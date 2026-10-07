(() => {
  // Copies the text a [data-caramel-text] button carries, or the text of the element a
  // [data-caramel-copy] button names, and says so on the button.
  document.addEventListener('click', async event => {
    const button = event.target.closest?.('[data-caramel-copy], [data-caramel-text]');
    if (!button) return;
    const source = button.dataset.caramelCopy ? document.getElementById(button.dataset.caramelCopy) : null;
    const text = button.dataset.caramelText ?? source?.textContent;
    if (text === undefined) return;
    const label = button.dataset.label || (button.dataset.label = button.textContent);
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch (_) {
      button.textContent = 'Copy failed';
    }
    clearTimeout(button.timer);
    button.timer = setTimeout(() => { button.textContent = label; }, 1500);
  });

  // The colour theme: follow the system (auto), or force light or dark; kept in localStorage.
  const THEME = 'caramel.dev.theme';
  const CHOICES = ['auto', 'light', 'dark'];

  function themeChoice() {
    try {
      const saved = localStorage.getItem(THEME);
      return saved === 'light' || saved === 'dark' ? saved : 'auto';
    } catch (_) { return 'auto'; }
  }

  function applyTheme() {
    const choice = themeChoice();
    if (choice === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = choice;
    for (const button of document.querySelectorAll('[data-caramel-theme]')) button.textContent = 'Theme: ' + choice;
  }

  document.addEventListener('click', event => {
    if (!event.target.closest?.('[data-caramel-theme]')) return;
    const next = CHOICES[(CHOICES.indexOf(themeChoice()) + 1) % CHOICES.length];
    try { next === 'auto' ? localStorage.removeItem(THEME) : localStorage.setItem(THEME, next); } catch (_) { /* Private mode. */ }
    applyTheme();
  });
  addEventListener('storage', event => { if (event.key === THEME || event.key === null) applyTheme(); });
  applyTheme();

  const list = document.getElementById('tail');
  if (!list) return;
  const KEEP = 500;

  const fixed = value => Number(value).toFixed(1);

  function request(event) {
    const parts = ['request', event.method || '-', event.path || event.route || '-', event.status ?? '-'];
    parts.push(fixed(event.duration_ms) + 'ms', 'db=' + event.db_count + '/' + fixed(event.db_ms) + 'ms');
    parts.push('view=' + fixed(event.view_ms) + 'ms');
    if (event.action) parts.push(event.action);
    return parts;
  }

  function job(event) {
    const parts = ['job', event.name];
    if (event.job_id !== undefined) parts.push('#' + event.job_id);
    parts.push(event.outcome, fixed(event.duration_ms) + 'ms', 'db=' + event.db_count + '/' + fixed(event.db_ms) + 'ms');
    if (event.queue) parts.push('queue=' + event.queue);
    if (event.attempt !== undefined) parts.push('attempt=' + event.attempt);
    if (event.queue_lag_ms !== undefined) parts.push('lag=' + fixed(event.queue_lag_ms) + 'ms');
    return parts;
  }

  function trace(event) {
    let parts = event.kind === 'job' ? job(event) : request(event);
    if (event.kind === 'schedule') parts = ['schedule', event.name, event.outcome, fixed(event.duration_ms) + 'ms'];
    if (event.request_id) parts.push('request_id=' + event.request_id);
    if (event.repeated?.length) parts.push('repeated=' + event.repeated.length);
    if (event.slow_queries) parts.push('slow_queries=' + event.slow_queries);
    if (event.error) parts.push('error=' + event.error.error_class);
    if (event.debug) parts.push('debug');
    return parts.join(' ');
  }

  function line(event) {
    if (event.type === 'trace') return trace(event);
    if (event.type === 'error') {
      return ['error', event.error_class, 'fingerprint=' + event.fingerprint, event.location ? 'at ' + event.location : '']
        .filter(Boolean).join(' ');
    }
    return '[' + event.level + '] ' + event.source + ': ' + event.message;
  }

  const source = new EventSource('/v1/tail?logs=1');
  source.onmessage = message => {
    const event = JSON.parse(message.data);
    const item = document.createElement('li');
    item.textContent = new Date().toLocaleTimeString() + ' ' + line(event);
    if (event.type === 'error' || event.outcome === 'error') item.className = 'error';
    list.prepend(item);
    while (list.children.length > KEEP) list.lastChild.remove();
  };
})();
