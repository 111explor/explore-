-- =====================================================================
--  ⚠️ بداية نظيفة: بيحذف كل الحسابات والمنتجات والمخزون والطلبات
--  ما في رجعة! نزّل نسخة احتياطية من لوحة الأدمن قبل إذا بدك.
--  بيضل: إعدادات الموقع (الأرقام، طرق الدفع، التواصل)، مستويات الخصم، العروض، إعدادات تلجرام
--  الصقه بـ Supabase → SQL Editor → New query → Run
-- =====================================================================

-- صور إيصالات الشحن
delete from storage.objects where bucket_id = 'receipts';

-- كل الحسابات (بينحذف معها: البروفايلات، الأرصدة، الطلبات، طلبات الشحن، البلاغات، الإشعارات)
delete from auth.users;

-- كل المنتجات والخدمات (بينحذف معها المخزون)
delete from public.products;

-- إحصائيات الزيارات (اختياري، شيل السطرين إذا بدك تخليهم)
delete from public.site_visits;
delete from public.site_presence;

-- تأكيد: لازم كلهم يطلعوا 0
select
  (select count(*) from auth.users)          as accounts,
  (select count(*) from public.products)     as products,
  (select count(*) from public.orders)       as orders,
  (select count(*) from public.stock_items)  as stock;
