/* Explor Plus: service worker بسيط
   - الصور والخطوط والملفات الثابتة: من الذاكرة بسرعة، وبتتحدّث بالخلفية
   - الصفحات وقاعدة البيانات: دايماً من النت (الأسعار والأرصدة لازم تكون محدّثة)
   - بدون نت: بتفتح آخر نسخة محفوظة من الصفحة */
const CACHE = 'xp-v7';
const CORE = ['/', '/index.html', '/store.html', '/assets/store.css', '/assets/store-core.js', '/assets/config.js', '/assets/vendor/supabase-2.118.0.js', '/assets/logo-light.png', '/assets/icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(CORE)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) {
    // خطوط جوجل بس، الباقي (Supabase) دايماً من النت
    if (!/fonts\.(googleapis|gstatic)\.com$/.test(url.hostname)) return;
  }
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res; })
      .catch(() => caches.match(req).then((r) => r || caches.match('/store.html'))));
    return;
  }
  // الكود (js/css): من النت أول لحتى ما يعلق الزبون على نسخة قديمة
  if (/\.(js|css|webmanifest)$/.test(url.pathname)) {
    e.respondWith(fetch(req).then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res; }).catch(() => caches.match(req)));
    return;
  }
  // الصور والخطوط: stale-while-revalidate
  e.respondWith(caches.match(req).then((cached) => {
    const net = fetch(req).then((res) => { if (res.ok || res.type === 'opaque') { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return res; }).catch(() => cached);
    return cached || net;
  }));
});
