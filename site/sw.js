// Service worker: keeps the app itself available offline. Data always comes live from Supabase.
const VERSION = "brewskis-v16";
const SHELL = ["./", "index.html", "styles.css", "app.js", "config.js", "manifest.webmanifest", "logo.webp",
  "icons/icon-192.png", "icons/icon-512.png", "icons/maskable-512.png", "icons/apple-touch-icon.png", "icons/favicon-32.png"];

self.addEventListener("install", event => {
  // cache: "reload" skips the browser's own cache so an update always gets the newest files
  event.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL.map(u => new Request(u, { cache: "reload" })))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION && k !== "brewskis-fonts").map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", event => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // Google Fonts: cache first, they never change.
  if (url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com") {
    event.respondWith(caches.open("brewskis-fonts").then(async c => {
      const hit = await c.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === "opaque") c.put(req, res.clone());
      return res;
    }));
    return;
  }
  if (url.origin !== self.location.origin) return; // Supabase calls go straight to the network.
  if (url.pathname.endsWith("/version.json")) return; // always ask the network which version is newest

  // App files: answer from cache right away, refresh the cache in the background.
  event.respondWith(caches.open(VERSION).then(async c => {
    const hit = await c.match(req, { ignoreSearch: true }) || (req.mode === "navigate" ? await c.match("index.html") : null);
    const fresh = fetch(req).then(res => { if (res.ok) c.put(req, res.clone()); return res; }).catch(() => null);
    return hit || (await fresh) || new Response("Offline", { status: 503 });
  }));
});

// Manager notifications sent by the "notify" Edge Function.
self.addEventListener("push", event => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { title: "Brewskis", body: event.data ? event.data.text() : "" }; }
  event.waitUntil(self.registration.showNotification(d.title || "Brewskis", {
    body: d.body || "",
    icon: "icons/icon-192.png",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || "./" }
  }));
});

// Tapping a notification opens the app (or brings it forward) at the right screen.
self.addEventListener("notificationclick", event => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "./", self.registration.scope).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope)) {
        if (c.navigate) c.navigate(url).catch(() => {});
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  }));
});
