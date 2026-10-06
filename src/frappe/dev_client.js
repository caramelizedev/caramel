(() => {
  const script = document.currentScript;
  const generation = Number(script?.dataset.generation);
  if (!Number.isFinite(generation)) return;
  const requestId = script.dataset.request;
  const inspector = '/__caramel/dev/inspector';
  const session = { credentials: 'same-origin', cache: 'no-store', headers: { 'X-Caramel-Dev': '1' } };
  let stopped = false;
  let seen = null;
  let toolbar = null;
  let following = false;

  document.addEventListener('click', event => {
    const button = event.target.closest?.('[data-caramel-copy]');
    if (!button) return;
    const source = document.getElementById(button.dataset.caramelCopy);
    if (source) navigator.clipboard.writeText(source.textContent);
  });

  addEventListener('pagehide', () => { stopped = true; });
  addEventListener('pageshow', event => {
    if (event.persisted) { stopped = false; check(); }
  });

  function element(tag, text, attributes) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    for (const [name, value] of Object.entries(attributes || {})) node.setAttribute(name, value);
    return node;
  }

  async function feed(query) {
    const response = await fetch('/__caramel/dev/traces.json?' + query, {
      ...session, signal: AbortSignal.timeout(3000)
    });
    return response.ok ? response.json() : { latest: 0, traces: [] };
  }

  function flags(trace) {
    const found = [];
    if (trace.outcome === 'error') found.push('error');
    if (trace.slow) found.push('slow');
    if (trace.repeated > 0) found.push('repeated queries');
    return found;
  }

  function label(trace) {
    const status = trace.status === null ? trace.outcome : trace.status;
    const parts = [trace.name, status, Math.round(trace.duration_ms) + ' ms', trace.db_count + ' queries'];
    return parts.concat(flags(trace)).join(' · ');
  }

  function link(trace) {
    return element('a', label(trace), { href: inspector + '/traces/' + trace.trace_id, target: '_blank' });
  }

  function buildToolbar() {
    const host = element('caramel-dev-toolbar');
    const root = host.attachShadow({ mode: 'open' });
    root.append(element('link', undefined, { rel: 'stylesheet', href: '/__caramel/dev/toolbar.css' }));
    const badge = element('span', undefined, { class: 'badge' });
    const toggle = element('button', '▾', { class: 'toggle', type: 'button', 'aria-label': 'Recent requests' });
    const recent = element('ol', undefined, { class: 'recent' });
    recent.hidden = true;
    toggle.addEventListener('click', () => { recent.hidden = !recent.hidden; });
    root.append(badge, recent);
    badge.append(toggle);
    document.body.append(host);
    return { badge, toggle, recent };
  }

  function showCurrent(trace) {
    toolbar.badge.className = 'badge' + (trace.outcome === 'error' ? ' error' : flags(trace).length ? ' warn' : '');
    toolbar.badge.replaceChildren(link(trace), toolbar.toggle);
  }

  function prepend(traces) {
    for (const trace of traces) {
      const item = element('li');
      item.append(link(trace));
      toolbar.recent.prepend(item);
    }
    while (toolbar.recent.children.length > 10) toolbar.recent.lastChild.remove();
  }

  function pause(milliseconds) {
    return new Promise(resolve => setTimeout(resolve, milliseconds));
  }

  async function start() {
    if (!requestId || !document.body) return;
    toolbar = buildToolbar();
    try {
      // The application's trace can reach the event store a moment after its response.
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const own = await feed('request=' + encodeURIComponent(requestId));
        if (seen === null) seen = own.latest;
        if (own.traces.length) { showCurrent(own.traces[0]); return; }
        await pause(300);
      }
      toolbar.badge.prepend('no trace');
    } catch (_) { /* The toolbar is a convenience; the page works without it. */ }
  }

  async function follow(latest) {
    if (seen === null) seen = latest;
    if (latest <= seen) return;
    const banner = document.querySelector('[data-caramel-new]');
    if (banner) banner.hidden = false;
    if (!toolbar) { seen = latest; return; }
    if (following) return;
    following = true;
    try {
      const news = await feed('after=' + seen);
      seen = news.latest;
      prepend(news.traces.slice().reverse());
    } finally {
      following = false;
    }
  }

  async function check() {
    if (stopped) return;
    try {
      const response = await fetch('/__caramel/dev/status', {
        ...session, signal: AbortSignal.timeout(3000)
      });
      if (response.status === 403) { location.reload(); return; }
      if (response.ok) {
        const current = await response.json();
        if (current.state !== 'building' && current.generation !== generation) {
          location.reload();
          return;
        }
        if (typeof current.latest === 'number') follow(current.latest).catch(() => {});
      }
    } catch (_) { /* A restart keeps the same origin; reconnect on the next poll. */ }
    if (!stopped) setTimeout(check, 400);
  }

  start();
  check();
})();
