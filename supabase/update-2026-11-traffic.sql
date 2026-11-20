-- =====================================================================
--  تحديث: عدّاد الزيارات + «نشط الآن» + الزيارات بتقرير تلجرام اليومي
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
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
