// Application enhancements live here. All generated forms work without JS.
// After a swap that replaces the page content, move focus to its alert or
// heading. Swaps into smaller regions keep the user's focus and caret.
document.addEventListener('htmx:after:settle', (event) => {
  const content = document.getElementById('content');
  if (!content || !(event.target instanceof Node) || !event.target.contains(content)) return;
  const target = content.querySelector('[role="alert"], h1');
  if (target instanceof HTMLElement) {
    target.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
  }
});
