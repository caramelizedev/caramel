(() => {
  document.addEventListener('click', event => {
    const button = event.target.closest?.('[data-caramel-copy]');
    if (!button) return;
    const source = document.getElementById(button.dataset.caramelCopy);
    if (source) navigator.clipboard.writeText(source.textContent);
  });

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
