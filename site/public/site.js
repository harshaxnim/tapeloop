// Opens the cassette in the navigation bar into the full wordmark as the home page scrolls: --p goes from 0 (the
// cassette alone, at the top) to 1 (the wordmark, once the big wordmark in the hero has scrolled under the bar).
(() => {
  const root = document.documentElement;
  const hero = document.querySelector("[data-brand-hero]");
  if (!hero) {
    root.style.setProperty("--p", "1");
    return;
  }
  let end = 1;
  const measure = () => {
    end = Math.max(1, hero.getBoundingClientRect().bottom + window.scrollY - 52);
  };
  let queued = false;
  const update = () => {
    queued = false;
    const p = Math.min(1, Math.max(0, window.scrollY / end));
    root.style.setProperty("--p", p.toFixed(3));
  };
  const request = () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(update);
    }
  };
  measure();
  update();
  addEventListener("scroll", request, { passive: true });
  addEventListener("resize", () => {
    measure();
    request();
  });
})();
