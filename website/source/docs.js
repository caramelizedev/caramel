(() => {
  const root = document.querySelector('.c-documentation');
  if (!root) return;
  const header = root.querySelector('.c-header');
  const navigation = root.querySelector('.c-docnav');
  const mobile = matchMedia('(max-width:899px)');
  const syncNavigation = () => { navigation.open = !mobile.matches; };
  syncNavigation();
  mobile.addEventListener('change', syncNavigation);
  new ResizeObserver(() => root.style.setProperty('--docs-header', `${header.offsetHeight}px`)).observe(header);

  const headings = [...root.querySelectorAll('#c-article h2[id]')];
  const links = [...root.querySelectorAll('.c-toc a')];
  if (!headings.length) return;
  let scheduled = false;
  const updateSection = () => {
    scheduled = false;
    const boundary = header.offsetHeight + (mobile.matches ? 80 : 40);
    let active = headings[0];
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top <= boundary) active = heading;
    }
    if (scrollY > 0 && scrollY + innerHeight >= document.documentElement.scrollHeight - 3) active = headings.at(-1);
    for (const link of links) {
      if (link.hash === `#${active.id}`) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    }
  };
  const queueUpdate = () => {
    if (!scheduled) { scheduled = true; requestAnimationFrame(updateSection); }
  };
  addEventListener('scroll', queueUpdate, {passive:true});
  addEventListener('resize', queueUpdate, {passive:true});
  updateSection();
})();
