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
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_prod from public.products where id = p_product_id and active;
  if not found then raise exception 'product_not_found'; end if;

  select balance into v_bal from public.profiles where id = v_uid for update;
  if v_bal is null then raise exception 'profile_not_found'; end if;
  if v_bal < v_prod.price then raise exception 'insufficient_balance'; end if;

  if v_prod.delivery = 'auto' then
    select * into v_item from public.stock_items
      where product_id = v_prod.id and not is_sold
      order by id
      limit 1
      for update skip locked;
    if not found then raise exception 'out_of_stock'; end if;
  end if;

  update public.profiles set balance = balance - v_prod.price where id = v_uid;

  insert into public.orders (user_id, product_id, product_name, price, status, delivered_content, customer_note, delivered_at)
  values (
    v_uid, v_prod.id, v_prod.name, v_prod.price,
    case when v_item.id is not null then 'delivered' else 'pending' end,
    v_item.content,
    nullif(trim(coalesce(p_note, '')), ''),
    case when v_item.id is not null then now() end
  )
  returning * into v_order;

  if v_item.id is not null then
    update public.stock_items set is_sold = true, order_id = v_order.id where id = v_item.id;
  end if;

  insert into public.wallet_tx (user_id, amount, kind, ref_id, note)
  values (v_uid, -v_prod.price, 'purchase', v_order.id, v_prod.name);

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

  update public.topups set status = 'approved', amount = v_amount, reviewed_at = now()
    where id = p_topup_id returning * into v_t;
  update public.profiles set balance = balance + v_amount where id = v_t.user_id;
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
  update public.orders set status = 'delivered', delivered_content = p_content, delivered_at = now()
    where id = p_order_id and status = 'pending' returning * into v_o;
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
--  بعد ما تعمل حسابك من صفحة المتجر، خلّي حالك أدمن بهالسطر (غيّر الرقم):
--  update public.profiles set is_admin = true where phone = '0597653989';
-- =====================================================================
