// Redraws the AI on HKS dashboard every 30 seconds without reloading the page
(function () {
  'use strict';
  function refresh() {
    var root = document.getElementById('aih-root');
    if (!root || document.hidden) return;
    var open = Array.prototype.map.call(root.querySelectorAll('details[open]'), function (d) { return d.getAttribute('data-key'); });
    fetch('/plugin/hks-ai-dashboard/content', { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.text() : null; })
      .then(function (html) {
        if (!html) return;
        var box = document.createElement('div');
        box.innerHTML = html;
        var fresh = box.querySelector('#aih-root');
        if (!fresh) return;
        // keep the rows the user opened
        open.forEach(function (k) { var d = fresh.querySelector('details[data-key="' + k + '"]'); if (d) d.setAttribute('open', ''); });
        root.replaceWith(fresh);
      })
      .catch(function () {});
  }
  setInterval(refresh, 30000);
})();
// Times come from the server in UTC; show them in the viewer's own time
(function () {
  'use strict';
  function localize(root) {
    Array.prototype.forEach.call((root || document).querySelectorAll('[data-ms]'), function (e) {
      var ms = parseInt(e.getAttribute('data-ms'), 10);
      if (ms) e.textContent = new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    });
  }
  localize();
  new MutationObserver(function () { var r = document.getElementById('aih-root'); if (r && !r.getAttribute('data-local')) { localize(r); r.setAttribute('data-local', '1'); } })
    .observe(document.body, { childList: true, subtree: true });
})();
// After Approve or Reject the page comes back with ?done=...; say what happened once
(function () {
  'use strict';
  var done = (location.search.match(/[?&]done=(\w+)/) || [])[1];
  var text = { approved: 'Approved. The chat is being created.', rejected: 'Rejected.', failed: 'That did not work. You may not have permission to approve.' }[done];
  if (!text) return;
  var tries = 0, t = setInterval(function () {
    var root = document.getElementById('aih-root');
    if (root || ++tries > 40) {
      clearInterval(t);
      if (!root || root.querySelector('.aih-alert')) return;
      var d = document.createElement('div'); d.className = 'aih-alert' + (done === 'failed' ? ' aih-alert-error' : ''); d.textContent = text;
      var head = root.querySelector('.aih-head'); head ? head.insertAdjacentElement('afterend', d) : root.prepend(d);
      history.replaceState(null, '', location.pathname);
    }
  }, 250);
})();
