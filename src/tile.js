/* cloudflare.usage: keeps the Cloudflare tile current while the Dashboard stays open.
 * Every 30 s it rewrites the relative times; every 5 min it reloads the tile body
 * from include/tile.php, which reads the local cache only (never Cloudflare). */
(function () {
  'use strict';
  var TICK_MS = 30 * 1000;
  var REFRESH_MS = 5 * 60 * 1000;
  var STALE_S = 1800;
  var lastRefresh = Date.now();

  function dur(sec) {
    var min = Math.ceil(Math.max(0, sec) / 60);
    return min >= 60 ? Math.floor(min / 60) + ' h ' + (min % 60) + ' min' : min + ' min';
  }

  function clock(epoch) {
    return new Date(epoch * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  function each(root, sel, fn) {
    Array.prototype.forEach.call(root.querySelectorAll(sel), fn);
  }

  function tick() {
    var body = document.getElementById('cfu-body');
    if (!body) return;
    var now = Date.now() / 1000;
    each(body, '[data-cfu-time]', function (el) { el.textContent = clock(+el.getAttribute('data-cfu-time')); });
    each(body, '[data-cfu-ago]', function (el) {
      var s = now - el.getAttribute('data-cfu-ago');
      el.textContent = s < 60 ? 'just now' : dur(s) + ' ago';
    });
    each(body, '[data-cfu-reset]', function (el) {
      var s = el.getAttribute('data-cfu-reset') - now;
      el.textContent = s > 0 ? 'in ' + dur(s) : 'now, waiting for the next update';
    });
    each(body, '[data-cfu-updated]', function (el) {
      var u = +el.getAttribute('data-cfu-updated');
      el.classList.toggle('cfu-stale', u > 0 && now - u > STALE_S);
    });
  }

  function refresh() {
    lastRefresh = Date.now();
    fetch('/plugins/cloudflare.usage/include/tile.php', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
      .then(function (html) {
        var body = document.getElementById('cfu-body');
        if (body) { body.innerHTML = html; tick(); }
      })
      .catch(function () { /* keep showing the last render; the stale note covers it */ });
  }

  function start() {
    tick();
    setInterval(tick, TICK_MS);
    setInterval(function () { if (!document.hidden) refresh(); }, REFRESH_MS);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && Date.now() - lastRefresh > REFRESH_MS) refresh();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
