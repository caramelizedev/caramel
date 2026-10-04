
// Probes for scripts/check browser. The check reads window.__probe.
(() => {
  const probe = { requests: [], responses: [], settled: [], islands: [], sse: [], sseErrors: [], pubsub: [], pubsubErrors: [], inflight: 0 };
  window.__probe = probe;

  document.addEventListener('htmx:before:request', (event) => {
    const request = event.detail.ctx.request;
    probe.inflight += 1;
    probe.requests.push({
      method: request.method,
      action: String(request.action),
      type: request.headers['HX-Request-Type'],
      csrf: Boolean(request.headers['X-CSRF-Token']),
    });
  });
  document.addEventListener('htmx:after:request', (event) => {
    const ctx = event.detail.ctx;
    probe.responses.push({ status: ctx.response?.status, layout: /<html|site-header/.test(ctx.text || '') });
  });
  document.addEventListener('htmx:finally:request', () => {
    probe.inflight -= 1;
  });
  document.addEventListener('htmx:after:settle', (event) => {
    probe.settled.push(event.target.id || event.target.tagName);
  });

  CaramelIslands.define('ProbeCounter', (element, props) => {
    probe.islands.push({ event: 'mount', component: 'ProbeCounter', props });
    let count = 0;
    const label = document.createElement('span');
    label.className = 'island-label';
    label.textContent = props.label;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'island-increment';
    button.textContent = 'Increment';
    const output = document.createElement('output');
    output.className = 'island-count';
    output.textContent = '0';
    button.addEventListener('click', () => {
      count += 1;
      output.textContent = String(count);
    });
    element.append(label, button, output);
    return {
      update(next) {
        probe.islands.push({ event: 'update', component: 'ProbeCounter', props: next });
        label.textContent = next.label;
      },
      unmount() {
        probe.islands.push({ event: 'unmount', component: 'ProbeCounter' });
      },
    };
  });

  function defineLate() {
    CaramelIslands.define('LateProbe', (element, props) => {
      probe.islands.push({ event: 'mount', component: 'LateProbe', props });
      element.textContent = `Mounted ${props.label}`;
    });
  }

  function openStream() {
    const log = document.getElementById('sse-log');
    const source = new EventSource('/probe/events/stream');
    source.addEventListener('probe', (event) => {
      probe.sse.push({ data: event.data, at: performance.now() });
      const item = document.createElement('li');
      item.textContent = event.data;
      log.append(item);
      if (event.data !== 'first') source.close();
    });
    source.addEventListener('error', () => {
      probe.sseErrors.push(source.readyState);
    });
  }

  // Streams the board's Cold Brew channel through the Boards::Live action.
  function openBoard() {
    const board = document.getElementById('pubsub').dataset.board;
    const log = document.getElementById('pubsub-log');
    const source = new EventSource(`/probe/pubsub/${board}/live`);
    source.addEventListener('BoardUpdated', (event) => {
      probe.pubsub.push(event.data);
      const item = document.createElement('li');
      item.textContent = event.data;
      log.append(item);
    });
    source.addEventListener('error', () => {
      probe.pubsubErrors.push(source.readyState);
    });
  }

  document.addEventListener('click', (event) => {
    if (!(event.target instanceof Element)) return;
    const button = event.target.closest('#define-late, #sse-open, #pubsub-open');
    if (!button) return;
    button.disabled = true;
    if (button.id === 'define-late') defineLate();
    else if (button.id === 'pubsub-open') openBoard();
    else openStream();
  });
})();
