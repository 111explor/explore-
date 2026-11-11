-- =====================================================================
--  تحديث إصلاحات الفحص (نوفمبر 2026)
--  الصقه بـ Supabase → SQL Editor → New query → Run (آمن تشغيله أكتر من مرة)
--  نفس المحتوى موجود بآخر schema.sql
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
