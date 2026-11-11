/* =====================================================================
   إعدادات متجر Explor Plus: عدّل هالملف بس
   ===================================================================== */
window.EXPLOR_CONFIG = {
  // من Supabase → Project Settings → API (الـ anon key عام وآمن يكون بالموقع)
  SUPABASE_URL: 'https://evevrfazxoncwomqvzlo.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_oTyWXt1avECLgfOz07Ap0A_TUgjU44q',

  // أرقام الواتساب (بدون + وبدون أصفار بالبداية)
  WA_SUBSCRIPTIONS: '972597653989', // رقم الاشتراكات الرقمية والشحن
  WA_SERVICES: '972597653989',      // رقم باقي الخدمات

  // مقدمة الدولة لأرقام الزباين لما تراسلهم من لوحة الأدمن
  CUSTOMER_COUNTRY_CODE: '972',

  CURRENCY: '₪',
  MIN_TOPUP: 10,

  // طرق الدفع اللي بتظهر للزبون لما يشحن رصيد
  PAYMENT_METHODS: [
    { id: 'jawwalpay', name: 'جوال باي', details: 'حوّل المبلغ على الرقم 0597653989 وارفع صورة الإيصال.' },
    { id: 'bank', name: 'تحويل بنكي', details: 'البنك: ……  رقم الحساب: ……  الاسم: ……' },
    { id: 'palpay', name: 'بال باي', details: 'حوّل على الرقم: ……' },
    { id: 'cash', name: 'كاش / مكتب', details: 'ادفع بالمكتب واكتب اسم الموظف اللي استلم.' }
  ]
};
