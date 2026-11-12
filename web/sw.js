// lubdub service worker — the smallest one that makes the page installable.
//
// Strictly network-first: every request goes to the network, and only a
// navigation that fails (offline) falls back to the last cached shell.
// Nothing else is ever served from cache, so a deployed change is what you
// get on the next load — no stale-cache purgatory. Bump V when you change
// the shell's offline copy semantics, not for ordinary page edits.
const V = "lubdub-v1";

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(V).then((c) => c.add("/").catch(() => {})));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== V).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  e.respondWith(
    fetch(e.request).then((r) => {
      if (e.request.mode === "navigate" && r.ok) {
        const copy = r.clone();
        caches.open(V).then((c) => c.put("/", copy)).catch(() => {});
      }
      return r;
    }).catch(() => {
      if (e.request.mode === "navigate") return caches.match("/");
      throw new TypeError("offline");
    })
  );
});
