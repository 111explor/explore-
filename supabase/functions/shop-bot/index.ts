// Explor Plus: بوت تلجرام للمتجر (Supabase Edge Function اسمها shop-bot)
//
// البوت بيشتغل على نفس قاعدة بيانات الموقع: نفس الحسابات والأرصدة والمخزون والأسعار.
// كل منطق الفلوس والمخزون جوّا قاعدة البيانات (دوال bot_* اللي بتنادي purchase و report_issue
// تبع الموقع نفسها). هالملف بس بيستقبل رسائل تلجرام وبيرد عليها.
//
// التركيب: شوف README، قسم «بوت المتجر». ولازم تطفي «Verify JWT» لهالـ function.

type Json = any;

export type Deps = {
  rpc: (fn: string, args?: Record<string, unknown>) => Promise<Json>;
  tg: (method: string, body: Record<string, unknown>) => Promise<Json>;
  createUser: (phone: string, name: string) => Promise<void>;
  downloadFile: (fileId: string) => Promise<{ bytes: Uint8Array; type: string } | null>;
  upload: (path: string, bytes: Uint8Array, type: string) => Promise<void>;
};

// ---------- نصوص وأدوات ----------
const esc = (v: unknown) => String(v ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' } as Record<string, string>)[c]);
const money = (n: unknown) => `${Number(Number(n || 0).toFixed(2)).toString()} ₪`;
const toEnDigits = (s: string) => s.replace(/[٠-٩]/g, (d) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d))).replace(/[۰-۹]/g, (d) => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)));
const fmtDate = (iso: string) => { const d = new Date(iso); return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`; };

const BTN = { shop: '🛒 المتجر', wallet: '💰 محفظتي', orders: '📦 طلباتي', contact: '☎️ تواصل معنا' };
const MAIN_KB = { keyboard: [[{ text: BTN.shop }, { text: BTN.wallet }], [{ text: BTN.orders }, { text: BTN.contact }]], resize_keyboard: true, is_persistent: true };
const LINK_KB = { keyboard: [[{ text: '📱 شارك رقمي وابدأ', request_contact: true }]], resize_keyboard: true, one_time_keyboard: true };
const STATUS: Record<string, string> = { pending: '⏳ قيد التنفيذ', delivered: '✅ انسلّم', refunded: '↩️ مسترجع' };
const TX: Record<string, string> = { topup: 'شحن', purchase: 'شراء', refund: 'استرجاع', adjust: 'تعديل' };

const ERRORS: Record<string, string> = {
  insufficient_balance: 'رصيدك ما بيكفي. اشحن من «💰 محفظتي».',
  out_of_stock: 'للأسف هالمنتج نفد هلأ. جرّب بعد شوي.',
  product_not_found: 'هالمنتج مش متوفر.',
  too_fast: 'طلبك وصل، استنّى ثواني قبل ما تطلب نفس المنتج مرة تانية.',
  too_many_pending_topups: 'عندك 3 طلبات شحن لسا بالمراجعة. استنّى نراجعهم.',
  reference_required: 'لازم تكتب اسم صاحب التحويل أو الرقم اللي حوّلت منه.',
  invalid_amount: 'المبلغ مش صحيح.',
  report_already_open: 'في بلاغ مفتوح على هالطلب، رح نرد عليك قريباً.',
  order_not_delivered: 'بتقدر تبلّغ بس عن طلب انسلّم.',
  message_required: 'اكتب المشكلة بجملة واضحة.',
  invalid_phone: 'الرقم مش واضح. تواصل معنا على واتساب.',
  not_linked: 'لازم تشارك رقمك أول.',
};
const errText = (e: unknown) => {
  const m = String((e as Error)?.message || e || '');
  const key = Object.keys(ERRORS).find((k) => m.includes(k));
  return key ? ERRORS[key] : 'صار خطأ، جرّب مرة تانية أو تواصل معنا.';
};

// ---------- البوت ----------
export function makeBot(d: Deps) {
  const send = (chat: number, text: string, markup?: unknown) =>
    d.tg('sendMessage', { chat_id: chat, text, parse_mode: 'HTML', disable_web_page_preview: true, ...(markup ? { reply_markup: markup } : {}) });
  const setState = (chat: number, state: Record<string, unknown>) => d.rpc('bot_set_state', { p_chat: chat, p_state: state });

  async function mainMenu(chat: number, me: Json, intro?: string) {
    await setState(chat, {});
    await send(chat, (intro ? intro + '\n\n' : '') + `أهلاً ${esc(me.name || '')} 👋\nرصيدك: <b>${money(me.balance)}</b>\n\nاختار من القائمة تحت 👇`, MAIN_KB);
  }

  async function showShop(chat: number) {
    const list: Json[] = await d.rpc('bot_products', { p_chat: chat });
    if (!list.length) return send(chat, 'ما في منتجات متوفرة هلأ.');
    const rows = list.map((p) => [{
      text: `${p.name} · ${money(p.final)}${p.delivery === 'auto' ? (Number(p.available) > 0 ? ` · متوفر ${p.available}` : ' · نفدت') : ''}`,
      callback_data: `p:${p.id}`,
    }]);
    const disc = Number(list[0].discount) > 0 ? `\n⭐ الأسعار بعد خصمك ${list[0].discount}%` : '';
    return send(chat, `🛒 <b>المتجر</b>${disc}\nاختار المنتج:`, { inline_keyboard: rows });
  }

  async function showProduct(chat: number, me: Json, id: number) {
    const p = ((await d.rpc('bot_products', { p_chat: chat })) as Json[]).find((x) => x.id === id);
    if (!p) return send(chat, ERRORS.product_not_found);
    let text = `<b>${esc(p.name)}</b>${p.duration ? ' · ' + esc(p.duration) : ''}\n`;
    if (p.description) text += `${esc(p.description)}\n`;
    text += `\nالسعر: ${Number(p.discount) > 0 ? `<s>${money(p.price)}</s> <b>${money(p.final)}</b> (خصم ${p.discount}%)` : `<b>${money(p.final)}</b>`}`;
    text += `\nرصيدك: ${money(me.balance)}`;
    text += p.delivery === 'auto' ? '\n⚡ تسليم فوري بعد الدفع' : '\n🕐 تنفيذ يدوي بعد الدفع';
    const rows: Json[] = [];
    if (p.delivery === 'auto' && Number(p.available) <= 0) text += '\n\n❌ نفدت حالياً';
    else if (Number(me.balance) < Number(p.final)) {
      text += `\n\nرصيدك ما بيكفي. ناقصك <b>${money(Number(p.final) - Number(me.balance))}</b>`;
      rows.push([{ text: '➕ شحن رصيد', callback_data: 'tu' }]);
    } else rows.push([{ text: `✅ ادفع ${money(p.final)} من رصيدك`, callback_data: `b:${p.id}` }]);
    rows.push([{ text: '⬅️ رجوع للمتجر', callback_data: 'shop' }]);
    return send(chat, text, { inline_keyboard: rows });
  }

  async function buy(chat: number, id: number, note: string | null, msg?: Json) {
    if (msg) await d.tg('editMessageReplyMarkup', { chat_id: chat, message_id: msg.message_id, reply_markup: { inline_keyboard: [] } }).catch(() => {});
    try {
      const o = await d.rpc('bot_purchase', { p_chat: chat, p_product_id: id, p_note: note });
      await setState(chat, {});
      if (o.status === 'delivered') {
        return send(chat, `✅ <b>تم الشراء! طلب #${o.id}</b>\n${esc(o.product_name)} · ${money(o.price)}\n\n<code>${esc(o.content)}</code>\n` +
          (o.expires_at ? `\nينتهي: ${fmtDate(o.expires_at)}` : '') + `\nرصيدك صار: <b>${money(o.balance)}</b>\n\nإذا في أي مشكلة: «📦 طلباتي» ← الطلب ← بلّغ.`, MAIN_KB);
      }
      return send(chat, `⏳ <b>وصلنا طلبك #${o.id}</b>\n${esc(o.product_name)} · ${money(o.price)}\nرح ننفذه بأقرب وقت، وبيوصلك إشعار هون.\nرصيدك صار: <b>${money(o.balance)}</b>`, MAIN_KB);
    } catch (e) {
      await setState(chat, {});
      return send(chat, '❌ ' + errText(e), MAIN_KB);
    }
  }

  async function showWallet(chat: number) {
    const w = await d.rpc('bot_wallet', { p_chat: chat });
    let text = `💰 <b>محفظتي</b>\nالرصيد: <b>${money(w.balance)}</b>\nمجموع مشترياتك: ${money(w.spent)}`;
    if (w.tier) text += `\n⭐ مستواك: ${esc(w.tier)} · خصم ${w.discount}% على كل شي`;
    if (w.next_tier) text += `\nباقيلك ${money(Number(w.next_min) - Number(w.spent))} لمستوى ${esc(w.next_tier)} (خصم ${w.next_discount}%)`;
    if (Number(w.pending_topups) > 0) text += `\n\n⏳ عندك ${w.pending_topups} طلب شحن بالمراجعة`;
    return send(chat, text, { inline_keyboard: [[{ text: '➕ شحن رصيد', callback_data: 'tu' }], [{ text: '📜 آخر الحركات', callback_data: 'tx' }]] });
  }

  async function showTx(chat: number) {
    const w = await d.rpc('bot_wallet', { p_chat: chat });
    const tx: Json[] = w.tx || [];
    if (!tx.length) return send(chat, 'ما في حركات لسا.');
    return send(chat, '📜 <b>آخر الحركات</b>\n' + tx.map((t) =>
      `${Number(t.amount) > 0 ? '🟢 +' : '🔴 '}${money(t.amount)} · ${TX[t.kind] || t.kind}${t.note ? ' · ' + esc(t.note) : ''} · ${fmtDate(t.created_at)}`).join('\n'));
  }

  async function startTopup(chat: number) {
    const methods: Json[] = await d.rpc('bot_payment_methods');
    if (!methods.length) return send(chat, 'لشحن الرصيد تواصل معنا على واتساب ☎️');
    return send(chat, '➕ <b>شحن رصيد</b>\nاختار طريقة الدفع:', { inline_keyboard: methods.map((m, i) => [{ text: m.name, callback_data: `tm:${i}` }]) });
  }

  async function showOrders(chat: number) {
    const list: Json[] = await d.rpc('bot_orders', { p_chat: chat });
    if (!list.length) return send(chat, 'ما في طلبات لسا. ابدأ من «🛒 المتجر».');
    return send(chat, '📦 <b>طلباتي</b> (آخر 10)\nاضغط على الطلب لتشوف تفاصيله:', {
      inline_keyboard: list.map((o) => [{ text: `#${o.id} · ${o.product_name} · ${STATUS[o.status] || o.status}`, callback_data: `o:${o.id}` }]),
    });
  }

  async function showOrder(chat: number, id: number) {
    const o = ((await d.rpc('bot_orders', { p_chat: chat })) as Json[]).find((x) => x.id === id);
    if (!o) return send(chat, 'الطلب مش موجود.');
    let text = `<b>طلب #${o.id}</b>\n${esc(o.product_name)} · ${money(o.price)}\nالحالة: ${STATUS[o.status] || o.status}\nالتاريخ: ${fmtDate(o.created_at)}`;
    if (o.content && o.status === 'delivered') text += `\n\n<code>${esc(o.content)}</code>`;
    if (o.expires_at) text += `\n\nينتهي: ${fmtDate(o.expires_at)}`;
    const rows: Json[] = [];
    if (o.status === 'delivered' && !o.has_open_report) rows.push([{ text: '🚨 بلّغ عن مشكلة', callback_data: `r:${o.id}` }]);
    if (o.has_open_report) text += '\n\n🚨 في بلاغ مفتوح، رح نرد عليك قريباً.';
    rows.push([{ text: '⬅️ طلباتي', callback_data: 'orders' }]);
    return send(chat, text, { inline_keyboard: rows });
  }

  async function showContact(chat: number) {
    const c = await d.rpc('bot_contact');
    const rows: Json[] = [];
    const wa = (n: string) => `https://wa.me/${String(n).replace(/\D/g, '')}`;
    if (c.wa_services) rows.push([{ text: '💬 واتساب الخدمات', url: wa(c.wa_services) }]);
    if (c.wa_subscriptions) rows.push([{ text: '💬 واتساب الاشتراكات', url: wa(c.wa_subscriptions) }]);
    const site = String(c.site || 'https://explorplus.online').replace(/\/$/, '');
    rows.push([{ text: '🔗 كل حساباتنا', url: `${site}/contact.html` }], [{ text: '🌐 الموقع', url: site }]);
    return send(chat, '☎️ <b>تواصل معنا</b>\nيومياً من 10 الصبح لـ 10 الليل.', { inline_keyboard: rows });
  }

  async function finishTopup(chat: number, me: Json, st: Json, receipt: string | null) {
    try {
      const t = await d.rpc('bot_create_topup', { p_chat: chat, p_amount: st.amount, p_method: st.method, p_reference: st.ref, p_receipt_path: receipt });
      await setState(chat, {});
      return send(chat, `✅ <b>وصلنا طلب الشحن #${t.id}</b>\nالمبلغ: ${money(t.amount)}\nرح نراجعه ونضيف الرصيد، وبيوصلك إشعار هون.`, MAIN_KB);
    } catch (e) {
      await setState(chat, {});
      return send(chat, '❌ ' + errText(e), MAIN_KB);
    }
  }

  // ---------- استقبال الرسائل ----------
  async function onMessage(msg: Json) {
    const chat: number = msg.chat.id;
    const text = String(msg.text || '').trim();
    let me = await d.rpc('bot_get', { p_chat: chat });

    // ربط الحساب برقم الهاتف
    if (msg.contact) {
      if (msg.contact.user_id !== msg.from?.id) return send(chat, 'شارك رقمك إنت، مش رقم حدا تاني 🙏', LINK_KB);
      const name = [msg.from?.first_name, msg.from?.last_name].filter(Boolean).join(' ').slice(0, 60) || 'زبون';
      let r = await d.rpc('bot_link', { p_chat: chat, p_phone: msg.contact.phone_number, p_username: msg.from?.username || null });
      let intro = '✅ انربط حسابك بالمتجر.';
      if (r.need_account) {
        await d.createUser(r.phone, name);
        r = await d.rpc('bot_link', { p_chat: chat, p_phone: msg.contact.phone_number, p_username: msg.from?.username || null });
        intro = '🎉 أهلاً فيك! عملنالك حساب جديد برقمك.';
      }
      if (!r.ok) return send(chat, ERRORS.invalid_phone);
      me = await d.rpc('bot_get', { p_chat: chat });
      return mainMenu(chat, me, intro + '\nنفس حسابك ورصيدك بالموقع explorplus.online');
    }

    if (!me.linked) {
      return send(chat, 'أهلاً فيك بمتجر <b>Explor Plus</b> 👋\nاشتراكات رقمية بتسليم فوري.\n\nعشان تبدأ، اضغط الزر تحت وشارك رقمك. إذا عندك حساب بالموقع بنفس الرقم، بينربط تلقائياً بنفس الرصيد.', LINK_KB);
    }

    const st = me.state || {};
    if (text === '/cancel' || text === 'إلغاء') { await setState(chat, {}); return send(chat, 'انلغت العملية.', MAIN_KB); }
    if (text === '/start' || text === '/menu') return mainMenu(chat, me);
    if (text === BTN.shop || text === '/shop') { await setState(chat, {}); return showShop(chat); }
    if (text === BTN.wallet || text === '/wallet') { await setState(chat, {}); return showWallet(chat); }
    if (text === BTN.orders || text === '/orders') { await setState(chat, {}); return showOrders(chat); }
    if (text === BTN.contact) { await setState(chat, {}); return showContact(chat); }

    // خطوات العمليات
    if (st.step === 'note' && text) {
      await setState(chat, { step: 'note_ok', pid: st.pid, note: text.slice(0, 500) });
      return send(chat, `تمام. التفاصيل:\n<i>${esc(text.slice(0, 500))}</i>\n\nأكّد الطلب:`, { inline_keyboard: [[{ text: '✅ تأكيد ودفع', callback_data: `bn:${st.pid}` }], [{ text: '✖️ إلغاء', callback_data: 'cancel' }]] });
    }
    if (st.step === 'tu_amount' && text) {
      const amount = Number(toEnDigits(text).replace(/[^\d.]/g, ''));
      if (!(amount > 0) || amount > 100000) return send(chat, 'اكتب المبلغ بالأرقام بس، مثلاً 50');
      await setState(chat, { step: 'tu_ref', method: st.method, amount });
      return send(chat, `المبلغ: <b>${money(amount)}</b>\nاكتب <b>اسم صاحب التحويل أو الرقم اللي حوّلت منه</b>:`);
    }
    if (st.step === 'tu_ref' && text) {
      if (text.length < 2) return send(chat, ERRORS.reference_required);
      await setState(chat, { step: 'tu_receipt', method: st.method, amount: st.amount, ref: text.slice(0, 120) });
      return send(chat, 'آخر خطوة: ابعت <b>صورة الإيصال</b> 📸', { inline_keyboard: [[{ text: 'ما عندي إيصال', callback_data: 'tu_skip' }]] });
    }
    if (st.step === 'tu_receipt' && (msg.photo || msg.document)) {
      const file = msg.photo ? msg.photo[msg.photo.length - 1] : msg.document;
      if (msg.document && !/^image\//.test(msg.document.mime_type || '')) return send(chat, 'ابعت الإيصال كصورة 📸');
      if (Number(file.file_size || 0) > 8 * 1024 * 1024) return send(chat, 'الصورة كبيرة كتير (أكتر من 8MB).');
      const f = await d.downloadFile(file.file_id);
      if (!f) return send(chat, 'ما قدرنا ننزّل الصورة، جرّب تبعتها مرة تانية.');
      const ext = f.type === 'image/png' ? 'png' : f.type === 'image/webp' ? 'webp' : 'jpg';
      const path = `${me.uid}/tg-${Date.now()}.${ext}`;
      await d.upload(path, f.bytes, f.type);
      return finishTopup(chat, me, st, path);
    }
    if (st.step === 'report' && text) {
      try {
        const r = await d.rpc('bot_report', { p_chat: chat, p_order_id: st.oid, p_message: text.slice(0, 1000) });
        await setState(chat, {});
        return send(chat, `✅ وصلنا بلاغك #${r.id}. رح نرد عليك هون بأقرب وقت.`, MAIN_KB);
      } catch (e) { await setState(chat, {}); return send(chat, '❌ ' + errText(e), MAIN_KB); }
    }
    return mainMenu(chat, me);
  }

  async function onCallback(cb: Json) {
    const chat: number = cb.message?.chat?.id;
    const data = String(cb.data || '');
    await d.tg('answerCallbackQuery', { callback_query_id: cb.id }).catch(() => {});
    if (!chat) return;
    const me = await d.rpc('bot_get', { p_chat: chat });
    if (!me.linked) return send(chat, 'لازم تشارك رقمك أول.', LINK_KB);
    const [cmd, arg] = data.split(':');
    const n = Number(arg);
    if (cmd === 'shop') return showShop(chat);
    if (cmd === 'orders') return showOrders(chat);
    if (cmd === 'cancel') { await setState(chat, {}); return send(chat, 'انلغت العملية.', MAIN_KB); }
    if (cmd === 'p') return showProduct(chat, me, n);
    if (cmd === 'b') {
      const p = ((await d.rpc('bot_products', { p_chat: chat })) as Json[]).find((x) => x.id === n);
      if (!p) return send(chat, ERRORS.product_not_found);
      if (p.delivery === 'manual') {
        await setState(chat, { step: 'note', pid: n });
        return send(chat, `${esc(p.name)}\nابعت <b>رابط صفحتك أو أي تفاصيل بنحتاجها</b> لننفذ الطلب:`);
      }
      return buy(chat, n, null, cb.message);
    }
    if (cmd === 'bn') {
      const st = me.state || {};
      if (st.step !== 'note_ok' || st.pid !== n) return send(chat, 'ابدأ الطلب من جديد من «🛒 المتجر».');
      return buy(chat, n, st.note, cb.message);
    }
    if (cmd === 'tu') return startTopup(chat);
    if (cmd === 'tx') return showTx(chat);
    if (cmd === 'tm') {
      const methods: Json[] = await d.rpc('bot_payment_methods');
      const m = methods[n];
      if (!m) return startTopup(chat);
      await setState(chat, { step: 'tu_amount', method: m.name });
      return send(chat, `<b>${esc(m.name)}</b>\n${esc(m.details || '')}\n\nحوّل المبلغ، وبعدين اكتب هون <b>قديش حوّلت</b> (بالشيكل):`);
    }
    if (cmd === 'tu_skip') {
      const st = me.state || {};
      if (st.step !== 'tu_receipt') return startTopup(chat);
      return finishTopup(chat, me, st, null);
    }
    if (cmd === 'o') return showOrder(chat, n);
    if (cmd === 'r') {
      await setState(chat, { step: 'report', oid: n });
      return send(chat, `🚨 بلاغ على طلب #${n}\nاكتب شو المشكلة بالضبط:`);
    }
  }

  return async function handle(update: Json) {
    try {
      if (update.message && update.message.chat?.type === 'private') return await onMessage(update.message);
      if (update.callback_query) return await onCallback(update.callback_query);
    } catch (e) {
      console.error('bot error', e);
      const chat = update.message?.chat?.id || update.callback_query?.message?.chat?.id;
      if (chat) await send(chat, '❌ ' + errText(e)).catch(() => {});
    }
  };
}

// ---------- التشغيل على Supabase ----------
declare const Deno: any;
if (typeof Deno !== 'undefined') {
  const URL_ = Deno.env.get('SUPABASE_URL');
  const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const headers = (extra: Record<string, string> = {}) => ({
    apikey: KEY, ...(String(KEY).startsWith('eyJ') ? { Authorization: `Bearer ${KEY}` } : {}), ...extra,
  });
  let cfg: { token: string; secret: string; at: number } | null = null;

  const rpc = async (fn: string, args: Record<string, unknown> = {}) => {
    const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: 'POST', headers: headers({ 'Content-Type': 'application/json' }), body: JSON.stringify(args) });
    const body = await r.text();
    const j = body ? JSON.parse(body) : null;
    if (!r.ok) throw new Error((j && (j.message || j.error)) || `rpc ${fn} ${r.status}`);
    return j;
  };
  const config = async () => {
    if (!cfg || Date.now() - cfg.at > 60_000) {
      const rows = await rpc('bot_config');
      const row = Array.isArray(rows) ? rows[0] : rows;
      cfg = { token: row?.token || '', secret: row?.secret || '', at: Date.now() };
    }
    return cfg;
  };
  const tg = async (method: string, body: Record<string, unknown>) => {
    const { token } = await config();
    const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return r.json();
  };
  const deps: Deps = {
    rpc, tg,
    async createUser(phone, name) {
      const pass = crypto.randomUUID() + crypto.randomUUID();
      const r = await fetch(`${URL_}/auth/v1/admin/users`, {
        method: 'POST', headers: headers({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ email: `p${phone}@phone.explorplus.app`, password: pass, email_confirm: true, user_metadata: { full_name: name, phone } }),
      });
      if (!r.ok && r.status !== 422) throw new Error('create_user_failed ' + r.status + ' ' + (await r.text()));
    },
    async downloadFile(fileId) {
      const { token } = await config();
      const info = await tg('getFile', { file_id: fileId });
      if (!info.ok) return null;
      const r = await fetch(`https://api.telegram.org/file/bot${token}/${info.result.file_path}`);
      if (!r.ok) return null;
      const bytes = new Uint8Array(await r.arrayBuffer());
      if (bytes.length > 8 * 1024 * 1024) return null;
      const p = String(info.result.file_path).toLowerCase();
      return { bytes, type: p.endsWith('.png') ? 'image/png' : p.endsWith('.webp') ? 'image/webp' : 'image/jpeg' };
    },
    async upload(path, bytes, type) {
      const r = await fetch(`${URL_}/storage/v1/object/receipts/${path}`, { method: 'POST', headers: headers({ 'Content-Type': type, 'x-upsert': 'false' }), body: bytes });
      if (!r.ok) throw new Error('upload_failed ' + r.status);
    },
  };
  const handle = makeBot(deps);

  Deno.serve(async (req: Request) => {
    if (req.method !== 'POST') return new Response('ok');
    // بس تلجرام بيعرف السر (انحط وقت ربط البوت من لوحة الإدارة)
    const got = req.headers.get('x-telegram-bot-api-secret-token');
    let { secret } = await config();
    if (got !== secret) { cfg = null; ({ secret } = await config()); }
    if (!secret || got !== secret) return new Response('forbidden', { status: 403 });
    const update = await req.json().catch(() => null);
    if (update) await handle(update);
    return new Response('ok');
  });
}
