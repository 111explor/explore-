/* Explor Plus: shared helpers for store.html and admin.html */
(function () {
  const C = window.EXPLOR_CONFIG || {};
  const configured = !!(C.SUPABASE_URL && C.SUPABASE_ANON_KEY && window.supabase);
  const sb = configured ? window.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_ANON_KEY) : null;

  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // رقم الجوال: بنحوّله لصيغة محلية 05xxxxxxxx
  function normPhone(p) {
    let d = String(p || '').replace(/\D/g, '');
    if (d.startsWith('00')) d = d.slice(2);
    if (d.startsWith('972') || d.startsWith('970')) d = '0' + d.slice(3);
    if (d && !d.startsWith('0')) d = '0' + d;
    return d;
  }
  const validPhone = (p) => /^0\d{8,9}$/.test(normPhone(p));
  // Supabase بيحتاج إيميل، فبنعمل إيميل داخلي من رقم الجوال (ما بينبعتله شي)
  const phoneEmail = (p) => `p${normPhone(p)}@phone.explorplus.app`;
  const intlPhone = (p) => (C.CUSTOMER_COUNTRY_CODE || '972') + normPhone(p).replace(/^0/, '');

  const money = (n) => `${Number(n || 0).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 2 })} ${C.CURRENCY || '₪'}`;
  const dateFmt = (() => { try { return new Intl.DateTimeFormat('ar-u-nu-latn', { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return null; } })();
  const fmtDate = (d) => (d ? (dateFmt ? dateFmt.format(new Date(d)) : new Date(d).toLocaleString()) : '');
  const waLink = (num, text) => `https://wa.me/${num}${text ? '?text=' + encodeURIComponent(text) : ''}`;

  const ERRORS = {
    insufficient_balance: 'رصيدك ما بيكفي. اشحن محفظتك وارجع كمّل الشراء.',
    out_of_stock: 'خلصت الكمية من هالمنتج حالياً. جرّب بعد شوي أو راسلنا.',
    product_not_found: 'هالمنتج مش متوفر حالياً.',
    not_authenticated: 'لازم تسجّل دخول أول.',
    forbidden: 'هاي العملية للإدارة بس.',
    topup_already_reviewed: 'طلب الشحن هاد انراجع من قبل.',
    topup_not_pending: 'طلب الشحن هاد انراجع من قبل.',
    order_not_pending: 'الطلب هاد مش قيد التنفيذ.',
    order_already_refunded: 'الطلب هاد مسترجع من قبل.',
    invalid_amount: 'المبلغ غير صحيح.',
    'Invalid login credentials': 'رقم الجوال أو كلمة السر غلط.',
    'User already registered': 'هالرقم مسجّل من قبل. سجّل دخول بدل ما تعمل حساب جديد.',
    'already registered': 'هالرقم مسجّل من قبل. سجّل دخول بدل ما تعمل حساب جديد.',
    'duplicate key': 'هالرقم مسجّل من قبل.',
    'Password should be at least': 'كلمة السر لازم تكون 6 أحرف أو أكثر.',
    'Email not confirmed': 'الحساب بحاجة تفعيل. راسل الإدارة.',
    'Failed to fetch': 'في مشكلة بالاتصال. تأكد من النت وجرّب كمان مرة.',
    'rate limit': 'محاولات كثيرة. استنى دقيقة وجرّب.'
  };
  function errMsg(e) {
    const m = (e && (e.message || e.error_description || e.msg)) || String(e || '');
    for (const k in ERRORS) if (m.includes(k)) return ERRORS[k];
    return 'صار خطأ: ' + m;
  }

  let toastTimer;
  function toast(msg, type = 'ok') {
    let el = $('#toast');
    if (!el) { el = document.createElement('div'); el.id = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.className = 'toast ' + type; el.textContent = msg; el.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.hidden = true; }, 3800);
  }

  async function copy(text, btn) {
    try { await navigator.clipboard.writeText(text); toast('تم النسخ ✓'); }
    catch (e) {
      const code = btn && btn.closest('.secret') && btn.closest('.secret').querySelector('code');
      if (code) { const r = document.createRange(); r.selectNodeContents(code); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
      toast('حدّد النص وانسخه يدوياً', 'err');
    }
  }

  // تأكيد بضغطتين بدل confirm()
  function twoStep(btn, fn) {
    if (btn.dataset.armed) { delete btn.dataset.armed; btn.textContent = btn.dataset.label; fn(); return; }
    btn.dataset.label = btn.textContent; btn.dataset.armed = '1'; btn.textContent = 'اضغط كمان مرة للتأكيد';
    setTimeout(() => { if (btn.dataset.armed) { delete btn.dataset.armed; btn.textContent = btn.dataset.label; } }, 3500);
  }

  const STATUS = {
    pending: ['قيد التنفيذ', 'warn'], delivered: ['تم التسليم', 'ok'], refunded: ['مسترجع', 'info'],
    approved: ['مقبول', 'ok'], rejected: ['مرفوض', 'bad']
  };
  const pill = (s, kind) => { const [l, c] = (kind === 'topup' && s === 'pending') ? ['بانتظار المراجعة', 'warn'] : (STATUS[s] || [s, '']); return `<span class="badge ${c}">${esc(l)}</span>`; };
  const TX_KIND = { topup: 'شحن رصيد', purchase: 'شراء', refund: 'استرجاع', adjust: 'تعديل من الإدارة' };

  function setupNotice(el) {
    el.innerHTML = `<div class="card setup-note">
      <h2>المتجر لسا مش مربوط بقاعدة البيانات</h2>
      <p class="muted">لتشغيله:</p>
      <ol>
        <li>اعمل مشروع مجاني على supabase.com</li>
        <li>من SQL Editor شغّل ملف <code>supabase/schema.sql</code></li>
        <li>من Authentication → Providers → Email: طفّي "Confirm email"</li>
        <li>انسخ Project URL و anon key وحطهم بملف <code>assets/config.js</code></li>
      </ol>
    </div>`;
  }

  async function getProfile() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return null;
    const { data, error } = await sb.from('profiles').select('*').eq('id', session.user.id).single();
    if (error) throw error;
    return data;
  }

  async function signIn(phone, password) {
    const { error } = await sb.auth.signInWithPassword({ email: phoneEmail(phone), password });
    if (error) throw error;
  }
  async function signUp(name, phone, password) {
    const { data, error } = await sb.auth.signUp({
      email: phoneEmail(phone), password,
      options: { data: { full_name: name.trim(), phone: normPhone(phone) } }
    });
    if (error) throw error;
    if (!data.session) await signIn(phone, password); // إذا التفعيل بالإيميل مطفّى بيرجع session مباشرة
  }

  window.XP = { C, sb, configured, $, $$, esc, normPhone, validPhone, phoneEmail, intlPhone, money, fmtDate, waLink, errMsg, toast, copy, twoStep, pill, TX_KIND, setupNotice, getProfile, signIn, signUp };
})();
