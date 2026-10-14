// Service worker de PVE Hub : reçoit les notifications et ouvre l'app au bon endroit quand on les touche.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data.json(); } catch { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "PVE Hub", {
    body: d.body || "", tag: d.tag || undefined, icon: "/icon.png?v=2", data: { url: d.url || "/" },
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "/", self.location.origin).href;
  e.waitUntil((async () => {
    for (const c of await self.clients.matchAll({ type: "window", includeUncontrolled: true })) {
      try { await c.focus(); await c.navigate(url); return; } catch {}
    }
    await self.clients.openWindow(url);
  })());
});
