-- =====================================================================
--  Explor Plus Store: قاعدة البيانات (Supabase / Postgres)
--  الصق هاد الملف كامل في: Supabase → SQL Editor → New query → Run
--  آمن إنك تشغله أكثر من مرة.
-- =====================================================================

-- ---------- الجداول ----------

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  phone       text not null unique,
  balance     numeric(12,2) not null default 0 check (balance >= 0),
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.products (
  id           bigint generated always as identity primary key,
  category     text not null default 'subscription' check (category in ('subscription','service')),
  name         text not null,
  name_en      text,
  description  text,
  price        numeric(12,2) not null check (price >= 0),
  duration     text,                       -- مثلاً: شهر، 3 شهور، سنة
  image_url    text,
  delivery     text not null default 'auto' check (delivery in ('auto','manual')),
  active       boolean not null default true,
  sort         int not null default 0,
  created_at   timestamptz not null default now()
);

-- المخزون: كل سطر = حساب/كود واحد بينسلّم لزبون واحد
create table if not exists public.stock_items (
  id          bigint generated always as identity primary key,
  product_id  bigint not null references public.products (id) on delete cascade,
  content     text not null,
  is_sold     boolean not null default false,
  order_id    bigint,
  created_at  timestamptz not null default now()
);
create index if not exists stock_available_idx on public.stock_items (product_id) where not is_sold;

create table if not exists public.orders (
  id                bigint generated always as identity primary key,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  product_id        bigint references public.products (id) on delete set null,
  product_name      text not null,
  price             numeric(12,2) not null,
  status            text not null default 'pending' check (status in ('pending','delivered','refunded')),
  delivered_content text,
  customer_note     text,
  admin_note        text,
  created_at        timestamptz not null default now(),
  delivered_at      timestamptz
);
create index if not exists orders_user_idx on public.orders (user_id, created_at desc);

create table if not exists public.topups (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  amount        numeric(12,2) not null check (amount > 0),
  method        text not null,
  reference     text,
  receipt_path  text,
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_note    text,
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz
);
create index if not exists topups_user_idx on public.topups (user_id, created_at desc);

-- سجل الحركات المالية (كل تغيير بالرصيد بينسجّل هون)
create table if not exists public.wallet_tx (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  amount      numeric(12,2) not null,           -- موجب = إضافة، سالب = خصم
  kind        text not null check (kind in ('topup','purchase','refund','adjust')),
  ref_id      bigint,
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists wallet_tx_user_idx on public.wallet_tx (user_id, created_at desc);

-- ---------- v2: انتهاء الاشتراكات، البلاغات، الإشعارات، الإعدادات ----------

alter table public.products add column if not exists duration_days int check (duration_days is null or duration_days > 0);
alter table public.orders   add column if not exists expires_at  timestamptz;
alter table public.orders   add column if not exists reminded_at timestamptz;
create index if not exists orders_expiry_idx on public.orders (expires_at) where status = 'delivered' and expires_at is not null;

-- بلاغات "الحساب وقف"
create table if not exists public.reports (
  id           bigint generated always as identity primary key,
  order_id     bigint not null references public.orders (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  message      text not null,
  status       text not null default 'open' check (status in ('open','resolved','rejected')),
  old_content  text,
  admin_reply  text,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
create unique index if not exists reports_one_open_per_order on public.reports (order_id) where status = 'open';

-- إشعارات الزبون داخل المتجر
create table if not exists public.notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  title       text not null,
  body        text,
  link        text,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

-- مستويات الامتياز: كل ما يصرف الزبون أكثر، بياخد خصم أكبر
create table if not exists public.loyalty_tiers (
  id            bigint generated always as identity primary key,
  name          text not null,
  min_spent     numeric(12,2) not null unique check (min_spent > 0),
  discount_pct  numeric(5,2) not null check (discount_pct > 0 and discount_pct < 100)
);
insert into public.loyalty_tiers (name, min_spent, discount_pct)
  select * from (values ('فضي', 5000::numeric, 2::numeric), ('ذهبي', 10000::numeric, 5::numeric)) v
  where not exists (select 1 from public.loyalty_tiers);

alter table public.orders add column if not exists list_price   numeric(12,2);
alter table public.orders add column if not exists discount_pct numeric(5,2) not null default 0;

-- إعدادات سرية (توكن بوت تلجرام…): ما في ولا policy، فما حدا بيقرأها من الموقع
create table if not exists public.app_settings (
  key    text primary key,
  value  text
);

-- ---------- مساعدات ----------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- إنشاء البروفايل تلقائياً عند التسجيل (الاسم والرقم بس، أبداً مش is_admin)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', new.id::text)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- عمليات الزبون ----------

-- الشراء: بيخصم الرصيد وبيسلّم من المخزون بعملية وحدة (ما في خصم مرتين ولا بيع نفس الحساب لاثنين)
create or replace function public.purchase(p_product_id bigint, p_note text default null)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_prod    public.products;
  v_bal     numeric;
  v_item    public.stock_items;
  v_order   public.orders;
  v_disc    numeric;
  v_price   numeric;
  v_before  public.loyalty_tiers;
  v_after   public.loyalty_tiers;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_prod from public.products where id = p_product_id and active;
  if not found then raise exception 'product_not_found'; end if;

  select balance into v_bal from public.profiles where id = v_uid for update;
  if v_bal is null then raise exception 'profile_not_found'; end if;

  -- خصم الامتياز حسب مجموع اللي صرفه الزبون
  v_before := public.tier_for(public.customer_spent(v_uid));
  v_disc   := coalesce(v_before.discount_pct, 0);
  v_price  := round(v_prod.price * (100 - v_disc) / 100, 2);
  if v_bal < v_price then raise exception 'insufficient_balance'; end if;

  if v_prod.delivery = 'auto' then
    select * into v_item from public.stock_items
      where product_id = v_prod.id and not is_sold
      order by id
      limit 1
      for update skip locked;
    if not found then raise exception 'out_of_stock'; end if;
  end if;

  update public.profiles set balance = balance - v_price where id = v_uid;

  insert into public.orders (user_id, product_id, product_name, price, list_price, discount_pct, status, delivered_content, customer_note, delivered_at, expires_at)
  values (
    v_uid, v_prod.id, v_prod.name, v_price, v_prod.price, v_disc,
    case when v_item.id is not null then 'delivered' else 'pending' end,
    v_item.content,
    nullif(trim(coalesce(p_note, '')), ''),
    case when v_item.id is not null then now() end,
    case when v_item.id is not null and v_prod.duration_days is not null then now() + make_interval(days => v_prod.duration_days) end
  )
  returning * into v_order;

  if v_item.id is not null then
    update public.stock_items set is_sold = true, order_id = v_order.id where id = v_item.id;
  end if;

  insert into public.wallet_tx (user_id, amount, kind, ref_id, note)
  values (v_uid, -v_price, 'purchase', v_order.id, v_prod.name || case when v_disc > 0 then ' (خصم ' || trim(to_char(v_disc, 'FM990.##'), '.') || '%)' else '' end);

  -- إذا انتقل لمستوى أعلى، بلّغه
  v_after := public.tier_for(public.customer_spent(v_uid));
  if v_after.id is not null and v_after.id is distinct from v_before.id then
    perform public.notify_user(v_uid, '🎉 مبروك! صرت عضو ' || v_after.name,
      'من هلأ عندك خصم ' || trim(to_char(v_after.discount_pct, 'FM990.##'), '.') || '% على كل مشترياتك.', '#shop');
  end if;

  return v_order;
end $$;

-- عدد المتوفر لكل منتج (بدون ما يكشف محتوى المخزون)
create or replace function public.product_stock()
returns table (product_id bigint, available bigint)
language sql stable security definer set search_path = public as $$
  select product_id, count(*) from public.stock_items where not is_sold group by product_id;
$$;

-- ---------- عمليات الأدمن ----------

create or replace function public.admin_approve_topup(p_topup_id bigint, p_amount numeric default null)
returns public.topups
language plpgsql security definer set search_path = public as $$
declare v_t public.topups; v_amount numeric;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_t from public.topups where id = p_topup_id for update;
  if not found then raise exception 'topup_not_found'; end if;
  if v_t.status <> 'pending' then raise exception 'topup_already_reviewed'; end if;
  v_amount := coalesce(p_amount, v_t.amount);
  if v_amount <= 0 then raise exception 'invalid_amount'; end if;

  -- الرصيد أول، بعدين الحالة (عشان إشعار الزبون يبيّن الرصيد الجديد)
  update public.profiles set balance = balance + v_amount where id = v_t.user_id;
  update public.topups set status = 'approved', amount = v_amount, reviewed_at = now()
    where id = p_topup_id returning * into v_t;
  insert into public.wallet_tx (user_id, amount, kind, ref_id, note)
    values (v_t.user_id, v_amount, 'topup', v_t.id, v_t.method);
  return v_t;
end $$;

create or replace function public.admin_reject_topup(p_topup_id bigint, p_note text default null)
returns public.topups
language plpgsql security definer set search_path = public as $$
declare v_t public.topups;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.topups set status = 'rejected', admin_note = p_note, reviewed_at = now()
    where id = p_topup_id and status = 'pending' returning * into v_t;
  if not found then raise exception 'topup_not_pending'; end if;
  return v_t;
end $$;

create or replace function public.admin_deliver_order(p_order_id bigint, p_content text)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare v_o public.orders;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.orders o set status = 'delivered', delivered_content = p_content, delivered_at = now(),
      expires_at = coalesce(o.expires_at, (select now() + make_interval(days => p.duration_days) from public.products p where p.id = o.product_id and p.duration_days is not null))
    where o.id = p_order_id and o.status = 'pending' returning * into v_o;
  if not found then raise exception 'order_not_pending'; end if;
  return v_o;
end $$;

-- استرجاع: بيرجّع المبلغ لرصيد الزبون
create or replace function public.admin_refund_order(p_order_id bigint, p_note text default null)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare v_o public.orders;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.orders set status = 'refunded', admin_note = p_note
    where id = p_order_id and status <> 'refunded' returning * into v_o;
  if not found then raise exception 'order_already_refunded'; end if;
  update public.profiles set balance = balance + v_o.price where id = v_o.user_id;
  insert into public.wallet_tx (user_id, amount, kind, ref_id, note)
    values (v_o.user_id, v_o.price, 'refund', v_o.id, p_note);
  return v_o;
end $$;

-- تعديل رصيد يدوي (موجب أو سالب)
create or replace function public.admin_adjust_balance(p_user_id uuid, p_amount numeric, p_note text default null)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare v_p public.profiles;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_amount = 0 then raise exception 'invalid_amount'; end if;
  update public.profiles set balance = balance + p_amount where id = p_user_id returning * into v_p;
  if not found then raise exception 'profile_not_found'; end if;
  insert into public.wallet_tx (user_id, amount, kind, note) values (p_user_id, p_amount, 'adjust', p_note);
  return v_p;
end $$;

-- إضافة مخزون: كل سطر = عنصر
create or replace function public.admin_add_stock(p_product_id bigint, p_lines text)
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  insert into public.stock_items (product_id, content)
    select p_product_id, trim(l) from regexp_split_to_table(p_lines, E'\\r?\\n') as l where trim(l) <> '';
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------- الصلاحيات (RLS) ----------

alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.stock_items enable row level security;
alter table public.orders      enable row level security;
alter table public.topups      enable row level security;
alter table public.wallet_tx   enable row level security;

-- profiles: كل زبون بيشوف حاله، الأدمن بيشوف الكل. التعديل على الرصيد بس من خلال الدوال.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (id = auth.uid() or public.is_admin());

-- products: الكل بيشوف المنتجات الفعّالة، الأدمن بيدير الكل
drop policy if exists products_select on public.products;
create policy products_select on public.products for select using (active or public.is_admin());
drop policy if exists products_admin on public.products;
create policy products_admin on public.products for all using (public.is_admin()) with check (public.is_admin());

-- stock_items: الأدمن بس
drop policy if exists stock_admin on public.stock_items;
create policy stock_admin on public.stock_items for all using (public.is_admin()) with check (public.is_admin());

-- orders: الزبون بيشوف طلباته، الإنشاء بس من خلال purchase()
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists orders_admin_update on public.orders;
create policy orders_admin_update on public.orders for update using (public.is_admin()) with check (public.is_admin());

-- topups: الزبون بيقدّم طلب شحن (pending فقط) وبيشوف طلباته
drop policy if exists topups_select on public.topups;
create policy topups_select on public.topups for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists topups_insert on public.topups;
create policy topups_insert on public.topups for insert
  with check (user_id = auth.uid() and status = 'pending' and reviewed_at is null and admin_note is null);

-- wallet_tx: قراءة فقط
drop policy if exists wallet_select on public.wallet_tx;
create policy wallet_select on public.wallet_tx for select using (user_id = auth.uid() or public.is_admin());

-- صلاحيات الدوال
revoke execute on function public.admin_approve_topup(bigint, numeric) from public, anon;
revoke execute on function public.admin_reject_topup(bigint, text)    from public, anon;
revoke execute on function public.admin_deliver_order(bigint, text)   from public, anon;
revoke execute on function public.admin_refund_order(bigint, text)    from public, anon;
revoke execute on function public.admin_adjust_balance(uuid, numeric, text) from public, anon;
revoke execute on function public.admin_add_stock(bigint, text)       from public, anon;
revoke execute on function public.purchase(bigint, text)              from public, anon;
grant  execute on function public.admin_approve_topup(bigint, numeric) to authenticated;
grant  execute on function public.admin_reject_topup(bigint, text)    to authenticated;
grant  execute on function public.admin_deliver_order(bigint, text)   to authenticated;
grant  execute on function public.admin_refund_order(bigint, text)    to authenticated;
grant  execute on function public.admin_adjust_balance(uuid, numeric, text) to authenticated;
grant  execute on function public.admin_add_stock(bigint, text)       to authenticated;
grant  execute on function public.purchase(bigint, text)              to authenticated;
grant  execute on function public.product_stock()                     to anon, authenticated;

-- ---------- تخزين صور الإيصالات ----------

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

drop policy if exists receipts_insert on storage.objects;
create policy receipts_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists receipts_select on storage.objects;
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- =====================================================================
--  v2: إشعارات تلجرام للأدمن، إشعارات الزبون، البلاغات، تذكير الانتهاء
-- =====================================================================

-- الإضافات (موجودة بـ Supabase؛ إذا مش متاحة الإشعارات بتتجاهل بهدوء)
do $$ begin create extension if not exists pg_net;  exception when others then raise notice 'pg_net not available: %', sqlerrm; end $$;
do $$ begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron not available: %', sqlerrm; end $$;

create or replace function public.setting(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from public.app_settings where key = p_key;
$$;
revoke execute on function public.setting(text) from public, anon, authenticated;

create or replace function public.tg_esc(t text) returns text
language sql immutable as $$
  select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

create or replace function public.fmt_money(n numeric) returns text
language sql stable security definer set search_path = public as $$
  select trim(to_char(n, 'FM999999990.##'), '.') || ' ' || coalesce(public.setting('currency'), '₪');
$$;

-- إرسال رسالة لتلجرام الأدمن (ما بيوقف أي عملية إذا فشل)
create or replace function public.notify_admin(p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare v_tok text := public.setting('telegram_bot_token'); v_chat text := public.setting('telegram_chat_id');
begin
  if coalesce(v_tok, '') = '' or coalesce(v_chat, '') = '' then return; end if;
  begin
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_tok || '/sendMessage',
      body := jsonb_build_object('chat_id', v_chat, 'text', p_text, 'parse_mode', 'HTML', 'disable_web_page_preview', true),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  exception when others then raise notice 'telegram notify failed: %', sqlerrm;
  end;
end $$;
revoke execute on function public.notify_admin(text) from public, anon, authenticated;

create or replace function public.admin_link(p_tab text) returns text
language sql stable security definer set search_path = public as $$
  select case when coalesce(public.setting('site_url'), '') = '' then ''
    else E'\n<a href="' || rtrim(public.setting('site_url'), '/') || '/admin.html#' || p_tab || '">افتح لوحة الإدارة</a>' end;
$$;

create or replace function public.notify_user(p_user uuid, p_title text, p_body text, p_link text default null) returns void
language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, title, body, link) values (p_user, p_title, p_body, p_link);
$$;
revoke execute on function public.notify_user(uuid, text, text, text) from public, anon, authenticated;

-- ---------- تريغرات: طلب شحن ----------
create or replace function public.on_topup_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_p public.profiles;
begin
  select * into v_p from public.profiles where id = new.user_id;
  if tg_op = 'INSERT' then
    perform public.notify_admin(
      '💰 <b>طلب شحن جديد #' || new.id || '</b>' ||
      E'\nالزبون: ' || public.tg_esc(v_p.full_name) || ' (' || public.tg_esc(v_p.phone) || ')' ||
      E'\nالمبلغ: <b>' || public.fmt_money(new.amount) || '</b>' ||
      E'\nالطريقة: ' || public.tg_esc(new.method) ||
      case when new.reference is not null then E'\nالمرجع: ' || public.tg_esc(new.reference) else '' end ||
      case when new.receipt_path is null then E'\n⚠️ بدون إيصال' else '' end ||
      public.admin_link('topups'));
  elsif new.status is distinct from old.status then
    if new.status = 'approved' then
      perform public.notify_user(new.user_id, '✅ تم شحن رصيدك', 'انضاف ' || public.fmt_money(new.amount) || ' لمحفظتك. رصيدك صار ' || public.fmt_money(v_p.balance) || '.', '#wallet');
    elsif new.status = 'rejected' then
      perform public.notify_user(new.user_id, '❌ طلب الشحن #' || new.id || ' انرفض', coalesce(new.admin_note, 'تواصل معنا لمعرفة السبب.'), '#wallet');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists topups_notify on public.topups;
create trigger topups_notify after insert or update on public.topups for each row execute function public.on_topup_change();

-- ---------- تريغرات: الطلبات ----------
create or replace function public.on_order_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_p public.profiles; v_left bigint; v_prod public.products; v_low int := coalesce(nullif(public.setting('low_stock'), '')::int, 3);
begin
  select * into v_p from public.profiles where id = new.user_id;
  if tg_op = 'INSERT' then
    perform public.notify_admin(
      case when new.status = 'pending' then '⏳ <b>طلب جديد بانتظارك #' else '🛒 <b>بيعة جديدة #' end || new.id || '</b>' ||
      E'\n' || public.tg_esc(new.product_name) || ' · <b>' || public.fmt_money(new.price) || '</b>' ||
      E'\nالزبون: ' || public.tg_esc(v_p.full_name) || ' (' || public.tg_esc(v_p.phone) || ')' ||
      case when new.status = 'delivered' then E'\n✅ انسلّم تلقائياً' else '' end ||
      case when new.customer_note is not null then E'\nملاحظة: ' || public.tg_esc(new.customer_note) else '' end ||
      case when new.status = 'pending' then public.admin_link('orders') else '' end);
    select * into v_prod from public.products where id = new.product_id;
    if v_prod.delivery = 'auto' then
      select count(*) into v_left from public.stock_items where product_id = v_prod.id and not is_sold;
      if v_left < v_low then
        perform public.notify_admin('⚠️ <b>المخزون قرّب يخلص</b>' || E'\n' || public.tg_esc(v_prod.name) || ': باقي <b>' || v_left || '</b>' || public.admin_link('stock'));
      end if;
    end if;
  elsif new.status is distinct from old.status then
    if new.status = 'delivered' then
      perform public.notify_user(new.user_id, '✅ طلبك #' || new.id || ' جاهز', new.product_name || '. التفاصيل بصفحة طلباتي.', '#orders');
    elsif new.status = 'refunded' then
      perform public.notify_user(new.user_id, '↩️ رجعنالك ' || public.fmt_money(new.price), 'طلب #' || new.id || ' (' || new.product_name || ')' || coalesce('. ' || new.admin_note, ''), '#wallet');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists orders_notify on public.orders;
create trigger orders_notify after insert or update on public.orders for each row execute function public.on_order_change();

-- ---------- البلاغات ----------
create or replace function public.report_issue(p_order_id bigint, p_message text) returns public.reports
language plpgsql security definer set search_path = public as $$
declare v_o public.orders; v_r public.reports; v_p public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if length(trim(coalesce(p_message, ''))) < 3 then raise exception 'message_required'; end if;
  select * into v_o from public.orders where id = p_order_id and user_id = auth.uid();
  if not found then raise exception 'order_not_found'; end if;
  if v_o.status <> 'delivered' then raise exception 'order_not_delivered'; end if;
  if exists (select 1 from public.reports where order_id = p_order_id and status = 'open') then raise exception 'report_already_open'; end if;
  insert into public.reports (order_id, user_id, message, old_content)
    values (p_order_id, auth.uid(), left(trim(p_message), 1000), v_o.delivered_content) returning * into v_r;
  select * into v_p from public.profiles where id = auth.uid();
  perform public.notify_admin('🚨 <b>بلاغ جديد على طلب #' || v_o.id || '</b>' ||
    E'\n' || public.tg_esc(v_o.product_name) ||
    E'\nالزبون: ' || public.tg_esc(v_p.full_name) || ' (' || public.tg_esc(v_p.phone) || ')' ||
    E'\nالمشكلة: ' || public.tg_esc(v_r.message) || public.admin_link('reports'));
  return v_r;
end $$;

-- حل البلاغ: p_mode = 'stock' (بديل من المخزون) | 'content' (بديل بتكتبه) | 'reply' (رد بس) | 'reject'
create or replace function public.admin_resolve_report(p_report_id bigint, p_mode text, p_content text default null, p_reply text default null)
returns public.reports
language plpgsql security definer set search_path = public as $$
declare v_r public.reports; v_o public.orders; v_item public.stock_items; v_new text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_r from public.reports where id = p_report_id for update;
  if not found then raise exception 'report_not_found'; end if;
  if v_r.status <> 'open' then raise exception 'report_not_open'; end if;
  select * into v_o from public.orders where id = v_r.order_id for update;

  if p_mode = 'stock' then
    select * into v_item from public.stock_items where product_id = v_o.product_id and not is_sold order by id limit 1 for update skip locked;
    if not found then raise exception 'out_of_stock'; end if;
    update public.stock_items set is_sold = true, order_id = v_o.id where id = v_item.id;
    v_new := v_item.content;
  elsif p_mode = 'content' then
    if trim(coalesce(p_content, '')) = '' then raise exception 'content_required'; end if;
    v_new := trim(p_content);
  elsif p_mode not in ('reply', 'reject') then
    raise exception 'invalid_mode';
  end if;

  if v_new is not null then
    update public.orders set delivered_content = v_new where id = v_o.id;
  end if;
  update public.reports set
      status = case when p_mode = 'reject' then 'rejected' else 'resolved' end,
      admin_reply = nullif(trim(coalesce(p_reply, '')), ''), resolved_at = now()
    where id = v_r.id returning * into v_r;

  perform public.notify_user(v_r.user_id,
    case when v_new is not null then '🔄 بدّلنالك الحساب (طلب #' || v_o.id || ')'
         when p_mode = 'reject' then 'رد على بلاغك (طلب #' || v_o.id || ')'
         else '✅ انحلّ بلاغك (طلب #' || v_o.id || ')' end,
    coalesce(v_r.admin_reply, case when v_new is not null then 'البيانات الجديدة بصفحة طلباتي.' else '' end), '#orders');
  return v_r;
end $$;

-- ---------- إشعارات الزبون ----------
create or replace function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update public.notifications set is_read = true where user_id = auth.uid() and not is_read;
$$;

-- ---------- إعدادات الأدمن ----------
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_key not in ('telegram_bot_token', 'telegram_chat_id', 'site_url', 'currency', 'low_stock') then raise exception 'invalid_setting'; end if;
  insert into public.app_settings (key, value) values (p_key, nullif(trim(p_value), ''))
    on conflict (key) do update set value = excluded.value;
end $$;

-- الأدمن بيشوف الإعدادات بدون التوكن نفسه
create or replace function public.admin_get_settings()
returns table (has_telegram_token boolean, telegram_chat_id text, site_url text, low_stock text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query select coalesce(public.setting('telegram_bot_token'), '') <> '', public.setting('telegram_chat_id'), public.setting('site_url'), public.setting('low_stock');
end $$;

create or replace function public.admin_test_telegram() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  perform public.notify_admin('✅ <b>Explor Plus</b>' || E'\nإشعارات تلجرام شغّالة!');
end $$;

-- ---------- تذكير الانتهاء + ملخص يومي (pg_cron كل يوم) ----------
create or replace function public.daily_jobs() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_lines text := ''; v_n int := 0; v_topups int; v_orders int; v_reports int; v_sales numeric;
begin
  -- 1) ذكّر الزباين اللي اشتراكهم بينتهي خلال 3 أيام (مرة وحدة لكل طلب)
  for r in
    select o.id, o.user_id, o.product_name, o.expires_at, p.full_name, p.phone
    from public.orders o join public.profiles p on p.id = o.user_id
    where o.status = 'delivered' and o.expires_at between now() and now() + interval '3 days' and o.reminded_at is null
    order by o.expires_at
  loop
    perform public.notify_user(r.user_id, '⏰ اشتراكك بيخلص قريباً',
      r.product_name || ' بينتهي ' || to_char(r.expires_at at time zone 'Asia/Hebron', 'YYYY-MM-DD') || '. جدّد من صفحة طلباتي.', '#orders');
    update public.orders set reminded_at = now() where id = r.id;
    v_n := v_n + 1;
    if v_n <= 25 then
      v_lines := v_lines || E'\n• ' || public.tg_esc(r.full_name) || ' (' || public.tg_esc(r.phone) || ') · ' || public.tg_esc(r.product_name) || ' · ' || to_char(r.expires_at at time zone 'Asia/Hebron', 'MM-DD');
    end if;
  end loop;

  -- 2) ملخص للأدمن
  select count(*) into v_topups from public.topups where status = 'pending';
  select count(*) into v_orders from public.orders where status = 'pending';
  select count(*) into v_reports from public.reports where status = 'open';
  select coalesce(sum(price), 0) into v_sales from public.orders where status <> 'refunded' and created_at >= now() - interval '1 day';
  perform public.notify_admin('📊 <b>ملخص اليوم</b>' ||
    E'\nمبيعات آخر 24 ساعة: <b>' || public.fmt_money(v_sales) || '</b>' ||
    E'\nشحن بانتظارك: ' || v_topups || E'\nطلبات بانتظارك: ' || v_orders || E'\nبلاغات مفتوحة: ' || v_reports ||
    case when v_n > 0 then E'\n\n⏰ <b>اشتراكات بتخلص خلال 3 أيام (' || v_n || ')</b>' || v_lines else '' end ||
    public.admin_link('home'));
end $$;
revoke execute on function public.daily_jobs() from public, anon, authenticated;

-- كل يوم الساعة 9 الصبح بتوقيت فلسطين تقريباً (6 UTC)
do $$ begin
  perform cron.schedule('explor-daily-jobs', '0 6 * * *', 'select public.daily_jobs()');
exception when others then raise notice 'cron schedule skipped: %', sqlerrm;
end $$;

-- ---------- صلاحيات v2 ----------
alter table public.reports       enable row level security;
alter table public.notifications enable row level security;
alter table public.app_settings  enable row level security;

drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select using (user_id = auth.uid());

revoke execute on function public.report_issue(bigint, text) from public, anon;
revoke execute on function public.admin_resolve_report(bigint, text, text, text) from public, anon;
revoke execute on function public.mark_notifications_read() from public, anon;
revoke execute on function public.admin_set_setting(text, text) from public, anon;
revoke execute on function public.admin_get_settings() from public, anon;
revoke execute on function public.admin_test_telegram() from public, anon;
grant execute on function public.report_issue(bigint, text) to authenticated;
grant execute on function public.admin_resolve_report(bigint, text, text, text) to authenticated;
grant execute on function public.mark_notifications_read() to authenticated;
grant execute on function public.admin_set_setting(text, text) to authenticated;
grant execute on function public.admin_get_settings() to authenticated;
grant execute on function public.admin_test_telegram() to authenticated;

-- =====================================================================
--  v3: الامتيازات (خصم حسب مجموع المصروف)
-- =====================================================================

-- مجموع اللي صرفه الزبون (بدون المسترجع)
create or replace function public.customer_spent(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(price), 0) from public.orders where user_id = p_uid and status <> 'refunded';
$$;
revoke execute on function public.customer_spent(uuid) from public, anon, authenticated;

-- أعلى مستوى وصله المبلغ
create or replace function public.tier_for(p_spent numeric) returns public.loyalty_tiers
language sql stable security definer set search_path = public as $$
  select * from public.loyalty_tiers where min_spent <= p_spent order by min_spent desc limit 1;
$$;

-- ملخص الزبون: رصيده، كم صرف، عملياته، مستواه، وكم باقيله للمستوى الجاي
create or replace function public.my_summary()
returns table (balance numeric, total_spent numeric, completed_count bigint, pending_count bigint,
               tier_name text, discount_pct numeric, next_tier_name text, next_min_spent numeric, next_discount_pct numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_spent numeric; v_cur public.loyalty_tiers; v_next public.loyalty_tiers;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  v_spent := public.customer_spent(v_uid);
  v_cur := public.tier_for(v_spent);
  select * into v_next from public.loyalty_tiers where min_spent > v_spent order by min_spent limit 1;
  return query select
    (select p.balance from public.profiles p where p.id = v_uid), v_spent,
    (select count(*) from public.orders o where o.user_id = v_uid and o.status = 'delivered'),
    (select count(*) from public.orders o where o.user_id = v_uid and o.status = 'pending'),
    v_cur.name, coalesce(v_cur.discount_pct, 0), v_next.name, v_next.min_spent, v_next.discount_pct;
end $$;

-- للأدمن: مجموع مصروف كل زبون
create or replace function public.admin_customer_spent()
returns table (user_id uuid, total_spent numeric, orders_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query select o.user_id, sum(o.price), count(*) from public.orders o where o.status <> 'refunded' group by o.user_id;
end $$;

alter table public.loyalty_tiers enable row level security;
drop policy if exists tiers_select on public.loyalty_tiers;
create policy tiers_select on public.loyalty_tiers for select using (true);
drop policy if exists tiers_admin on public.loyalty_tiers;
create policy tiers_admin on public.loyalty_tiers for all using (public.is_admin()) with check (public.is_admin());

revoke execute on function public.my_summary() from public, anon;
revoke execute on function public.admin_customer_spent() from public, anon;
grant execute on function public.my_summary() to authenticated;
grant execute on function public.admin_customer_spent() to authenticated;

-- =====================================================================
--  v4: إعدادات الموقع العامة (واتساب، دفع، تواصل) + العروض والإعلانات
-- =====================================================================

-- إعدادات عامة بيقرأها الموقع (مش سرية): الأدمن بيعدّلها من لوحة الإدارة
create table if not exists public.site_config (
  key    text primary key,
  value  jsonb not null
);
insert into public.site_config (key, value) values
  ('wa_subscriptions', '"972597653989"'),
  ('wa_services',      '"972597653989"'),
  ('socials',          '{"instagram": "https://www.instagram.com/explor.ps", "facebook": "", "tiktok": "", "telegram": ""}'),
  ('hours',            '"يومياً من 10 صباحاً حتى 10 مساءً"'),
  ('payment_methods',  '[{"id": "jawwalpay", "name": "جوال باي", "details": "حوّل المبلغ على الرقم 0597653989 وارفع صورة الإيصال."}, {"id": "bank", "name": "تحويل بنكي", "details": "البنك: ……  رقم الحساب: ……  الاسم: ……"}]')
on conflict (key) do nothing;

-- العروض والإعلانات: بتظهر كشريط بالموقع والمتجر، وممكن تبعت إشعار لكل الزباين
create table if not exists public.announcements (
  id          bigint generated always as identity primary key,
  title       text not null,
  body        text,
  link        text,
  active      boolean not null default true,
  ends_at     timestamptz,
  created_at  timestamptz not null default now()
);

-- نشر عرض: بينحفظ، واختيارياً بيوصل إشعار لكل زبون
create or replace function public.admin_publish_offer(p_title text, p_body text default null, p_link text default null, p_notify boolean default true, p_days int default null)
returns public.announcements
language plpgsql security definer set search_path = public as $$
declare v_a public.announcements; v_n int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if trim(coalesce(p_title, '')) = '' then raise exception 'title_required'; end if;
  insert into public.announcements (title, body, link, ends_at)
    values (trim(p_title), nullif(trim(coalesce(p_body, '')), ''), nullif(trim(coalesce(p_link, '')), ''),
            case when p_days is not null and p_days > 0 then now() + make_interval(days => p_days) end)
    returning * into v_a;
  if p_notify then
    insert into public.notifications (user_id, title, body, link)
      select id, '🎁 ' || v_a.title, v_a.body, coalesce(v_a.link, '#shop') from public.profiles where not is_admin;
    get diagnostics v_n = row_count;
    perform public.notify_admin('📣 <b>نشرت عرض:</b> ' || public.tg_esc(v_a.title) || E'\nوصل إشعار لـ ' || v_n || ' زبون.');
  end if;
  return v_a;
end $$;

alter table public.site_config   enable row level security;
alter table public.announcements enable row level security;
drop policy if exists site_config_select on public.site_config;
create policy site_config_select on public.site_config for select using (true);
drop policy if exists site_config_admin on public.site_config;
create policy site_config_admin on public.site_config for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists announcements_select on public.announcements;
create policy announcements_select on public.announcements for select using ((active and (ends_at is null or ends_at > now())) or public.is_admin());
drop policy if exists announcements_admin on public.announcements;
create policy announcements_admin on public.announcements for all using (public.is_admin()) with check (public.is_admin());

revoke execute on function public.admin_publish_offer(text, text, text, boolean, int) from public, anon;
grant execute on function public.admin_publish_offer(text, text, text, boolean, int) to authenticated;

-- =====================================================================
--  v5: إصلاحات الفحص (إيصالات، رقم موثّق، كلمة السر، أرقام الصفحة)
-- =====================================================================

-- 1) حد لصور الإيصالات: 8MB وصور بس
update storage.buckets
   set file_size_limit = 8388608,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif','image/gif']
 where id = 'receipts';

-- 2) الإيصال لازم يكون بمجلد الزبون نفسه
alter table public.topups drop constraint if exists topups_receipt_owner;
alter table public.topups add constraint topups_receipt_owner
  check (receipt_path is null or receipt_path like (user_id::text || '/%'));

-- 3) علامة «رقم موثّق» (الأدمن بيحطها بعد ما يتأكد إنه الرقم لصاحب الحساب)
alter table public.profiles add column if not exists phone_verified boolean not null default false;

create or replace function public.admin_set_phone_verified(p_user_id uuid, p_verified boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare v_p public.profiles;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.profiles set phone_verified = p_verified where id = p_user_id returning * into v_p;
  if not found then raise exception 'profile_not_found'; end if;
  return v_p;
end $$;

-- 4) تغيير كلمة سر زبون من لوحة الأدمن (بدل SQL)
create or replace function public.admin_set_password(p_user_id uuid, p_password text)
returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'weak_password'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user_id;
  if not found then raise exception 'profile_not_found'; end if;
end $$;

-- 5) أرقام الصفحة الرئيسية بتتعدّل من لوحة الأدمن
insert into public.site_config (key, value) values ('stat_services', '"30,248"') on conflict (key) do nothing;

revoke execute on function public.admin_set_phone_verified(uuid, boolean) from public, anon;
revoke execute on function public.admin_set_password(uuid, text) from public, anon;
grant  execute on function public.admin_set_phone_verified(uuid, boolean) to authenticated;
grant  execute on function public.admin_set_password(uuid, text) to authenticated;

-- =====================================================================
--  v6: الزيارات و«نشط الآن» والتقرير اليومي
-- =====================================================================

-- كل زيارة (زائر رجع بعد غياب 30 دقيقة = زيارة جديدة)
create table if not exists public.site_visits (
  id          bigint generated always as identity primary key,
  visitor     text not null,
  path        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists site_visits_time_idx on public.site_visits (created_at);

-- آخر ظهور لكل زائر (لحساب «نشط الآن»)
create table if not exists public.site_presence (
  visitor    text primary key,
  path       text not null,
  last_seen  timestamptz not null default now()
);
create index if not exists site_presence_seen_idx on public.site_presence (last_seen);

alter table public.site_visits   enable row level security;
alter table public.site_presence enable row level security;
-- ما في policies: ما حدا بيقرأهم إلا من خلال الدوال تحت

-- الموقع بينادي هاي الدالة لما حدا يفتحه، وكل دقيقة وهو فاتح
create or replace function public.track_visit(p_visitor text, p_path text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_last timestamptz;
begin
  if p_visitor is null or p_visitor !~ '^[a-z0-9]{8,40}$' then return; end if;
  p_path := left(coalesce(nullif(trim(p_path), ''), '/'), 120);
  select last_seen into v_last from public.site_presence where visitor = p_visitor;
  if v_last is null or v_last < now() - interval '30 minutes' then
    insert into public.site_visits (visitor, path) values (p_visitor, p_path);
  end if;
  insert into public.site_presence (visitor, path, last_seen) values (p_visitor, p_path, now())
    on conflict (visitor) do update set path = excluded.path, last_seen = now();
end $$;

-- للأدمن: نشط الآن، زيارات اليوم، زوار اليوم، زيارات 7 أيام
create or replace function public.admin_traffic()
returns table (active_now bigint, visits_today bigint, visitors_today bigint, visits_7d bigint, store_now bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_start timestamptz := date_trunc('day', now() at time zone 'Asia/Hebron') at time zone 'Asia/Hebron';
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query select
    (select count(*) from public.site_presence where last_seen > now() - interval '2 minutes'),
    (select count(*) from public.site_visits where created_at >= v_start),
    (select count(distinct visitor) from public.site_visits where created_at >= v_start),
    (select count(*) from public.site_visits where created_at >= now() - interval '7 days'),
    (select count(*) from public.site_presence where last_seen > now() - interval '2 minutes' and path like '/store%');
end $$;

revoke execute on function public.track_visit(text, text) from public;
grant  execute on function public.track_visit(text, text) to anon, authenticated;
revoke execute on function public.admin_traffic() from public, anon;
grant  execute on function public.admin_traffic() to authenticated;

-- التقرير اليومي (تلجرام الساعة 9 الصبح): ضفنا الزيارات + تنظيف البيانات القديمة
create or replace function public.daily_jobs() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_lines text := ''; v_n int := 0; v_topups int; v_orders int; v_reports int; v_sales numeric;
        v_visits int; v_visitors int; v_new_users int; v_sales_n int;
begin
  -- 1) ذكّر الزباين اللي اشتراكهم بينتهي خلال 3 أيام (مرة وحدة لكل طلب)
  for r in
    select o.id, o.user_id, o.product_name, o.expires_at, p.full_name, p.phone
    from public.orders o join public.profiles p on p.id = o.user_id
    where o.status = 'delivered' and o.expires_at between now() and now() + interval '3 days' and o.reminded_at is null
    order by o.expires_at
  loop
    perform public.notify_user(r.user_id, '⏰ اشتراكك بيخلص قريباً',
      r.product_name || ' بينتهي ' || to_char(r.expires_at at time zone 'Asia/Hebron', 'YYYY-MM-DD') || '. جدّد من صفحة طلباتي.', '#orders');
    update public.orders set reminded_at = now() where id = r.id;
    v_n := v_n + 1;
    if v_n <= 25 then
      v_lines := v_lines || E'\n• ' || public.tg_esc(r.full_name) || ' (' || public.tg_esc(r.phone) || ') · ' || public.tg_esc(r.product_name) || ' · ' || to_char(r.expires_at at time zone 'Asia/Hebron', 'MM-DD');
    end if;
  end loop;

  -- 2) أرقام آخر 24 ساعة
  select count(*) into v_topups from public.topups where status = 'pending';
  select count(*) into v_orders from public.orders where status = 'pending';
  select count(*) into v_reports from public.reports where status = 'open';
  select coalesce(sum(price), 0), count(*) into v_sales, v_sales_n from public.orders where status <> 'refunded' and created_at >= now() - interval '1 day';
  select count(*), count(distinct visitor) into v_visits, v_visitors from public.site_visits where created_at >= now() - interval '1 day';
  select count(*) into v_new_users from public.profiles where created_at >= now() - interval '1 day';

  perform public.notify_admin('📊 <b>التقرير اليومي</b>' ||
    E'\n\n👀 الزيارات: <b>' || v_visits || '</b> (' || v_visitors || ' زائر)' ||
    E'\n🆕 حسابات جديدة: <b>' || v_new_users || '</b>' ||
    E'\n🛒 المبيعات: <b>' || public.fmt_money(v_sales) || '</b> (' || v_sales_n || ' طلب)' ||
    E'\n\n💰 شحن بانتظارك: ' || v_topups || E'\n⏳ طلبات بانتظارك: ' || v_orders || E'\n🚨 بلاغات مفتوحة: ' || v_reports ||
    case when v_n > 0 then E'\n\n⏰ <b>اشتراكات بتخلص خلال 3 أيام (' || v_n || ')</b>' || v_lines else '' end ||
    public.admin_link('home'));

  -- 3) تنظيف
  delete from public.site_presence where last_seen < now() - interval '1 day';
  delete from public.site_visits where created_at < now() - interval '180 days';
end $$;
revoke execute on function public.daily_jobs() from public, anon, authenticated;

-- =====================================================================
--  بعد ما تعمل حسابك من صفحة المتجر، خلّي حالك أدمن بهالسطر (غيّر الرقم):
--  update public.profiles set is_admin = true where phone = '0597653989';
-- =====================================================================
