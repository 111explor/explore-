/* Explor Plus: أيقونات وأدوات صفحة «تواصل معنا» (بتستخدمها الصفحة ولوحة الأدمن) */
(function () {
  const S = (d, fill) => `<svg viewBox="0 0 24 24" ${fill ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'} aria-hidden="true">${d}</svg>`;
  const ICONS = {
    instagram: { label: 'إنستغرام', color: '#e1306c', svg: S('<rect x="2" y="2" width="20" height="20" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.5" cy="6.5" r=".8" fill="currentColor"/>') },
    whatsapp: { label: 'واتساب', color: '#25d366', svg: S('<path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2Zm4.5 12.1c-.2-.1-1.5-.7-1.7-.8-.2-.1-.4-.1-.6.1l-.8 1c-.1.2-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.3-.4.7-1.3.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.2.6.5-.1 1.5-.6 1.7-1.2.2-.6.2-1.1.2-1.2-.1-.1-.3-.2-.5-.3Z"/>', true) },
    facebook: { label: 'فيسبوك', color: '#1877f2', svg: S('<path d="M13.5 22v-8h2.7l.4-3.2h-3.1V8.8c0-.9.3-1.5 1.6-1.5h1.7V4.4c-.3 0-1.3-.1-2.5-.1-2.4 0-4.1 1.5-4.1 4.2v2.3H7.5V14h2.7v8h3.3Z"/>', true) },
    tiktok: { label: 'تيك توك', color: '#111111', svg: S('<path d="M16.6 5.8A4.3 4.3 0 0 1 15.5 3h-3.1v12.4a2.6 2.6 0 1 1-2.6-2.6c.3 0 .5 0 .8.1V9.7a5.8 5.8 0 1 0 4.9 5.7V9.1a7.4 7.4 0 0 0 4.3 1.4V7.4a4.3 4.3 0 0 1-3.2-1.6Z"/>', true) },
    telegram: { label: 'تلجرام', color: '#229ed9', svg: S('<path d="M21.9 4.3 18.7 19.4c-.2 1-.9 1.3-1.7.8l-4.8-3.5-2.3 2.2c-.3.3-.5.5-1 .5l.3-4.9 8.9-8c.4-.3-.1-.5-.6-.2L6.5 13.2l-4.7-1.5c-1-.3-1-1 .2-1.5L20.6 3c.9-.3 1.6.2 1.3 1.3Z"/>', true) },
    snapchat: { label: 'سناب شات', color: '#f7d000', svg: S('<path d="M12 2.5c3 0 5.3 2.3 5.3 5.3v2.4l1.6-.5c.6-.2 1.1.5.6 1l-1.8 1.4c.5 1.6 1.7 2.9 3.3 3.5.5.2.5.9 0 1.1l-1.7.6-.4 1.4-1.8-.2c-1 0-1.7.7-2.6 1.3-.8.6-1.6.9-2.5.9s-1.7-.3-2.5-.9c-.9-.6-1.6-1.3-2.6-1.3l-1.8.2-.4-1.4-1.7-.6c-.5-.2-.5-.9 0-1.1 1.6-.6 2.8-1.9 3.3-3.5L3.6 11.7c-.5-.5 0-1.2.6-1l1.6.5V7.8c0-3 2.3-5.3 5.3-5.3Z"/>', true) },
    youtube: { label: 'يوتيوب', color: '#ff0000', svg: S('<path d="M21.6 7.2a2.6 2.6 0 0 0-1.8-1.8C18.2 5 12 5 12 5s-6.2 0-7.8.4A2.6 2.6 0 0 0 2.4 7.2 27 27 0 0 0 2 12a27 27 0 0 0 .4 4.8 2.6 2.6 0 0 0 1.8 1.8c1.6.4 7.8.4 7.8.4s6.2 0 7.8-.4a2.6 2.6 0 0 0 1.8-1.8A27 27 0 0 0 22 12a27 27 0 0 0-.4-4.8ZM10 15V9l5.2 3L10 15Z"/>', true) },
    x: { label: 'X (تويتر)', color: '#111111', svg: S('<path d="M17.8 3h3.1l-6.8 7.8L22 21h-6.2l-4.9-6.4L5.3 21H2.2l7.3-8.3L2 3h6.4l4.4 5.8L17.8 3Zm-1.1 16.2h1.7L7.4 4.7H5.6l11.1 14.5Z"/>', true) },
    store: { label: 'المتجر', color: '#7c3aed', svg: S('<path d="M3 9h18l-1.5-5h-15L3 9Z"/><path d="M4 9v11h16V9"/><path d="M9 20v-6h6v6"/>') },
    website: { label: 'موقع', color: '#7c3aed', svg: S('<circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15 15 0 0 1 0 20 15 15 0 0 1 0-20Z"/>') },
    phone: { label: 'اتصال', color: '#0a84ff', svg: S('<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2Z"/>') },
    email: { label: 'إيميل', color: '#ea4335', svg: S('<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-10 6L2 7"/>') },
    location: { label: 'الموقع على الخريطة', color: '#ea4335', svg: S('<path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>') },
    ads: { label: 'إعلانات', color: '#e2621f', svg: S('<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>') },
    gift: { label: 'مسابقات', color: '#e2621f', svg: S('<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13"/><path d="M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7"/><path d="M7.5 8a2.5 2.5 0 0 1 0-5C11 3 12 8 12 8s1-5 4.5-5a2.5 2.5 0 0 1 0 5"/>') },
    link: { label: 'رابط', color: '#5f5378', svg: S('<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>') }
  };

  // بيحوّل اللي كتبه الأدمن لرابط صحيح: رقم واتساب، @يوزر، إيميل، رقم تلفون، أو رابط كامل
  function toHref(type, value) {
    const v = String(value || '').trim();
    if (!v) return '';
    if (/^https?:\/\//i.test(v)) return v;
    const digits = v.replace(/\D/g, '').replace(/^00/, '');
    if (type === 'whatsapp') return digits ? `https://wa.me/${digits.startsWith('0') ? '972' + digits.slice(1) : digits}` : '';
    if (type === 'phone') return `tel:+${digits.startsWith('0') ? '972' + digits.slice(1) : digits}`;
    if (type === 'email') return /@/.test(v) ? `mailto:${v}` : '';
    const handle = v.replace(/^@/, '');
    if (type === 'instagram') return `https://instagram.com/${handle}`;
    if (type === 'tiktok') return `https://tiktok.com/@${handle}`;
    if (type === 'telegram') return `https://t.me/${handle}`;
    if (type === 'snapchat') return `https://snapchat.com/add/${handle}`;
    if (type === 'x') return `https://x.com/${handle}`;
    if (type === 'facebook') return `https://facebook.com/${handle}`;
    if (type === 'youtube') return `https://youtube.com/@${handle}`;
    if (/^[\w.-]+\.[a-z]{2,}(\/.*)?$/i.test(v)) return 'https://' + v;
    // أيقونة عامة (إعلانات، مسابقات…) مع @يوزر = حساب إنستغرام
    if (/^@[\w.]+$/.test(v)) return `https://instagram.com/${handle}`;
    return '';
  }

  // الأزرار الافتراضية إذا الأدمن لسا ما رتّب الصفحة
  function defaults(C) {
    const so = C.SOCIALS || {};
    const list = [
      { type: 'instagram', title: 'إنستغرام', sub: '@explor.ps · الحساب الرئيسي', value: so.instagram || 'https://www.instagram.com/explor.ps' },
      { type: 'whatsapp', title: 'واتساب الخدمات', sub: 'إعلانات، توثيق، تصوير وتصميم', value: C.WA_SERVICES || '972597653989' },
      { type: 'whatsapp', title: 'واتساب الاشتراكات', sub: 'الاشتراكات الرقمية وشحن الرصيد', value: C.WA_SUBSCRIPTIONS || '972597653989' },
      { type: 'store', title: 'المتجر', sub: 'اشتراكات بتسليم فوري', value: 'https://explorplus.online/store' }
    ];
    if (so.facebook) list.push({ type: 'facebook', title: 'فيسبوك', sub: '', value: so.facebook });
    if (so.tiktok) list.push({ type: 'tiktok', title: 'تيك توك', sub: '', value: so.tiktok });
    if (so.telegram) list.push({ type: 'telegram', title: 'تلجرام', sub: '', value: so.telegram });
    return list;
  }

  window.XPLinks = { ICONS, toHref, defaults };
})();
