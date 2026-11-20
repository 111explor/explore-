-- =====================================================================
--  بوت تلجرام للمتجر (نوفمبر 2026). شغّله بعد update-2026-11-hardening.sql
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
--
--  البوت بيشتغل على نفس الحسابات والأرصدة والمخزون والأسعار والخصومات تبع الموقع.
--  الشراء والبلاغ بيمرّوا على نفس دوال الموقع (purchase و report_issue) بالضبط.
--  كل دوال bot_* بيقدر يستدعيها بس سيرفر البوت (service_role)، مش الزوار ولا الزباين.
-- =====================================================================

-- ---------- ربط محادثة تلجرام بحساب ----------
create table if not exists public.telegram_links (
  chat_id     bigint primary key,
  user_id     uuid unique references public.profiles(id) on delete cascade,
  tg_username text,
  state       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.telegram_links enable row level security;
drop policy if exists telegram_links_admin on public.telegram_links;
create policy telegram_links_admin on public.telegram_links for select using (public.is_admin());

-- رقم بأي صيغة ← 05XXXXXXXX (نفس طريقة الموقع)
create or replace function public.norm_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if d like '00%' then d := substr(d, 3); end if;
  if d like '972%' or d like '970%' then d := '0' || substr(d, 4); end if;
  if d <> '' and d not like '0%' then d := '0' || d; end if;
  return d;
end $$;

-- بيخلّي باقي العملية كأنها من الزبون نفسه (عشان نستخدم نفس دوال الموقع)
create or replace function public.bot_act_as(p_chat bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  select user_id into v_uid from public.telegram_links where chat_id = p_chat;
  if v_uid is null then raise exception 'not_linked'; end if;
  perform set_config('app.source', 'bot', true);
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  return v_uid;
end $$;

-- ---------- إعدادات البوت (للسيرفر بس) ----------
create or replace function public.bot_config() returns table (token text, secret text)
language sql stable security definer set search_path = public as $$
  select public.setting('shop_bot_token'), public.setting('shop_bot_secret');
$$;

-- ---------- حالة المحادثة ----------
create or replace function public.bot_get(p_chat bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_l public.telegram_links; v_p public.profiles;
begin
  select * into v_l from public.telegram_links where chat_id = p_chat;
  if v_l.user_id is not null then select * into v_p from public.profiles where id = v_l.user_id; end if;
  return jsonb_build_object(
    'linked', v_p.id is not null, 'uid', v_p.id,
    'name', v_p.full_name, 'phone', v_p.phone, 'balance', v_p.balance,
    'state', coalesce(v_l.state, '{}'::jsonb));
end $$;

create or replace function public.bot_set_state(p_chat bigint, p_state jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.telegram_links (chat_id, state, updated_at) values (p_chat, coalesce(p_state, '{}'::jsonb), now())
  on conflict (chat_id) do update set state = excluded.state, updated_at = now();
$$;

-- ربط برقم الهاتف اللي شاركه الزبون من تلجرام (تلجرام متأكد إنه رقمه)
-- إذا ما في حساب بهالرقم بيرجع need_account، والسيرفر بيعمل حساب وبيرجع ينادي
create or replace function public.bot_link(p_chat bigint, p_phone text, p_username text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_phone text := public.norm_phone(p_phone); v_p public.profiles;
begin
  if v_phone !~ '^0\d{8,9}$' then raise exception 'invalid_phone'; end if;
  select * into v_p from public.profiles where phone = v_phone;
  if not found then return jsonb_build_object('ok', false, 'need_account', true, 'phone', v_phone); end if;
  delete from public.telegram_links where user_id = v_p.id and chat_id <> p_chat;
  insert into public.telegram_links (chat_id, user_id, tg_username, state, updated_at)
    values (p_chat, v_p.id, nullif(p_username, ''), '{}'::jsonb, now())
    on conflict (chat_id) do update set user_id = excluded.user_id, tg_username = excluded.tg_username, state = '{}'::jsonb, updated_at = now();
  perform public.bot_act_as(p_chat);
  if not v_p.phone_verified then
    update public.profiles set phone_verified = true where id = v_p.id;
  end if;
  perform public.audit('🤖 <b>زبون ربط حسابه ببوت تلجرام</b>', public.who(v_p.id), false,
    '🤖 بوت تلجرام · ' || coalesce(nullif(v_p.full_name, ''), '—') || ' (' || v_p.phone || ')');
  return jsonb_build_object('ok', true, 'name', v_p.full_name, 'phone', v_p.phone, 'balance', v_p.balance);
end $$;

-- ---------- المتجر ----------
create or replace function public.bot_products(p_chat bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_disc numeric := 0;
begin
  select user_id into v_uid from public.telegram_links where chat_id = p_chat;
  if v_uid is not null then v_disc := coalesce((public.tier_for(public.customer_spent(v_uid))).discount_pct, 0); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'description', p.description, 'duration', p.duration,
      'price', p.price, 'final', round(p.price * (100 - v_disc) / 100, 2), 'discount', v_disc,
      'delivery', p.delivery,
      'available', case when p.delivery = 'auto' then (select count(*) from public.stock_items s where s.product_id = p.id and not s.is_sold) end
    ) order by p.sort, p.id)
    from public.products p where p.active), '[]'::jsonb);
end $$;

create or replace function public.bot_purchase(p_chat bigint, p_product_id bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.bot_act_as(p_chat); v_o public.orders; v_bal numeric;
begin
  -- ضد الضغط المزدوج: نفس المنتج خلال 10 ثواني
  if exists (select 1 from public.orders where user_id = v_uid and product_id = p_product_id and created_at > now() - interval '10 seconds') then
    raise exception 'too_fast';
  end if;
  v_o := public.purchase(p_product_id, p_note);
  select balance into v_bal from public.profiles where id = v_uid;
  return jsonb_build_object('id', v_o.id, 'status', v_o.status, 'product_name', v_o.product_name, 'price', v_o.price,
    'discount_pct', v_o.discount_pct, 'content', v_o.delivered_content, 'expires_at', v_o.expires_at, 'balance', v_bal);
end $$;

-- ---------- المحفظة ----------
create or replace function public.bot_wallet(p_chat bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.bot_act_as(p_chat); s record;
begin
  select * into s from public.my_summary();
  return jsonb_build_object(
    'balance', s.balance, 'spent', s.total_spent, 'tier', s.tier_name, 'discount', s.discount_pct,
    'next_tier', s.next_tier_name, 'next_min', s.next_min_spent, 'next_discount', s.next_discount_pct,
    'pending_topups', (select count(*) from public.topups where user_id = v_uid and status = 'pending'),
    'tx', coalesce((select jsonb_agg(t order by t.created_at desc) from (
        select kind, amount, note, created_at from public.wallet_tx where user_id = v_uid order by created_at desc limit 8) t), '[]'::jsonb));
end $$;

create or replace function public.bot_payment_methods() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.site_config where key = 'payment_methods' and jsonb_typeof(value) = 'array'), '[]'::jsonb);
$$;

create or replace function public.bot_create_topup(p_chat bigint, p_amount numeric, p_method text, p_reference text, p_receipt_path text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.bot_act_as(p_chat); v_t public.topups;
begin
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'invalid_amount'; end if;
  if length(trim(coalesce(p_reference, ''))) < 2 then raise exception 'reference_required'; end if;
  if p_receipt_path is not null and p_receipt_path not like v_uid::text || '/%' then raise exception 'invalid_receipt'; end if;
  insert into public.topups (user_id, amount, method, reference, receipt_path)
    values (v_uid, round(p_amount, 2), left(trim(p_method), 80), left(trim(p_reference), 120), p_receipt_path)
    returning * into v_t;
  return jsonb_build_object('id', v_t.id, 'amount', v_t.amount);
end $$;

-- ---------- الطلبات والبلاغات ----------
create or replace function public.bot_orders(p_chat bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.bot_act_as(p_chat);
begin
  return coalesce((select jsonb_agg(o order by o.created_at desc) from (
    select o.id, o.product_name, o.price, o.status, o.delivered_content as content, o.created_at, o.expires_at,
           exists (select 1 from public.reports r where r.order_id = o.id and r.status = 'open') as has_open_report
    from public.orders o where o.user_id = v_uid order by o.created_at desc limit 10) o), '[]'::jsonb);
end $$;

create or replace function public.bot_report(p_chat bigint, p_order_id bigint, p_message text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_r public.reports;
begin
  perform public.bot_act_as(p_chat);
  v_r := public.report_issue(p_order_id, p_message);
  return jsonb_build_object('id', v_r.id);
end $$;

create or replace function public.bot_contact() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'wa_services', (select value #>> '{}' from public.site_config where key = 'wa_services'),
    'wa_subscriptions', (select value #>> '{}' from public.site_config where key = 'wa_subscriptions'),
    'links', (select value from public.site_config where key = 'contact_links'),
    'site', public.setting('site_url'));
$$;

-- ---------- إشعارات الزبون بتوصله كمان على البوت ----------
create or replace function public.notify_user(p_user uuid, p_title text, p_body text, p_link text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_chat bigint; v_tok text;
begin
  insert into public.notifications (user_id, title, body, link) values (p_user, p_title, p_body, p_link);
  select chat_id into v_chat from public.telegram_links where user_id = p_user;
  v_tok := public.setting('shop_bot_token');
  if v_chat is not null and coalesce(v_tok, '') <> '' then
    begin
      perform net.http_post(
        url := 'https://api.telegram.org/bot' || v_tok || '/sendMessage',
        body := jsonb_build_object('chat_id', v_chat, 'parse_mode', 'HTML', 'disable_web_page_preview', true,
          'text', '<b>' || public.tg_esc(p_title) || '</b>' || coalesce(E'\n' || public.tg_esc(p_body), '')),
        headers := '{"Content-Type": "application/json"}'::jsonb);
    exception when others then raise notice 'bot notify failed: %', sqlerrm;
    end;
  end if;
end $$;

-- ---------- الأدمن: تشغيل البوت ----------
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_key not in ('telegram_bot_token', 'telegram_chat_id', 'site_url', 'currency', 'low_stock', 'alerts_all', 'alerts_signups', 'shop_bot_token') then raise exception 'invalid_setting'; end if;
  insert into public.app_settings (key, value) values (p_key, nullif(trim(p_value), ''))
    on conflict (key) do update set value = excluded.value;
end $$;

-- بيربط البوت بسيرفره (webhook) وبيحط أوامره. p_url = رابط الـ Edge Function
create or replace function public.admin_setup_shop_bot(p_url text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_tok text := public.setting('shop_bot_token'); v_secret text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if coalesce(v_tok, '') = '' then raise exception 'bot_token_missing'; end if;
  if p_url !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/[a-z0-9_-]+$' then raise exception 'invalid_url'; end if;
  v_secret := encode(gen_random_bytes(24), 'hex');
  insert into public.app_settings (key, value) values ('shop_bot_secret', v_secret)
    on conflict (key) do update set value = excluded.value;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_tok || '/setWebhook',
    body := jsonb_build_object('url', p_url, 'secret_token', v_secret, 'allowed_updates', jsonb_build_array('message', 'callback_query'), 'drop_pending_updates', true),
    headers := '{"Content-Type": "application/json"}'::jsonb);
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_tok || '/setMyCommands',
    body := jsonb_build_object('commands', jsonb_build_array(
      jsonb_build_object('command', 'start', 'description', 'القائمة الرئيسية'),
      jsonb_build_object('command', 'shop', 'description', 'المتجر'),
      jsonb_build_object('command', 'wallet', 'description', 'محفظتي وشحن الرصيد'),
      jsonb_build_object('command', 'orders', 'description', 'طلباتي'),
      jsonb_build_object('command', 'cancel', 'description', 'إلغاء العملية الحالية'))),
    headers := '{"Content-Type": "application/json"}'::jsonb);
  return p_url;
end $$;

create or replace function public.admin_bot_status() returns table (has_token boolean, connected boolean, linked bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query select coalesce(public.setting('shop_bot_token'), '') <> '', coalesce(public.setting('shop_bot_secret'), '') <> '',
    (select count(*) from public.telegram_links where user_id is not null);
end $$;

-- إذا تغيّر توكن البوت، لازم يرجع ينربط
create or replace function public.reset_bot_secret() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.key = 'shop_bot_token' and (tg_op = 'INSERT' or new.value is distinct from old.value) then
    delete from public.app_settings where key = 'shop_bot_secret';
  end if;
  return new;
end $$;
drop trigger if exists app_settings_bot_reset on public.app_settings;
create trigger app_settings_bot_reset after insert or update on public.app_settings for each row execute function public.reset_bot_secret();

-- ---------- إشعار تغيير إعدادات البوت (بدون ما نكشف السر) ----------
create or replace function public.audit_app_settings() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_key text := coalesce(new.key, old.key);
begin
  if v_key = 'shop_bot_secret' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and new.value is not distinct from old.value then return new; end if;
  perform public.audit('🔧 <b>إعداد اتغيّر:</b> ' || case v_key
      when 'telegram_bot_token' then 'توكن بوت الإشعارات' when 'telegram_chat_id' then 'Chat ID تلجرام'
      when 'shop_bot_token' then 'توكن بوت المتجر'
      when 'alerts_all' then 'الإشعارات الفورية' when 'alerts_signups' then 'إشعار الحسابات الجديدة'
      when 'low_stock' then 'حد تنبيه المخزون' when 'site_url' then 'رابط الموقع' else public.tg_esc(v_key) end,
    case when v_key in ('alerts_all', 'alerts_signups', 'low_stock') and tg_op <> 'DELETE' then 'صار: ' || public.tg_esc(coalesce(new.value, '—')) else null end,
    v_key in ('telegram_bot_token', 'telegram_chat_id', 'alerts_all', 'shop_bot_token'));
  return coalesce(new, old);
end $$;
revoke execute on function public.audit_app_settings() from public, anon, authenticated;

-- ---------- الصلاحيات ----------
revoke execute on function public.norm_phone(text) from public, anon, authenticated;
revoke execute on function public.bot_act_as(bigint) from public, anon, authenticated, service_role;
revoke execute on function public.reset_bot_secret() from public, anon, authenticated;
revoke execute on function public.notify_user(uuid, text, text, text) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'bot_config()', 'bot_get(bigint)', 'bot_set_state(bigint, jsonb)', 'bot_link(bigint, text, text)',
    'bot_products(bigint)', 'bot_purchase(bigint, bigint, text)', 'bot_wallet(bigint)', 'bot_payment_methods()',
    'bot_create_topup(bigint, numeric, text, text, text)', 'bot_orders(bigint)', 'bot_report(bigint, bigint, text)', 'bot_contact()']
  loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    begin execute format('grant execute on function public.%s to service_role', f);
    exception when undefined_object then raise notice 'no service_role role (local test)';
    end;
  end loop;
end $$;
revoke execute on function public.admin_setup_shop_bot(text) from public, anon;
revoke execute on function public.admin_bot_status() from public, anon;
grant execute on function public.admin_set_setting(text, text) to authenticated;
grant execute on function public.admin_setup_shop_bot(text) to authenticated;
grant execute on function public.admin_bot_status() to authenticated;
