(() => {
  // Applies the colour theme a developer chose on the inspector, before the page paints.
  let chosen = null;
  try { chosen = localStorage.getItem('caramel.dev.theme'); } catch (_) { /* Blocked storage. */ }
  if (chosen === 'light' || chosen === 'dark') document.documentElement.dataset.theme = chosen;
})();
