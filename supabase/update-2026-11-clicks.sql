-- =====================================================================
--  عدّاد الطلبات لكل خدمة (نوفمبر 2026)
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
--
--  كل ما زبون يضغط «اطلبها» أو زر الواتساب، بينحسب +1 للخدمة (بدون أي بيانات عن الزبون).
--  بتشوف بلوحة الإدارة ← الرئيسية: أي خدمة أكتر طلباً آخر 7 و 30 يوم.
-- =====================================================================

create table if not exists public.order_clicks (
  day     date not null default (now() at time zone 'Asia/Hebron')::date,
  service text not null,
  clicks  integer not null default 0,
  primary key (day, service)
);
alter table public.order_clicks enable row level security;
-- ما في سياسات: الكتابة بس عن طريق track_order_click، والقراءة عن طريق admin_order_clicks

create or replace function public.track_order_click(p_service text) returns void
language plpgsql security definer set search_path = public as $$
declare v_day date := (now() at time zone 'Asia/Hebron')::date;
begin
  if p_service is null or p_service !~ '^[a-z_]{2,20}$' then return; end if;
  -- ضد الإغراق: حد أقصى 5000 ضغطة باليوم لكل الخدمات
  if (select coalesce(sum(clicks), 0) from public.order_clicks where day = v_day) >= 5000 then return; end if;
  insert into public.order_clicks (day, service, clicks) values (v_day, p_service, 1)
    on conflict (day, service) do update set clicks = public.order_clicks.clicks + 1;
end $$;

create or replace function public.admin_order_clicks()
returns table (service text, d7 bigint, d30 bigint, total bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_day date := (now() at time zone 'Asia/Hebron')::date;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query
    select c.service,
           coalesce(sum(c.clicks) filter (where c.day > v_day - 7), 0)::bigint,
           coalesce(sum(c.clicks) filter (where c.day > v_day - 30), 0)::bigint,
           sum(c.clicks)::bigint
    from public.order_clicks c group by c.service order by 3 desc, 4 desc;
end $$;

revoke execute on function public.track_order_click(text) from public;
revoke execute on function public.admin_order_clicks() from public, anon;
grant execute on function public.track_order_click(text) to anon, authenticated;
grant execute on function public.admin_order_clicks() to authenticated;
