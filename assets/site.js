const CARAMEL = {"routes":{"home":"/","cookbook":"/cookbook/0.16.0/","learn":"/docs/0.16.0/getting-started/","map":"/docs/0.16.0/project-map/","crud":"/cookbook/0.16.0/create-a-resource/","forms":"/cookbook/0.16.0/rendered-forms/","json":"/cookbook/0.16.0/return-json/","uploads":"/cookbook/0.16.0/uploads/","islands":"/cookbook/0.16.0/third-party-components/","jobs":"/cookbook/0.16.0/background-jobs/","webhooks":"/cookbook/0.16.0/webhooks/","sessions":"/cookbook/0.16.0/revocable-sessions/","agents":"/docs/0.16.0/agents/","i18n":"/docs/0.16.0/internationalization/","tenancy":"/docs/0.16.0/multi-tenancy/","crema":"/docs/0.16.0/observability/","testing":"/docs/0.16.0/testing-html/","releases":"/docs/0.16.0/releases/","deploy":"/docs/0.16.0/deployment/","boxoffice":"/docs/0.16.0/box-office/","sweettalk":"/docs/0.16.0/sweettalk/","practices":"/docs/0.16.0/best-practices/","routing":"/docs/0.16.0/routes-and-contracts/","actions":"/docs/0.16.0/actions-and-responses/","views":"/docs/0.16.0/views/","sugarorm":"/docs/0.16.0/sugarorm/","coldbrew":"/docs/0.16.0/cold-brew/","corretto":"/docs/0.16.0/corretto/","cremaref":"/docs/0.16.0/crema/","security":"/docs/0.16.0/security/","commands":"/docs/0.16.0/commands/","local":"/docs/0.16.0/local-environment/"},"searchIndex":[{"page":"learn","title":"Your first application","type":"Learning path","terms":"setup install create macos apple silicon"},{"page":"map","title":"Project map","type":"Guide","terms":"directory files controller action model view frappe latte sugarorm corretto blueprint"},{"page":"agents","title":"Work with an agent","type":"Guide","terms":"AI AGENTS manifest check commands mrdp diagnostics patch expand"},{"page":"i18n","title":"Internationalization","type":"Guide","terms":"i18n translate translations localization locales language French plurals formatting dates number fallback cookie accept language rtl wording make locale catalog reference keys errors pages directives plural rules languages"},{"page":"crema","title":"Observability","type":"Guide","terms":"crema observability logs log request id trace traceparent error report fingerprint slow monitoring debugging on_error"},{"page":"cremaref","title":"Crema","type":"Reference","terms":"crema observability reference ops socket ops status tail errors traces metrics prometheus debug token recorder insights otlp opentelemetry sampler log line fields redaction fingerprint inspector toolbar theme dark light copy sql bind values shortcut dump traceparent jobs db diagnose collector pg_stat_statements access log"},{"page":"tenancy","title":"Multi-tenancy","type":"Guide","terms":"tenant tenancy multi-tenant saas accounts organizations slug scope isolation central make tenancy tenant_session"},{"page":"testing","title":"Test rendered HTML","type":"Guide","terms":"corretto have_html blueprint lexbor render_partial render_page doctype strict count scope assertions"},{"page":"releases","title":"Current release","type":"Guide","terms":"current release i18n internationalization translations locales version 0.16.0 crystal postgres lock shard lexbor only url server unique render_errors requirements limits"},{"page":"practices","title":"Best practices","type":"Guide","terms":"best practices conventions guidelines style lint service nouns contracts changesets preload migrations escaping csrf security jobs idempotent retries testing corretto mocks translations proof checks agents"},{"page":"routing","title":"Routes and contracts","type":"Reference","terms":"routes router draw path parameters 404 405 head method override contract field params validation min max default nilable string int64 time uploadedfile json query duplicate unknown errors 422 resource_paths path helpers frappe routes contract_mismatch ingress"},{"page":"actions","title":"Actions and responses","type":"Reference","terms":"action controller handle render respond status page layout title_for markup htmx partials morph fragment redirect_to redirect_external not_found stream sse server-sent events render_errors contract_failure_page session sign_out csrf_token negotiation accept json"},{"page":"views","title":"Views","type":"Reference","terms":"views blueprint templates html elements escaping attributes plain raw safe markup islands render partials forms csrf _method layout lang"},{"page":"sugarorm","title":"SugarORM","type":"Reference","terms":"sugarorm orm database model schema field belongs_to has_many has_one index scope query where order_by find preload n+1 sql changeset validations validate_presence unique_constraint check constraint check_constraint create update transaction migrations db diff migrate linter dev-override branch lock for update upsert on conflict version lock_version stale etag if-match"},{"page":"coldbrew","title":"Cold Brew","type":"Reference","terms":"cold brew jobs background queue worker enqueue param perform retry_on backoff run_at priority work concurrency schedules every cron pubsub publish subscribe cache drain_queue"},{"page":"corretto","title":"Corretto","type":"Reference","terms":"corretto testing specs request specs session client get post json body files upload headers csrf forged follow_redirect matchers have_status have_header redirect_to render_page have_row stub_wire wire fixtures mocks drain_queue concurrency env.test"},{"page":"security","title":"Security defaults","type":"Reference","terms":"security csrf token origin session cookie host headers content security policy csp referrer nosniff 421 escaping xss safe ingress authenticate webhook redirect external url outbound static files errors request id"},{"page":"commands","title":"Commands","type":"Reference","terms":"commands cli frappe reference help syntax flags latte binary serve work seed routes schema drift migrate lint translations check format expand db dump restore diff branch logs services sites installations doctor open lsp corretto agent-manifest mrdp"},{"page":"local","title":"Local environment","type":"Reference","terms":"local environment latte services postgres dns caddy https sites origins localhost resolver trust frappe dev logs doctor databases env seed dump restore installations releases editor lsp zed crystalline ameba"},{"page":"crud","title":"Create a resource","type":"Proved recipe","terms":"A small CRUD feature, from model and changeset to a passing request spec. database validation model controller"},{"page":"forms","title":"Submit a rendered form","type":"Proved recipe","terms":"Post exactly the fields a view renders, so a spec catches a field its action’s contract refuses. form hidden field contract unknown field 422 corretto request spec lexbor submit select"},{"page":"json","title":"Read and write JSON","type":"Proved recipe","terms":"Answer the generated actions as JSON, bind JSON input, and check an update’s version with If-Match. api endpoint content negotiation accept json post csrf etag if-match 412 version lock_version"},{"page":"uploads","title":"Upload and keep a file","type":"Framework gap","terms":"Go from a request-scoped temporary file to a complete persistence recipe. storage image multipart upload"},{"page":"islands","title":"Mount a third-party component","type":"Draft recipe","terms":"Wrap a headless JavaScript library in a Caramel island: assets, lifecycle, history and tests. island javascript a11y-dialog dialog headless component htmx csp history sse"},{"page":"jobs","title":"Run a background job","type":"Proved recipe","terms":"Enqueue a typed job in the business transaction, drain it in a spec, and run workers without HTTP. queue cold brew worker work status retry hooks scheduler enqueue drain transaction rollback"},{"page":"webhooks","title":"Receive a signed webhook","type":"Proved recipe","terms":"Use raw-body ingress and provider authentication before contract binding. accept json post api csrf signature ingress raw body authenticate hmac secret env.test"},{"page":"sessions","title":"Sign users in with revocable sessions","type":"Proved recipe","terms":"Keep a random token in the signed cookie and its digest, expiry and revocation in PostgreSQL. login logout authentication session token revoke expire membership current_user sign_in corretto tenancy account clubhouse"},{"page":"boxoffice","title":"Build a box office","type":"Learning path","terms":"sweettalk tutorial box office ticket seats hold reservation checkout timer deadline lapse waitlist oversell concurrency row lock show"},{"page":"deploy","title":"Production","type":"Guide","terms":"deploy deployment production ship hosting linux binary release frappe build artifact docker static health readiness sigterm drain no-workers caramel_root caramel_socket app_origin app_secret jobs unknown db roles migrate"},{"page":"sweettalk","title":"SweetTalk","type":"Guide","terms":"sweettalk domain-driven design ddd bounded context aggregate entity value object event policy projection glossary ubiquitous language factory query finds remove service process saga deadline compensate compensation actor acting metadata composite check constraint database_check frappe make domain generator action contract field refusal 422 render_refusal pattern map repository specification anticorruption conformist outbox open-host published language shared kernel partnership distillation subdomain core supporting generic publishes open host outside system gateway"}],"version":"0.16.0"};
// Client behaviour. The build puts `const CARAMEL = {routes, searchIndex, version}` before this file.
// Every block guards on its element, so one file serves the landing page, the catalog and the docs.
(() => {
  const root = document.documentElement;

  // Theme: the stored choice wins over the system's, and the button flips whichever is showing.
  const themeButton = document.querySelector('.c-theme');
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const effective = () => root.dataset.theme ?? (scheme.matches ? 'dark' : 'light');
  const labelTheme = () => themeButton?.setAttribute('aria-label', `Switch to ${effective() === 'dark' ? 'light' : 'dark'} theme`);
  labelTheme();
  scheme.addEventListener('change', labelTheme);
  themeButton?.addEventListener('click', () => {
    const chosen = effective() === 'dark' ? 'light' : 'dark';
    root.dataset.theme = chosen;
    try { localStorage.setItem('caramel-theme', chosen); } catch (error) { /* storage is off: the choice lasts for this page */ }
    labelTheme();
  });

  // The sticky header's height places the rail, the outline and the anchors beneath it.
  const header = document.querySelector('.c-header');
  if (header) new ResizeObserver(() => root.style.setProperty('--header', `${header.offsetHeight}px`)).observe(header);

  // Search the documentation pages by title and terms.
  const input = document.getElementById('c-search');
  const results = document.getElementById('c-search-results');
  if (input && results) {
    const show = open => { results.hidden = !open; input.setAttribute('aria-expanded', String(open)); };
    const render = () => {
      const term = input.value.trim().toLowerCase();
      if (!term) { results.innerHTML = ''; show(false); return; }
      const found = CARAMEL.searchIndex.filter(r => `${r.title} ${r.terms}`.toLowerCase().includes(term)).slice(0, 8);
      results.innerHTML = found.length
        ? found.map(r => `<a href="${CARAMEL.routes[r.page]}">${r.title}<small>${r.type} · ${CARAMEL.version}</small></a>`).join('')
        : '<p>No results. Try “controller”, “JSON”, or “deploy”.</p>';
      show(true);
    };
    input.addEventListener('input', render);
    input.addEventListener('focus', render);
    input.addEventListener('keydown', event => {
      if (event.key === 'Enter') results.querySelector('a')?.click();
      if (event.key === 'Escape') { input.value = ''; render(); input.blur(); }
    });
    document.addEventListener('keydown', event => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        input.focus();
        input.select();
      }
    });
    document.addEventListener('click', event => { if (!event.target.closest('.c-search')) show(false); });
  }

  // The recipe finder hides the cards that do not match.
  const finder = document.getElementById('c-recipe-search');
  if (finder) {
    const cards = [...document.querySelectorAll('.c-recipe')];
    finder.addEventListener('input', () => {
      const term = finder.value.trim().toLowerCase();
      let shown = 0;
      for (const card of cards) {
        const match = card.dataset.search.includes(term);
        card.hidden = !match;
        if (match) shown += 1;
      }
      document.getElementById('c-recipe-count').textContent = `${shown} ${shown === 1 ? 'recipe' : 'recipes'}`;
      document.getElementById('c-empty').hidden = shown > 0;
    });
  }

  // The agents page shows the AGENTS.md that frappe new writes, on request.
  document.getElementById('c-agent-plain')?.addEventListener('click', event => {
    const button = event.currentTarget;
    const el = document.getElementById('c-agent-markdown');
    el.hidden = !el.hidden;
    button.textContent = el.hidden ? 'View AGENTS.md' : 'Hide AGENTS.md';
    button.setAttribute('aria-expanded', String(!el.hidden));
  });

  // The rail is open beside the page and folds away on a narrow screen.
  const railnav = document.querySelector('.c-railnav');
  const narrow = matchMedia('(max-width: 859px)');
  const syncRail = () => { if (railnav) railnav.open = !narrow.matches; };
  syncRail();
  narrow.addEventListener('change', syncRail);

  // The outline marks the section being read.
  const headings = [...document.querySelectorAll('.c-article h2[id]')];
  const links = [...document.querySelectorAll('.c-outline a[href^="#"]')];
  if (headings.length && header) {
    let scheduled = false;
    const update = () => {
      scheduled = false;
      const boundary = header.offsetHeight + (narrow.matches ? 80 : 40);
      let active = headings[0];
      for (const heading of headings) if (heading.getBoundingClientRect().top <= boundary) active = heading;
      if (scrollY > 0 && scrollY + innerHeight >= root.scrollHeight - 3) active = headings.at(-1);
      for (const link of links) {
        if (link.hash === `#${active.id}`) link.setAttribute('aria-current', 'location');
        else link.removeAttribute('aria-current');
      }
    };
    const queue = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(update); } };
    addEventListener('scroll', queue, {passive: true});
    addEventListener('resize', queue, {passive: true});
    update();
  }
})();
