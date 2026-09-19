(() => {
  const generation = Number(document.currentScript?.dataset.generation);
  if (!Number.isFinite(generation)) return;
  let stopped = false;
  addEventListener('pagehide', () => { stopped = true; });
  addEventListener('pageshow', event => {
    if (event.persisted) { stopped = false; check(); }
  });
  async function check() {
    if (stopped) return;
    try {
      const response = await fetch('/__caramel/dev/status', {
        credentials: 'same-origin', cache: 'no-store',
        headers: { 'X-Caramel-Dev': '1' },
        signal: AbortSignal.timeout(3000)
      });
      if (response.status === 403) { location.reload(); return; }
      if (response.ok) {
        const current = await response.json();
        if (current.state !== 'building' && current.generation !== generation) {
          location.reload();
          return;
        }
      }
    } catch (_) { /* A restart keeps the same origin; reconnect on the next poll. */ }
    if (!stopped) setTimeout(check, 400);
  }
  check();
})();
