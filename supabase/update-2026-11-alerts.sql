-- =====================================================================
--  إشعارات فورية لكل تعديل + سجل العمليات (نوفمبر 2026)
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
--
--  شو بيعمل:
--  • أي تعديل على الفلوس، الطلبات، المنتجات، المخزون، الإعدادات، الحسابات
--    بيوصلك فوراً على بوت تلجرام، ومكتوب فيه مين عمله.
--  • لو حدا عدّل مباشرة من لوحة Supabase (مش من لوحة الإدارة) بيوصلك ⚠️.
--  • لو رصيد زبون اتغيّر بدون حركة مسجّلة بالمحفظة بيوصلك 🚨.
--  • دخول الأدمن، تغيير كلمة سره، أو حدا صار أدمن: 🚨 دايماً (حتى لو طفيت الإشعارات).
--  • كل شي بينحفظ بجدول audit_log، ما حدا بيقدر يعدّله أو يحذفه من الموقع.
-- =====================================================================

-- ---------- 1) سجل العمليات ----------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  actor_label text not null,
  action      text not null,
  details     text,
  critical    boolean not null default false
);
create index if not exists audit_log_at_idx on public.audit_log (at desc);
alter table public.audit_log enable row level security;
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select using (public.is_admin());
-- ما في سياسات insert/update/delete: السجل ما بينكتب إلا من التريغرات

-- ---------- 2) مين عمل التعديل؟ ----------
create or replace function public.actor_label() returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_p public.profiles;
  v_claims text := nullif(current_setting('request.jwt.claims', true), '');
  v_role text;
begin
  if v_uid is not null then
    select * into v_p from public.profiles where id = v_uid;
    return case when v_p.is_admin then 'الأدمن ' else 'الزبون ' end
      || coalesce(nullif(v_p.full_name, ''), '—') || ' (' || coalesce(v_p.phone, '?') || ')';
  end if;
  begin v_role := v_claims::jsonb ->> 'role'; exception when others then v_role := null; end;
  if v_role = 'service_role' then return '🔑 مفتاح service_role'; end if;
  return '⚠️ مباشرة من Supabase (Dashboard أو SQL)';
end $$;
revoke execute on function public.actor_label() from public, anon, authenticated;

-- ---------- 3) تسجيل + إرسال (ما بيوقف أي عملية لو فشل) ----------
create or replace function public.audit(p_action text, p_details text default null, p_critical boolean default false, p_actor text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor text;
  v_plain text;
begin
  v_actor := coalesce(p_actor, public.actor_label());
  v_plain := replace(replace(replace(regexp_replace(p_action || coalesce(E'\n' || p_details, ''), '<[^>]+>', '', 'g'), '&lt;', '<'), '&gt;', '>'), '&amp;', '&');
  insert into public.audit_log (actor, actor_label, action, details, critical)
    values (auth.uid(), v_actor, split_part(v_plain, E'\n', 1), nullif(substr(v_plain, length(split_part(v_plain, E'\n', 1)) + 2), ''), p_critical);
  if p_critical or coalesce(public.setting('alerts_all'), 'on') <> 'off' then
    perform public.notify_admin(
      case when p_critical then '🚨 ' else '' end || p_action ||
      coalesce(E'\n' || p_details, '') ||
      E'\n<i>بواسطة: ' || public.tg_esc(v_actor) || '</i>');
  end if;
exception when others then
  raise notice 'audit failed: %', sqlerrm;
end $$;
revoke execute on function public.audit(text, text, boolean, text) from public, anon, authenticated;

create or replace function public.who(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(public.tg_esc(nullif(full_name, '')), '—') || ' (' || public.tg_esc(phone) || ')' from public.profiles where id = p_user;
$$;
revoke execute on function public.who(uuid) from public, anon, authenticated;

-- ---------- 4) الشحنات: قبول ورفض ----------
create or replace function public.audit_topups() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'approved' then
      perform public.audit('✅ <b>قبول شحنة #' || new.id || '</b>',
        'الزبون: ' || public.who(new.user_id) || E'\nالمبلغ: <b>' || public.fmt_money(new.amount) || '</b>' ||
        case when new.amount <> old.amount then ' (كان مطلوب ' || public.fmt_money(old.amount) || ')' else '' end);
    elsif new.status = 'rejected' then
      perform public.audit('❌ <b>رفض شحنة #' || new.id || '</b>',
        'الزبون: ' || public.who(new.user_id) || E'\nالمبلغ: ' || public.fmt_money(new.amount) ||
        coalesce(E'\nالسبب: ' || public.tg_esc(new.admin_note), ''));
    else
      perform public.audit('✏️ <b>حالة شحنة #' || new.id || ' رجعت ' || new.status || '</b>', 'الزبون: ' || public.who(new.user_id), true);
    end if;
  elsif tg_op = 'UPDATE' and new.amount is distinct from old.amount then
    perform public.audit('✏️ <b>مبلغ شحنة #' || new.id || ' اتغيّر</b>', public.fmt_money(old.amount) || ' ← ' || public.fmt_money(new.amount), true);
  elsif tg_op = 'DELETE' then
    perform public.audit('🗑 <b>انحذفت شحنة #' || old.id || '</b>', 'الزبون: ' || coalesce(public.who(old.user_id), '—') || E'\nالمبلغ: ' || public.fmt_money(old.amount) || ' · ' || old.status, true);
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists topups_audit on public.topups;
create trigger topups_audit after update or delete on public.topups for each row execute function public.audit_topups();

-- ---------- 5) الطلبات: تسليم يدوي، استرجاع، تغيير محتوى ----------
create or replace function public.audit_orders() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    perform public.audit('🗑 <b>انحذف طلب #' || old.id || '</b>', public.tg_esc(old.product_name) || ' · ' || public.fmt_money(old.price) || ' · ' || old.status, true);
    return old;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'delivered' then
      perform public.audit('📦 <b>تسليم يدوي للطلب #' || new.id || '</b>', public.tg_esc(new.product_name) || E'\nالزبون: ' || public.who(new.user_id));
    elsif new.status = 'refunded' then
      perform public.audit('↩️ <b>استرجاع طلب #' || new.id || '</b>',
        public.tg_esc(new.product_name) || E'\nرجع <b>' || public.fmt_money(new.price) || '</b> لرصيد ' || public.who(new.user_id) ||
        coalesce(E'\nملاحظة: ' || public.tg_esc(new.admin_note), ''));
    else
      perform public.audit('✏️ <b>حالة الطلب #' || new.id || ' اتغيّرت</b>', old.status || ' ← ' || new.status, true);
    end if;
  elsif new.delivered_content is distinct from old.delivered_content then
    perform public.audit('🔁 <b>تغيير محتوى الطلب #' || new.id || '</b>', public.tg_esc(new.product_name) || E'\nالزبون: ' || public.who(new.user_id));
  end if;
  if new.price is distinct from old.price or new.user_id is distinct from old.user_id then
    perform public.audit('✏️ <b>بيانات الطلب #' || new.id || ' اتغيّرت</b>',
      'السعر: ' || public.fmt_money(old.price) || ' ← ' || public.fmt_money(new.price), true);
  end if;
  return new;
end $$;
drop trigger if exists orders_audit on public.orders;
create trigger orders_audit after update or delete on public.orders for each row execute function public.audit_orders();

-- ---------- 6) المحفظة: تعديل رصيد يدوي، وأي تلاعب بالسجل ----------
create or replace function public.audit_wallet() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'adjust' then
      perform public.audit('✏️ <b>تعديل رصيد يدوي: ' || case when new.amount > 0 then '+' else '' end || public.fmt_money(new.amount) || '</b>',
        'الزبون: ' || public.who(new.user_id) || coalesce(E'\nملاحظة: ' || public.tg_esc(new.note), ''));
    end if;
    return new;
  end if;
  perform public.audit('<b>سجل المحفظة ' || case when tg_op = 'DELETE' then 'انحذف منه' else 'انعدّل فيه' end || ' حركة #' || old.id || '</b>',
    'الزبون: ' || coalesce(public.who(old.user_id), '—') || E'\n' || old.kind || ' · ' || public.fmt_money(old.amount), true);
  return coalesce(new, old);
end $$;
drop trigger if exists wallet_audit on public.wallet_tx;
create trigger wallet_audit after insert or update or delete on public.wallet_tx for each row execute function public.audit_wallet();

-- رصيد اتغيّر بدون حركة بالمحفظة بنفس العملية؟ (بينفحص آخر العملية)
create or replace function public.audit_balance_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.wallet_tx where user_id = new.id and created_at = now()) then
    perform public.audit('<b>رصيد اتغيّر بدون حركة مسجّلة بالمحفظة</b>',
      'الزبون: ' || public.who(new.id) || E'\n' || public.fmt_money(old.balance) || ' ← ' || public.fmt_money(new.balance), true);
  end if;
  return null;
end $$;
drop trigger if exists profiles_balance_guard on public.profiles;
create constraint trigger profiles_balance_guard after update of balance on public.profiles
  deferrable initially deferred for each row
  when (old.balance is distinct from new.balance)
  execute function public.audit_balance_guard();

-- ---------- 7) الحسابات ----------
create or replace function public.audit_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_parts text := '';
begin
  if tg_op = 'INSERT' then
    if coalesce(public.setting('alerts_signups'), 'on') <> 'off' then
      perform public.audit('👤 <b>حساب جديد</b>', public.tg_esc(nullif(new.full_name, '')) || ' (' || public.tg_esc(new.phone) || ')', false, 'تسجيل من المتجر');
    else
      insert into public.audit_log (actor_label, action, details) values ('تسجيل من المتجر', 'حساب جديد', new.full_name || ' (' || new.phone || ')');
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    perform public.audit('🗑 <b>انحذف حساب</b>', public.tg_esc(old.full_name) || ' (' || public.tg_esc(old.phone) || ') · رصيده كان ' || public.fmt_money(old.balance), true);
    return old;
  end if;
  if new.is_admin is distinct from old.is_admin then
    perform public.audit(case when new.is_admin then '<b>حساب صار أدمن!</b>' else '<b>انشالت صلاحية الأدمن</b>' end, public.who(new.id), true);
  end if;
  if new.phone is distinct from old.phone then v_parts := v_parts || E'\nالرقم: ' || public.tg_esc(old.phone) || ' ← ' || public.tg_esc(new.phone); end if;
  if new.full_name is distinct from old.full_name then v_parts := v_parts || E'\nالاسم: ' || public.tg_esc(old.full_name) || ' ← ' || public.tg_esc(new.full_name); end if;
  if new.phone_verified is distinct from old.phone_verified then v_parts := v_parts || E'\n' || case when new.phone_verified then 'صار الرقم موثّق ✓' else 'انشال توثيق الرقم' end; end if;
  if v_parts <> '' then
    perform public.audit('✏️ <b>تعديل حساب</b> ' || public.who(new.id), substr(v_parts, 2));
  end if;
  return new;
end $$;
drop trigger if exists profiles_audit on public.profiles;
create trigger profiles_audit after insert or update or delete on public.profiles for each row execute function public.audit_profiles();

-- ---------- 8) المنتجات والأسعار ----------
create or replace function public.audit_products() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_parts text := '';
begin
  if tg_op = 'INSERT' then
    perform public.audit('➕ <b>منتج جديد:</b> ' || public.tg_esc(new.name), 'السعر: ' || public.fmt_money(new.price) || ' · ' || case when new.delivery = 'auto' then 'تسليم تلقائي' else 'تسليم يدوي' end);
    return new;
  elsif tg_op = 'DELETE' then
    perform public.audit('🗑 <b>انحذف منتج:</b> ' || public.tg_esc(old.name), 'كان سعره ' || public.fmt_money(old.price));
    return old;
  end if;
  if new.price is distinct from old.price then v_parts := v_parts || E'\n💲 السعر: ' || public.fmt_money(old.price) || ' ← <b>' || public.fmt_money(new.price) || '</b>'; end if;
  if new.active is distinct from old.active then v_parts := v_parts || E'\n' || case when new.active then '👁 صار ظاهر بالمتجر' else '🙈 انخفى من المتجر' end; end if;
  if new.name is distinct from old.name then v_parts := v_parts || E'\nالاسم: ' || public.tg_esc(old.name) || ' ← ' || public.tg_esc(new.name); end if;
  if new.delivery is distinct from old.delivery then v_parts := v_parts || E'\nالتسليم: ' || old.delivery || ' ← ' || new.delivery; end if;
  if new.duration_days is distinct from old.duration_days then v_parts := v_parts || E'\nالمدة: ' || coalesce(old.duration_days::text, '—') || ' ← ' || coalesce(new.duration_days::text, '—') || ' يوم'; end if;
  if v_parts <> '' then
    perform public.audit('🏷 <b>تعديل منتج:</b> ' || public.tg_esc(new.name), substr(v_parts, 2));
  end if;
  return new;
end $$;
drop trigger if exists products_audit on public.products;
create trigger products_audit after insert or update or delete on public.products for each row execute function public.audit_products();

-- ---------- 9) المخزون (رسالة وحدة لكل عملية، مش لكل سطر) ----------
create or replace function public.audit_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'INSERT' then
    for r in select p.name, count(*) n from new_rows s left join public.products p on p.id = s.product_id group by p.name loop
      perform public.audit('📥 <b>انضاف ' || r.n || ' للمخزون</b>', public.tg_esc(coalesce(r.name, '?')));
    end loop;
  elsif tg_op = 'DELETE' then
    for r in select p.name, count(*) n, count(*) filter (where s.is_sold) sold from old_rows s left join public.products p on p.id = s.product_id group by p.name loop
      perform public.audit('🗑 <b>انحذف ' || r.n || ' من المخزون</b>', public.tg_esc(coalesce(r.name, '?')) || case when r.sold > 0 then E'\n(منهم ' || r.sold || ' مباعين)' else '' end, r.sold > 0);
    end loop;
  else
    for r in select p.name, count(*) n from new_rows nw join old_rows o on o.id = nw.id left join public.products p on p.id = nw.product_id
             where nw.content is distinct from o.content or (o.is_sold and not nw.is_sold) group by p.name loop
      perform public.audit('✏️ <b>تعديل ' || r.n || ' عنصر بالمخزون</b>', public.tg_esc(coalesce(r.name, '?')), true);
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists stock_audit_ins on public.stock_items;
drop trigger if exists stock_audit_del on public.stock_items;
drop trigger if exists stock_audit_upd on public.stock_items;
create trigger stock_audit_ins after insert on public.stock_items referencing new table as new_rows for each statement execute function public.audit_stock();
create trigger stock_audit_del after delete on public.stock_items referencing old table as old_rows for each statement execute function public.audit_stock();
create trigger stock_audit_upd after update on public.stock_items referencing old table as old_rows new table as new_rows for each statement execute function public.audit_stock();

-- ---------- 10) إعدادات الموقع (أرقام الواتساب وطرق الدفع مهمين جداً) ----------
create or replace function public.audit_site_config() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_key text := coalesce(new.key, old.key);
  v_label text;
  v_val text;
  v_old text;
begin
  if tg_op = 'UPDATE' and new.value = old.value then return new; end if;
  v_label := case v_key
    when 'wa_subscriptions' then 'واتساب الاشتراكات' when 'wa_services' then 'واتساب الخدمات'
    when 'payment_methods' then 'طرق الدفع' when 'socials' then 'روابط السوشال'
    when 'hours' then 'ساعات العمل' when 'stat_services' then 'رقم الإحصائية'
    when 'contact_links' then 'صفحة تواصل معنا' else v_key end;
  if v_key = 'payment_methods' and tg_op <> 'DELETE' then
    select string_agg('• ' || coalesce(m->>'name', '') || ': ' || left(coalesce(m->>'details', ''), 120), E'\n') into v_val from jsonb_array_elements(new.value) m;
  elsif v_key = 'contact_links' and tg_op <> 'DELETE' then
    select string_agg('• ' || coalesce(l->>'title', '') || ': ' || coalesce(l->>'value', ''), E'\n') into v_val from jsonb_array_elements(new.value) l;
  elsif tg_op <> 'DELETE' then
    v_val := case when jsonb_typeof(new.value) = 'string' then new.value #>> '{}' else new.value::text end;
    if tg_op = 'UPDATE' then v_old := case when jsonb_typeof(old.value) = 'string' then old.value #>> '{}' else old.value::text end; end if;
  end if;
  perform public.audit('⚙️ <b>تعديل ' || public.tg_esc(v_label) || '</b>',
    case when tg_op = 'DELETE' then 'انحذف'
         when v_old is not null then public.tg_esc(left(v_old, 300)) || ' ← <b>' || public.tg_esc(left(v_val, 300)) || '</b>'
         else public.tg_esc(left(coalesce(v_val, ''), 900)) end,
    v_key in ('wa_subscriptions', 'wa_services', 'payment_methods'));
  return coalesce(new, old);
end $$;
drop trigger if exists site_config_audit on public.site_config;
create trigger site_config_audit after insert or update or delete on public.site_config for each row execute function public.audit_site_config();

-- ---------- 11) إعدادات سرية (بدون ما نكشف القيمة) ----------
create or replace function public.audit_app_settings() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_key text := coalesce(new.key, old.key);
begin
  if tg_op = 'UPDATE' and new.value is not distinct from old.value then return new; end if;
  perform public.audit('🔧 <b>إعداد اتغيّر:</b> ' || case v_key
      when 'telegram_bot_token' then 'توكن بوت تلجرام' when 'telegram_chat_id' then 'Chat ID تلجرام'
      when 'alerts_all' then 'الإشعارات الفورية' when 'alerts_signups' then 'إشعار الحسابات الجديدة'
      when 'low_stock' then 'حد تنبيه المخزون' when 'site_url' then 'رابط الموقع' else public.tg_esc(v_key) end,
    case when v_key in ('alerts_all', 'alerts_signups', 'low_stock') and tg_op <> 'DELETE' then 'صار: ' || public.tg_esc(coalesce(new.value, '—')) else null end,
    v_key in ('telegram_bot_token', 'telegram_chat_id', 'alerts_all'));
  return coalesce(new, old);
end $$;
drop trigger if exists app_settings_audit on public.app_settings;
create trigger app_settings_audit after insert or update or delete on public.app_settings for each row execute function public.audit_app_settings();

-- ---------- 12) العروض ومستويات الخصم والبلاغات ----------
create or replace function public.audit_misc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'announcements' then
    if tg_op = 'DELETE' then perform public.audit('🗑 <b>انحذف عرض:</b> ' || public.tg_esc(old.title));
    elsif tg_op = 'UPDATE' and new.active is distinct from old.active then
      perform public.audit(case when new.active then '📣 <b>رجع العرض ظاهر:</b> ' else '⏸ <b>توقّف العرض:</b> ' end || public.tg_esc(new.title));
    end if;
  elsif tg_table_name = 'loyalty_tiers' then
    if tg_op = 'DELETE' then perform public.audit('⭐ <b>انحذف مستوى خصم:</b> ' || public.tg_esc(old.name), public.fmt_money(old.min_spent) || ' · ' || old.discount_pct || '%');
    elsif tg_op = 'INSERT' then perform public.audit('⭐ <b>مستوى خصم جديد:</b> ' || public.tg_esc(new.name), 'بعد ' || public.fmt_money(new.min_spent) || ' · خصم ' || new.discount_pct || '%');
    elsif row(new.*) is distinct from row(old.*) then
      perform public.audit('⭐ <b>تعديل مستوى خصم:</b> ' || public.tg_esc(new.name),
        public.fmt_money(old.min_spent) || ' · ' || old.discount_pct || '% ← ' || public.fmt_money(new.min_spent) || ' · ' || new.discount_pct || '%');
    end if;
  elsif tg_table_name = 'reports' then
    if tg_op = 'UPDATE' and new.status is distinct from old.status then
      perform public.audit('🛠 <b>' || case when new.status = 'rejected' then 'رفض' else 'حل' end || ' بلاغ #' || new.id || '</b> (طلب #' || new.order_id || ')',
        'الزبون: ' || public.who(new.user_id) || coalesce(E'\nالرد: ' || public.tg_esc(new.admin_reply), ''));
    end if;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists announcements_audit on public.announcements;
create trigger announcements_audit after update or delete on public.announcements for each row execute function public.audit_misc();
drop trigger if exists tiers_audit on public.loyalty_tiers;
create trigger tiers_audit after insert or update or delete on public.loyalty_tiers for each row execute function public.audit_misc();
drop trigger if exists reports_audit on public.reports;
create trigger reports_audit after update on public.reports for each row execute function public.audit_misc();

-- ---------- 13) دخول الأدمن وتغيير كلمات السر (أهم إشعار) ----------
create or replace function public.audit_auth_users() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_p public.profiles;
begin
  begin
    select * into v_p from public.profiles where id = new.id;
    if not found then return new; end if;
    if new.last_sign_in_at is distinct from old.last_sign_in_at and v_p.is_admin then
      perform public.audit('🔐 <b>دخول للوحة الإدارة</b>', public.who(new.id) || E'\n' || to_char(now() at time zone 'Asia/Hebron', 'YYYY-MM-DD HH24:MI'), true,
        'الأدمن ' || coalesce(nullif(v_p.full_name, ''), '—') || ' (' || v_p.phone || ')');
    end if;
    if new.encrypted_password is distinct from old.encrypted_password then
      if v_p.is_admin then
        perform public.audit('<b>كلمة سر الأدمن اتغيّرت</b>', public.who(new.id), true);
      else
        perform public.audit('🔑 <b>كلمة سر جديدة لزبون</b>', public.who(new.id));
      end if;
    end if;
  exception when others then raise notice 'auth audit failed: %', sqlerrm;
  end;
  return new;
end $$;
revoke execute on function public.audit_auth_users() from public, anon, authenticated;
drop trigger if exists on_auth_user_audit on auth.users;
create trigger on_auth_user_audit after update on auth.users for each row execute function public.audit_auth_users();

-- ---------- 14) إعدادات الإشعارات من لوحة الإدارة ----------
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_key not in ('telegram_bot_token', 'telegram_chat_id', 'site_url', 'currency', 'low_stock', 'alerts_all', 'alerts_signups') then raise exception 'invalid_setting'; end if;
  insert into public.app_settings (key, value) values (p_key, nullif(trim(p_value), ''))
    on conflict (key) do update set value = excluded.value;
end $$;

create or replace function public.admin_alert_prefs()
returns table (alerts_all boolean, alerts_signups boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query select coalesce(public.setting('alerts_all'), 'on') <> 'off', coalesce(public.setting('alerts_signups'), 'on') <> 'off';
end $$;
revoke execute on function public.admin_alert_prefs() from public, anon;
grant execute on function public.admin_alert_prefs() to authenticated;

-- ---------- 15) تنظيف: دوال مساعدة كانت مفتوحة للكل ----------
revoke execute on function public.tier_for(numeric) from public, anon, authenticated;
revoke execute on function public.fmt_money(numeric) from public, anon, authenticated;
revoke execute on function public.tg_esc(text) from public, anon, authenticated;
revoke execute on function public.admin_link(text) from public, anon, authenticated;
revoke execute on function public.audit_topups() from public, anon, authenticated;
revoke execute on function public.audit_orders() from public, anon, authenticated;
revoke execute on function public.audit_wallet() from public, anon, authenticated;
revoke execute on function public.audit_balance_guard() from public, anon, authenticated;
revoke execute on function public.audit_profiles() from public, anon, authenticated;
revoke execute on function public.audit_products() from public, anon, authenticated;
revoke execute on function public.audit_stock() from public, anon, authenticated;
revoke execute on function public.audit_site_config() from public, anon, authenticated;
revoke execute on function public.audit_app_settings() from public, anon, authenticated;
revoke execute on function public.audit_misc() from public, anon, authenticated;
-- is_admin لازم يضل مفتوح: سياسات RLS بتستخدمه

select public.audit('✅ <b>الإشعارات الفورية اشتغلت</b>', 'من هلأ أي تعديل بيوصلك هون.', true, 'إعداد النظام');
