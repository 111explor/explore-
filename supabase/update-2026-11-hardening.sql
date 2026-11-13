-- =====================================================================
--  تقوية الحماية (نوفمبر 2026). شغّله بعد update-2026-11-alerts.sql
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
--
--  1) مصدر كل تعديل بالإشعارات: لوحة الإدارة / الموقع / بوت تلجرام / Supabase مباشرة
--  2) حد لعدّاد الزيارات (track_visit) ضد الإغراق
--  3) product_stock بتعرض مخزون المنتجات الظاهرة بس
--  4) صلاحيات EXECUTE: مسكّرة على الكل، ومنفتحة بس للي لازم
--  5) كلمة السر 8 أحرف على الأقل، والتحقق الثنائي (2FA) للأدمن إجباري بعد ما يفعّله
--  6) حد 3 طلبات شحن معلّقة لكل زبون (ضد سبام الإيصالات)
-- =====================================================================

-- ---------- 1) مصدر التعديل ----------
create or replace function public.actor_label() returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_p public.profiles;
  v_src text := nullif(current_setting('app.source', true), '');
  v_role text;
  v_who text;
begin
  if v_uid is not null then
    select * into v_p from public.profiles where id = v_uid;
    v_who := coalesce(nullif(v_p.full_name, ''), '—') || ' (' || coalesce(v_p.phone, '?') || ')';
  end if;
  if v_src = 'bot' then return '🤖 بوت تلجرام · ' || coalesce(v_who, '—'); end if;
  if v_src = 'cron' then return '⏰ مهمة تلقائية'; end if;
  if v_uid is not null then
    return case when v_p.is_admin then '🖥 لوحة الإدارة · ' else '🌐 الموقع · ' end || v_who;
  end if;
  begin v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'; exception when others then v_role := null; end;
  if v_role = 'service_role' then return '🔑 مفتاح service_role (خارج الموقع)'; end if;
  return '⚠️ Supabase مباشرة (Dashboard أو SQL)';
end $$;

-- الإشعار بيكتب «المصدر:» بدل «بواسطة:»
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
      E'\n<i>المصدر: ' || public.tg_esc(v_actor) || '</i>');
  end if;
exception when others then
  raise notice 'audit failed: %', sqlerrm;
end $$;

-- ---------- 2) حد لعدّاد الزيارات ----------
create or replace function public.track_visit(p_visitor text, p_path text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_last timestamptz;
begin
  if p_visitor is null or p_visitor !~ '^[a-z0-9]{8,40}$' then return; end if;
  p_path := left(coalesce(nullif(trim(p_path), ''), '/'), 120);
  if p_path !~ '^/[A-Za-z0-9/_.#?=&-]*$' then p_path := '/'; end if;
  select last_seen into v_last from public.site_presence where visitor = p_visitor;
  -- نفس الزائر: تحديث وحدة كل 15 ثانية بالكتير
  if v_last is not null and v_last > now() - interval '15 seconds' then return; end if;
  -- زائر جديد: بنوقف لو في إغراق (أكتر من 300 زائر جديد بآخر دقيقة)
  if v_last is null and (select count(*) from public.site_presence where last_seen > now() - interval '1 minute') > 300 then return; end if;
  if v_last is null or v_last < now() - interval '30 minutes' then
    -- وحد أقصى 2000 زيارة بالساعة
    if (select count(*) from public.site_visits where created_at > now() - interval '1 hour') < 2000 then
      insert into public.site_visits (visitor, path) values (p_visitor, p_path);
    end if;
  end if;
  insert into public.site_presence (visitor, path, last_seen) values (p_visitor, p_path, now())
    on conflict (visitor) do update set path = excluded.path, last_seen = now();
end $$;
-- التنظيف موجود بـ daily_jobs: المتواجدين أقدم من يوم، والزيارات أقدم من 180 يوم

-- ---------- 3) المخزون للمنتجات الظاهرة بس ----------
create or replace function public.product_stock()
returns table (product_id bigint, available bigint)
language sql stable security definer set search_path = public as $$
  select s.product_id, count(*) from public.stock_items s
  join public.products p on p.id = s.product_id and (p.active or public.is_admin())
  where not s.is_sold group by s.product_id;
$$;

-- ---------- 5) الأدمن: التحقق الثنائي إجباري إذا مفعّل ----------
-- إذا الأدمن فعّل 2FA، ما بيقدر يعمل ولا عملية إلا بعد ما يدخل الرمز (جلسة aal2)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
    and (
      coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
    );
$$;

create or replace function public.admin_set_password(p_user_id uuid, p_password text)
returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'weak_password'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user_id;
  if not found then raise exception 'profile_not_found'; end if;
end $$;

-- ---------- 6) حد طلبات الشحن المعلّقة ----------
create or replace function public.topups_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.topups where user_id = new.user_id and status = 'pending') >= 3 then
    raise exception 'too_many_pending_topups';
  end if;
  return new;
end $$;
drop trigger if exists topups_limit on public.topups;
create trigger topups_limit before insert on public.topups for each row execute function public.topups_limit();

-- ---------- 4) صلاحيات EXECUTE ----------
-- بنسكّر كل الدوال عن الكل، وبنفتح بس اللي الموقع بيحتاجه
revoke execute on all functions in schema public from public, anon, authenticated;

-- الزوار (بدون حساب)
grant execute on function public.is_admin()                 to anon, authenticated;  -- سياسات الحماية بتستخدمها
grant execute on function public.product_stock()            to anon, authenticated;
grant execute on function public.track_visit(text, text)    to anon, authenticated;

-- الزبون
grant execute on function public.purchase(bigint, text)      to authenticated;
grant execute on function public.report_issue(bigint, text)  to authenticated;
grant execute on function public.my_summary()                to authenticated;
grant execute on function public.mark_notifications_read()   to authenticated;

-- الأدمن (كل دالة بتفحص is_admin بأول سطر)
grant execute on function public.admin_approve_topup(bigint, numeric)               to authenticated;
grant execute on function public.admin_reject_topup(bigint, text)                   to authenticated;
grant execute on function public.admin_deliver_order(bigint, text)                  to authenticated;
grant execute on function public.admin_refund_order(bigint, text)                   to authenticated;
grant execute on function public.admin_adjust_balance(uuid, numeric, text)          to authenticated;
grant execute on function public.admin_add_stock(bigint, text)                      to authenticated;
grant execute on function public.admin_resolve_report(bigint, text, text, text)     to authenticated;
grant execute on function public.admin_customer_spent()                             to authenticated;
grant execute on function public.admin_publish_offer(text, text, text, boolean, int) to authenticated;
grant execute on function public.admin_set_setting(text, text)                      to authenticated;
grant execute on function public.admin_get_settings()                               to authenticated;
grant execute on function public.admin_test_telegram()                              to authenticated;
grant execute on function public.admin_set_password(uuid, text)                     to authenticated;
grant execute on function public.admin_set_phone_verified(uuid, boolean)            to authenticated;
grant execute on function public.admin_traffic()                                    to authenticated;
grant execute on function public.admin_alert_prefs()                                to authenticated;
-- دوال بوت المتجر (إذا انشغّل ملفه): لوحة الإدارة للأدمن، والباقي لسيرفر البوت بس
do $$
declare f text;
begin
  foreach f in array array['admin_setup_shop_bot(text)', 'admin_bot_status()'] loop
    if to_regprocedure('public.' || f) is not null then execute format('grant execute on function public.%s to authenticated', f); end if;
  end loop;
end $$;

-- الدوال الجديدة بالمستقبل: مسكّرة تلقائياً لحتى نفتحها بإيدنا
do $$ begin
  alter default privileges in schema public revoke execute on functions from anon, authenticated;
  alter default privileges revoke execute on functions from public;
exception when others then raise notice 'default privileges skipped: %', sqlerrm;
end $$;

select public.audit('🛡 <b>تحديث الحماية انطبّق</b>', 'صلاحيات الدوال، حد الزيارات، 2FA للأدمن، وحد طلبات الشحن.', true, 'إعداد النظام');
