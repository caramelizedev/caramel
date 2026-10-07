(() => {
  const script = document.currentScript;
  const generation = Number(script?.dataset.generation);
  if (!Number.isFinite(generation)) return;
  const requestId = script.dataset.request;
  const inspector = '/__caramel/dev/inspector';
  const session = { credentials: 'same-origin', cache: 'no-store', headers: { 'X-Caramel-Dev': '1' } };
  const RECENT = 10;
  const REMEMBER = 'caramel.dev.toolbar';
  const THEME = 'caramel.dev.theme';
  const CHOICES = ['auto', 'light', 'dark'];
  let stopped = false;
  let seen = null;
  let toolbar = null;
  let following = false;
  let current = null;
  let rows = [];
  let unread = 0;
  let unreadError = false;

  // Copies the text of the element a [data-caramel-copy] button names, and says so on the button.
  document.addEventListener('click', async event => {
    const button = event.target.closest?.('[data-caramel-copy]');
    if (!button) return;
    const source = document.getElementById(button.dataset.caramelCopy);
    if (!source) return;
    const label = button.dataset.label || (button.dataset.label = button.textContent);
    try {
      await navigator.clipboard.writeText(source.textContent);
      button.textContent = 'Copied';
    } catch (_) {
      button.textContent = 'Copy failed';
    }
    setTimeout(() => { button.textContent = label; }, 1500);
  });

  // The colour theme: follow the system (auto), or force light or dark. The choice is shared
  // by the toolbar and the inspector through localStorage, and by every open tab.
  function themeChoice() {
    try {
      const saved = localStorage.getItem(THEME);
      return saved === 'light' || saved === 'dark' ? saved : 'auto';
    } catch (_) { return 'auto'; }
  }

  function applyTheme() {
    const choice = themeChoice();
    const targets = [toolbar?.host];
    if (location.pathname.startsWith(inspector)) targets.push(document.documentElement);
    for (const node of targets) {
      if (!node) continue;
      if (choice === 'auto') delete node.dataset.theme; else node.dataset.theme = choice;
    }
    const label = 'Theme: ' + choice;
    const buttons = [...document.querySelectorAll('[data-caramel-theme]'), toolbar?.theme];
    for (const button of buttons) if (button) button.textContent = label;
  }

  function cycleTheme() {
    const next = CHOICES[(CHOICES.indexOf(themeChoice()) + 1) % CHOICES.length];
    try { next === 'auto' ? localStorage.removeItem(THEME) : localStorage.setItem(THEME, next); } catch (_) { /* Private mode. */ }
    applyTheme();
  }

  document.addEventListener('click', event => {
    if (event.target.closest?.('[data-caramel-theme]')) cycleTheme();
  });
  addEventListener('storage', event => { if (event.key === THEME) applyTheme(); });

  addEventListener('pagehide', () => { stopped = true; });
  addEventListener('pageshow', event => {
    if (event.persisted) { stopped = false; check(); }
  });

  function element(tag, text, attributes, ...children) {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = text;
    for (const [name, value] of Object.entries(attributes || {})) node.setAttribute(name, value);
    node.append(...children);
    return node;
  }

  function remembered() {
    try { return localStorage.getItem(REMEMBER) === 'min'; } catch (_) { return false; }
  }

  function remember(minimised) {
    try { minimised ? localStorage.setItem(REMEMBER, 'min') : localStorage.removeItem(REMEMBER); } catch (_) { /* Private mode. */ }
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

  // ok, warn or error: what the dot, the ring and the unread count show.
  function stateOf(trace) {
    if (trace.outcome === 'error' || trace.status >= 500) return 'error';
    if (flags(trace).length || trace.status >= 400) return 'warn';
    return 'ok';
  }

  function statusText(trace) {
    return trace.status === null || trace.status === undefined ? trace.outcome : String(trace.status);
  }

  function statusClass(trace) {
    return 's' + (Number.isFinite(trace.status) ? Math.floor(trace.status / 100) : 'x');
  }

  function queries(count) {
    return count + (count === 1 ? ' query' : ' queries');
  }

  // The same facts as words, for the tooltip and screen readers.
  function sentence(trace) {
    const parts = [trace.name, statusText(trace), Math.round(trace.duration_ms) + ' ms', queries(trace.db_count)];
    return parts.concat(flags(trace)).join(', ');
  }

  function link(trace, className) {
    return element('a', undefined, { class: className, href: inspector + '/traces/' + trace.trace_id, target: '_blank', rel: 'noopener', title: sentence(trace) });
  }

  // The address of one part of a request's page in the inspector.
  function part(trace, anchor) {
    return inspector + '/traces/' + trace.trace_id + '#' + anchor;
  }

  // In the bar each part links to its place on the trace page; in the list the whole row is
  // one link, so its parts stay plain text.
  function piece(trace, tag, text, className, anchor, linked) {
    if (!linked) return element('span', text, { class: className });
    return element('a', text, { class: className, href: part(trace, anchor), target: '_blank', rel: 'noopener' });
  }

  // One request as parts a developer can scan: its numbers, then what is wrong with it.
  function numbers(trace, linked) {
    return [
      piece(trace, 'span', statusText(trace), 'status ' + statusClass(trace), trace.outcome === 'error' ? 'error' : 'timeline', linked),
      piece(trace, 'span', Math.round(trace.duration_ms) + ' ms', 'metric ms' + (trace.slow ? ' hot' : ''), 'timeline', linked),
      piece(trace, 'span', queries(trace.db_count), 'metric queries' + (trace.repeated > 0 ? ' hot' : ''), 'queries', linked)
    ];
  }

  const SHORT = { 'repeated queries': 'repeat' };
  const WHERE = { error: 'error', slow: 'timeline', 'repeated queries': 'queries' };

  // A chip names the problem in words (never colour alone); on a phone it shortens.
  function chips(trace, linked) {
    return flags(trace).map(flag => {
      const chip = element('span', undefined, { class: 'flag ' + flag.split(' ')[0] },
        element('span', flag, { class: 'long' }), element('span', SHORT[flag] || flag, { class: 'short' }));
      if (!linked) return chip;
      const wrap = element('a', undefined, { class: 'flag-link', href: part(trace, WHERE[flag]), target: '_blank', rel: 'noopener' });
      wrap.append(chip);
      return wrap;
    });
  }

  function buildToolbar() {
    const host = element('caramel-dev-toolbar');
    const root = host.attachShadow({ mode: 'open' });
    const bar = element('div', undefined, { class: 'bar', 'data-state': 'wait' });
    const toggle = element('button', undefined, { class: 'toggle', type: 'button', 'aria-expanded': 'false', 'aria-controls': 'panel', title: 'Recent requests' });
    const minimise = element('button', '–', { class: 'minimise', type: 'button', 'aria-label': 'Minimise the toolbar', title: 'Minimise' });
    const dot = element('button', undefined, { class: 'dot-only', type: 'button', 'aria-label': 'Show the development toolbar', title: 'Show the toolbar', 'data-state': 'wait' });
    const list = element('ol', undefined, { class: 'recent' });
    const open = element('a', 'Open inspector', { class: 'inspector action', href: inspector, target: '_blank', rel: 'noopener' });
    const theme = element('button', undefined, { class: 'theme action', type: 'button', title: 'Colour theme: click to change' });
    const copy = element('button', 'Copy for an agent', { class: 'copy action', type: 'button', title: 'Copy this request as Markdown: the summary, queries with their values, the error and its backtrace' });
    const panel = element('section', undefined, { class: 'panel', id: 'panel', 'aria-label': 'Recent requests' },
      element('header', undefined, undefined, element('strong', 'Recent requests'), open, theme), list,
      element('footer', undefined, undefined, element('span', '` opens and closes this list · j / k move · Enter opens · Esc closes', { class: 'hint' })));
    panel.hidden = true;
    root.append(element('link', undefined, { rel: 'stylesheet', href: '/__caramel/dev/toolbar.css' }), bar, panel, dot);
    toggle.addEventListener('click', () => setOpen(panel.hidden));
    minimise.addEventListener('click', () => setMinimised(true));
    theme.addEventListener('click', cycleTheme);
    copy.addEventListener('click', copyForAgent);
    dot.addEventListener('click', () => setMinimised(false));
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && !panel.hidden) { setOpen(false); toggle.focus(); return; }
      if (editing(event)) return;
      if (event.key === '`' && !event.metaKey && !event.ctrlKey && !event.altKey) { setOpen(panel.hidden); if (!panel.hidden) focusRow(0); return; }
      if (panel.hidden || (event.key !== 'j' && event.key !== 'k')) return;
      event.preventDefault();
      focusRow(event.key === 'j' ? 1 : -1);
    });
    document.addEventListener('pointerdown', event => {
      if (!panel.hidden && !event.composedPath().includes(host)) setOpen(false);
    });
    document.body.append(host);
    const made = { host, root, bar, toggle, minimise, dot, panel, list, theme, copy };
    return made;
  }

  // Typing in a field must never trigger a shortcut.
  function editing(event) {
    const target = event.composedPath()[0];
    return target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
  }

  // Moves focus along the list: to row 0, or by *step* from the focused row.
  function focusRow(step) {
    const rows = [...toolbar.list.querySelectorAll('a.row')];
    if (!rows.length) return;
    const at = rows.indexOf(toolbar.root.activeElement);
    const next = step === 0 || at < 0 ? 0 : Math.min(rows.length - 1, Math.max(0, at + step));
    rows[next].focus();
  }

  // Copies the current request as Markdown, fetched with the development session's header.
  async function copyForAgent() {
    const label = 'Copy for an agent';
    if (!current) return;
    try {
      const response = await fetch('/__caramel/dev/trace.md?id=' + encodeURIComponent(current.trace_id), { ...session, signal: AbortSignal.timeout(3000) });
      if (!response.ok) throw new Error('no trace');
      await navigator.clipboard.writeText(await response.text());
      toolbar.copy.textContent = 'Copied';
    } catch (_) {
      toolbar.copy.textContent = 'Copy failed';
    }
    setTimeout(() => { toolbar.copy.textContent = label; }, 1500);
  }

  function setOpen(open) {
    toolbar.panel.hidden = !open;
    toolbar.toggle.setAttribute('aria-expanded', String(open));
    if (open) { unread = 0; unreadError = false; renderToggle(); renderRows(); }
  }

  function setMinimised(minimised) {
    remember(minimised);
    toolbar.bar.hidden = minimised;
    toolbar.dot.hidden = !minimised;
    if (minimised) setOpen(false);
  }

  function renderToggle() {
    const count = element('span', unread ? String(unread) : undefined, { class: 'unread' + (unreadError ? ' error' : '') });
    count.hidden = unread === 0;
    toolbar.toggle.replaceChildren(element('span', undefined, { class: 'chevron', 'aria-hidden': 'true' }), count);
    toolbar.toggle.title = unread ? unread + (unread === 1 ? ' new request' : ' new requests') + ' since you looked' : 'Recent requests';
    toolbar.toggle.setAttribute('aria-label', toolbar.toggle.title);
  }

  function renderRows() {
    toolbar.list.replaceChildren(...rows.map(trace => {
      const mine = trace.request_id === requestId;
      const row = link(trace, 'row ' + stateOf(trace));
      const marks = mine ? chips(trace, false).concat(element('span', 'this page', { class: 'flag mine' })) : chips(trace, false);
      row.append(element('span', undefined, { class: 'dot ' + stateOf(trace), 'aria-hidden': 'true' }),
        element('span', trace.name, { class: 'name' }), ...numbers(trace, false), element('span', undefined, { class: 'flags' }, ...marks));
      return element('li', undefined, undefined, row);
    }));
    if (!rows.length) toolbar.list.append(element('li', 'Nothing yet. Requests appear here as the page makes them.', { class: 'empty' }));
  }

  function showCurrent(trace) {
    current = trace;
    const state = stateOf(trace);
    toolbar.bar.dataset.state = state;
    toolbar.dot.dataset.state = state;
    const route = link(trace, 'route');
    route.append(element('span', undefined, { class: 'dot ' + state, 'aria-hidden': 'true' }), element('span', trace.name, { class: 'name' }));
    toolbar.bar.replaceChildren(route, ...numbers(trace, true), ...chips(trace, true), toolbar.copy, toolbar.toggle, toolbar.minimise);
    renderToggle();
  }

  function showMissing() {
    toolbar.bar.dataset.state = 'empty';
    toolbar.dot.dataset.state = 'empty';
    const note = element('span', 'No trace for this page', { class: 'note', title: 'Its request did not reach the development event store. The inspector still lists the others.' });
    toolbar.bar.replaceChildren(element('span', undefined, { class: 'dot empty', 'aria-hidden': 'true' }), note, toolbar.toggle, toolbar.minimise);
    renderToggle();
  }

  function showWaiting() {
    toolbar.bar.dataset.state = 'wait';
    const note = element('span', 'Waiting for this page’s trace…', { class: 'note' });
    toolbar.bar.replaceChildren(element('span', undefined, { class: 'dot wait', 'aria-hidden': 'true' }), note, toolbar.toggle, toolbar.minimise);
    renderToggle();
  }

  function keepRows(traces) {
    for (const trace of traces) rows = rows.filter(row => row.trace_id !== trace.trace_id);
    rows = traces.concat(rows).slice(0, RECENT);
  }

  function prepend(traces) {
    keepRows(traces);
    if (toolbar.panel.hidden) {
      unread += traces.length;
      unreadError = unreadError || traces.some(trace => stateOf(trace) === 'error');
      renderToggle();
    } else {
      renderRows();
    }
  }

  function pause(milliseconds) {
    return new Promise(resolve => setTimeout(resolve, milliseconds));
  }

  async function start() {
    if (!requestId || !document.body) return;
    toolbar = buildToolbar();
    applyTheme();
    setMinimised(remembered());
    showWaiting();
    renderRows();
    try {
      // The application's trace can reach the event store a moment after its response.
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const own = await feed('request=' + encodeURIComponent(requestId));
        if (seen === null) seen = own.latest;
        if (own.traces.length) { showCurrent(own.traces[0]); break; }
        await pause(300);
      }
      if (!current) showMissing();
      const recent = await feed('limit=' + RECENT);
      seen = Math.max(seen ?? 0, recent.latest);
      keepRows(recent.traces);
      renderRows();
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
      prepend(news.traces);
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
        const status = await response.json();
        if (status.state !== 'building' && status.generation !== generation) {
          location.reload();
          return;
        }
        if (typeof status.latest === 'number') follow(status.latest).catch(() => {});
      }
    } catch (_) { /* A restart keeps the same origin; reconnect on the next poll. */ }
    if (!stopped) setTimeout(check, 400);
  }

  applyTheme();
  start();
  check();
})();
