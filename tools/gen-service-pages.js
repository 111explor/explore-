// تشغيل: node tools/gen-service-pages.js  (بيعيد بناء صفحات الخدمات من بيانات index.html)
// بيولّد صفحة لكل خدمة من بيانات الموقع نفسه (SERVICES, RESULTS, VERIFIED, GROWTH, WORKS)
const fs = require('fs'); const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const html = fs.readFileSync(ROOT + '/index.html', 'utf8');
const grab = (name) => { const i = html.indexOf(`const ${name} = [`); let d = 0, j = i + `const ${name} = `.length;
  for (let k = j; k < html.length; k++) { if (html[k] === '[') d++; if (html[k] === ']') { d--; if (!d) return eval(html.slice(j, k + 1)); } } };
const SERVICES = grab('SERVICES'), RESULTS = grab('RESULTS'), VERIFIED = grab('VERIFIED'), GROWTH = grab('GROWTH'), WORKS = grab('WORKS');
const SLUG = { ads: 'ads', verify: 'verify', recover: 'recover', growth: 'followers', manage: 'management', video: 'video', menu: 'menu', product: 'photography', design: 'design', setup: 'setup' };
const esc = (v) => String(v ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = (x) => { const s = String(x).replace(/,/g, ''); return s.endsWith('K') ? parseFloat(s) * 1000 : parseFloat(s); };

const proof = {
  ads: RESULTS.slice(0, 3).map((r) => ({ img: r.img, cap: `<b>${r.big}</b> ${r.ar.big}`, sub: r.ar.t })),
  verify: VERIFIED.slice(0, 4).map((v) => ({ img: v.img, pos: 'bottom', cap: `مبروك التوثيق ✔️`, sub: `@${v.handle} · ${v.followers} متابع` })),
  recover: WORKS.filter((w) => w.type === 'case').map((w) => ({ img: w.after, cap: w.ar.t, sub: w.ar.s })),
  growth: [...GROWTH].sort((a, b) => (num(b.after) - num(b.before)) - (num(a.after) - num(a.before))).slice(0, 4)
    .map((g) => ({ img: g.img, pos: 'bottom', cap: `من ${g.before} لـ ${g.after} متابع`, sub: `@${g.handle}` })),
};

const STEPS = [['اختار خدمتك', 'اضغط «اطلب على واتساب» تحت. بتاخد أقل من دقيقة.'],
  ['احكي معنا على واتساب', 'منفهم شو بدك، ومنتفق معك على التفاصيل والسعر قبل ما نبلّش.'],
  ['بنبلّش بنفس اليوم', 'منبلّش بشغلك فوراً، ومنضل نتابع معك يومياً من 10 الصبح لـ 10 الليل.']];

const WA = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2Zm4.5 12.1c-.2-.1-1.5-.7-1.7-.8-.2-.1-.4-.1-.6.1l-.8 1c-.1.2-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.3-.4.7-1.3.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.2.6.5-.1 1.5-.6 1.7-1.2.2-.6.2-1.1.2-1.2-.1-.1-.3-.2-.5-.3Z"/></svg>';

const CSS = `
:root{--bg:#f5faff;--surface:#fff;--tint:#e7f3ff;--text:#0b0b14;--muted:#55637a;--border:rgba(10,132,255,.16);--accent:#0a84ff;--grad:linear-gradient(115deg,#0a84ff 0%,#2aa6f5 50%,#5cc8fb 100%);color-scheme:light}
*{box-sizing:border-box;margin:0}body{background:var(--bg);color:var(--text);font-family:'Cairo','IBM Plex Sans Arabic',system-ui,sans-serif;line-height:1.75}
a{color:inherit;text-decoration:none}img{max-width:100%;display:block}
.wrap{width:min(960px,100%);margin:0 auto;padding-inline:16px}
header.top{position:sticky;top:0;z-index:50;background:rgba(245,250,255,.9);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--border)}
.nav{display:flex;align-items:center;justify-content:space-between;gap:12px;height:64px}
.brand{display:flex;align-items:center;gap:10px;font-family:'Alexandria','Cairo',sans-serif;font-weight:700}.brand img{width:42px;height:auto}.brand small{display:block;font-family:'Cairo';font-size:11.5px;color:var(--muted);font-weight:500}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:46px;padding:10px 22px;border-radius:999px;font-weight:800;white-space:nowrap}
.btn svg{width:20px;height:20px}.btn-wa{background:#25d366;color:#05310f;box-shadow:0 12px 28px -14px rgba(37,211,102,.8)}.btn-dark{background:var(--text);color:#fff}.btn-light{background:#fff;color:var(--text);border:1.5px solid var(--border)}
.btn-sm{min-height:40px;padding:8px 16px;font-size:14px}
.hero{background:var(--grad);color:#fff;border-radius:0 0 40px 40px;padding:34px 0 40px}
.crumb{font-size:14px;font-weight:600;color:#e6f6ff}.crumb a{text-decoration:underline;text-underline-offset:3px}
h1{font-family:'Lalezar','Cairo',sans-serif;font-weight:400;font-size:clamp(40px,8vw,68px);line-height:1.15;margin:10px 0 8px}
.lead{font-size:17.5px;color:#eef8ff;max-width:640px}
.ctas{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
section{padding:34px 0 0}h2{font-family:'Lalezar','Cairo',sans-serif;font-weight:400;font-size:clamp(28px,5vw,40px);line-height:1.2;margin-bottom:14px}
.eyebrow{display:inline-block;background:var(--tint);color:var(--accent);padding:3px 13px;border-radius:999px;font-weight:700;font-size:13.5px;margin-bottom:8px}
.tags{display:flex;flex-wrap:wrap;gap:8px}.tags span{background:#fff;border:1.5px solid var(--border);padding:7px 16px;border-radius:999px;font-weight:700}
.proof{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:14px}
.proof figure{background:#fff;border:1.5px solid var(--border);border-radius:22px;overflow:hidden}
.proof img{width:100%;aspect-ratio:4/5;object-fit:cover;object-position:top;background:var(--tint)}
.proof figcaption{padding:12px 14px}.proof figcaption b{color:var(--accent)}.proof figcaption span{display:block;color:var(--muted);font-size:13.5px}
.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;list-style:none;padding:0}
.steps li{background:#cfe7ff;border-radius:22px;padding:18px}.steps i{font-style:normal;width:38px;height:38px;border-radius:50%;background:var(--accent);color:#fff;display:grid;place-items:center;font-weight:800;margin-bottom:8px}
.steps b{display:block;font-weight:800;font-size:17px}.steps p{color:#2d4566;font-size:14.5px}
.more{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.more a{background:#eaf5ff;border-radius:20px;padding:16px;font-weight:800}.more a span{display:block;color:var(--muted);font-weight:500;font-size:13.5px;margin-top:2px}
.band{margin:40px 0 0;background:var(--text);color:#fff;border-radius:30px;padding:26px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}
.band h2{margin:0;font-size:clamp(26px,4.5vw,36px)}.band p{color:#b6c3d6}
footer{border-top:1px solid var(--border);margin-top:44px;padding:22px 0 30px;color:var(--muted);font-size:14px}
.foot{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}.foot nav{display:flex;gap:14px;flex-wrap:wrap}
@media (max-width:700px){.steps,.more{grid-template-columns:1fr}.hero{padding:26px 0 32px}}
.btn:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:3px}`;

const page = (s) => {
  const c = s.ar, slug = SLUG[s.id];
  const idx = SERVICES.indexOf(s);
  const others = [1, 2, 3].map((k) => SERVICES[(idx + k) % SERVICES.length]);
  const msg = encodeURIComponent(`مرحباً Explor Plus 👋\nبدي أطلب خدمة: ${c.t}\n\n(من صفحة الخدمة بالموقع)`);
  const pr = proof[s.id] || [];
  const title = `${c.t} في فلسطين | Explor Plus`;
  const desc = `${c.d} اطلب على واتساب، ومنبلّش بنفس اليوم. Explor Plus للدعاية والإعلان منذ 2018.`;
  const ld = [{ '@context': 'https://schema.org', '@type': 'Service', name: c.t, description: c.d, areaServed: 'Palestine', serviceType: c.t,
      provider: { '@type': 'ProfessionalService', name: 'Explor Plus', url: 'https://explorplus.online/', telephone: '+972597653989' } },
    { '@context': 'https://schema.org', '@type': 'BreadcrumbList', itemListElement: [
      { '@type': 'ListItem', position: 1, name: 'Explor Plus', item: 'https://explorplus.online/' },
      { '@type': 'ListItem', position: 2, name: 'خدماتنا', item: 'https://explorplus.online/#services' },
      { '@type': 'ListItem', position: 3, name: c.t, item: `https://explorplus.online/${slug}/` }] }];
  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
  <title>${esc(title)}</title>
  <meta name="description" content="${esc(desc)}">
  <meta name="theme-color" content="#f5faff">
  <link rel="canonical" href="https://explorplus.online/${slug}/">
  <meta property="og:type" content="website">
  <meta property="og:title" content="${esc(title)}">
  <meta property="og:description" content="${esc(c.d)}">
  <meta property="og:url" content="https://explorplus.online/${slug}/">
  <meta property="og:image" content="https://explorplus.online/assets/og-image.jpg">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="../assets/icon.png">
  <link rel="apple-touch-icon" href="../assets/apple-touch-icon.png">
  <link rel="manifest" href="/manifest.webmanifest">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Lalezar&family=Cairo:wght@400;500;600;700;800&family=Alexandria:wght@700&display=swap" rel="stylesheet">
  <script type="application/ld+json">${JSON.stringify(ld)}</script>
  <style>${CSS}</style>
</head>
<body>
  <header class="top"><div class="wrap nav">
    <a href="../" class="brand" aria-label="Explor Plus"><img src="../assets/logo-dark.png" alt="" width="579" height="427"><span>Explor Plus<small>للدعاية والإعلان</small></span></a>
    <a href="../#services" class="btn btn-dark btn-sm">كل الخدمات</a>
  </div></header>
  <main>
    <section class="hero" style="padding-top:30px"><div class="wrap">
      <p class="crumb"><a href="../">الرئيسية</a> › <a href="../#services">خدماتنا</a> › ${esc(c.t)}</p>
      <h1>${esc(c.t)}</h1>
      <p class="lead">${esc(c.d)}</p>
      <div class="ctas"><a class="btn btn-wa" href="https://wa.me/972597653989?text=${msg}" target="_blank" rel="noopener" data-track="${s.id}">${WA} اطلب على واتساب</a><a class="btn btn-light" href="../contact.html">صفحاتنا</a></div>
    </div></section>
    <div class="wrap">
      <section><span class="eyebrow">شو بتشمل الخدمة</span><h2>${esc(c.t)} عنّا</h2><div class="tags">${c.tags.map((g) => `<span>${esc(g)}</span>`).join('')}</div></section>
      ${pr.length ? `<section><span class="eyebrow">من شغلنا</span><h2>نتائج حقيقية لزباينا</h2><div class="proof">${pr.map((p) => `<figure><img src="../${p.img}" alt="${esc(p.sub)}" loading="lazy"${p.pos ? ` style="object-position:${p.pos}"` : ''}><figcaption>${p.cap.includes('<b>') ? p.cap : esc(p.cap)}<span>${esc(p.sub)}</span></figcaption></figure>`).join('')}</div></section>` : ''}
      <section><span class="eyebrow">كيف بنشتغل؟</span><h2>3 خطوات وبنبلّش</h2><ol class="steps">${STEPS.map(([t, d], k) => `<li><i>${k + 1}</i><b>${t}</b><p>${d}</p></li>`).join('')}</ol></section>
      <section><span class="eyebrow">خدمات تانية</span><h2>ممكن تهمّك كمان</h2><div class="more">${others.map((o) => `<a href="../${SLUG[o.id]}/">${esc(o.ar.t)}<span>${esc(o.ar.d.split('،')[0].split('.')[0])}</span></a>`).join('')}</div></section>
      <div class="band"><div><h2>جاهز نبلّش؟</h2><p>متواجدين يومياً من 10 الصبح لـ 10 الليل.</p></div><a class="btn btn-wa" href="https://wa.me/972597653989?text=${msg}" target="_blank" rel="noopener" data-track="${s.id}">${WA} اطلب ${esc(c.t)}</a></div>
    </div>
  </main>
  <footer><div class="wrap foot"><span>© <span id="y">2026</span> Explor Plus · للدعاية والإعلان</span><nav><a href="../">الرئيسية</a><a href="../#services">خدماتنا</a><a href="../contact.html">صفحاتنا</a><a href="../terms.html">الشروط والخصوصية</a></nav></div></footer>
  <script src="../assets/config.js"></script>
  <script>
  (function () {
    var C = window.EXPLOR_CONFIG || {};
    document.getElementById('y').textContent = new Date().getFullYear();
    if (C.WA_SERVICES) document.querySelectorAll('a[href*="wa.me/"]').forEach(function (a) { a.href = a.href.replace(/wa\\.me\\/\\d+/, 'wa.me/' + C.WA_SERVICES); });
    document.addEventListener('click', function (e) {
      var a = e.target.closest('[data-track]'); if (!a || !C.SUPABASE_URL) return;
      try { fetch(C.SUPABASE_URL + '/rest/v1/rpc/track_order_click', { method: 'POST', keepalive: true, headers: { apikey: C.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_service: a.dataset.track }) }).catch(function () {}); } catch (err) {}
    });
  })();
  </script>
</body>
</html>
`;
};

const urls = [];
for (const s of SERVICES) {
  const dir = path.join(ROOT, SLUG[s.id]); fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'index.html'), page(s)); urls.push(SLUG[s.id]);
}
console.log('pages:', urls.join(', '));
