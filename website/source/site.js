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
