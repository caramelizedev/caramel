// Application enhancements live here. All generated forms work without JS.
document.addEventListener('htmx:after:settle', () => {
  const target = document.querySelector('#content [role="alert"], #content h1');
  if (target instanceof HTMLElement) {
    target.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
  }
});
