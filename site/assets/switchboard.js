/* SwitchBoard site — theme switch, nav toggle, copy buttons, docs scrollspy,
   heading anchors. */
(function () {
  'use strict';

  /* ---- theme switch ----
     The stored preference is applied inline in <head> before first paint;
     this only wires the control and keeps the label truthful. With no stored
     choice the page follows the OS, so the label has to read the media query
     rather than the data attribute. */
  var root = document.documentElement;
  var sw = document.querySelector('.themesw');
  if (sw) {
    var systemDark = window.matchMedia('(prefers-color-scheme: dark)');
    var effective = function () {
      return root.dataset.theme || (systemDark.matches ? 'dark' : 'light');
    };
    var relabel = function () {
      sw.setAttribute('aria-label', 'Switch to ' + (effective() === 'dark' ? 'light' : 'dark') + ' theme');
    };
    sw.addEventListener('click', function () {
      root.dataset.theme = effective() === 'dark' ? 'light' : 'dark';
      try { localStorage.setItem('sb-theme', root.dataset.theme); } catch (e) {}
      relabel();
    });
    // Keep following the OS for as long as the reader has not overridden it.
    if (systemDark.addEventListener) {
      systemDark.addEventListener('change', function () { if (!root.dataset.theme) relabel(); });
    }
    relabel();
  }

  /* ---- mobile nav ---- */
  var NAV_WIDE = '(min-width: 901px)';
  var toggle = document.querySelector('.nav__toggle');
  var links = document.getElementById('nav-links');
  if (toggle && links) {
    var sync = function () {
      var wide = window.matchMedia(NAV_WIDE).matches;
      if (wide) { links.hidden = false; toggle.setAttribute('aria-expanded', 'false'); }
      else if (toggle.getAttribute('aria-expanded') !== 'true') { links.hidden = true; }
    };
    toggle.addEventListener('click', function () {
      var open = toggle.getAttribute('aria-expanded') === 'true';
      toggle.setAttribute('aria-expanded', String(!open));
      links.hidden = open;
      toggle.textContent = open ? 'Menu' : 'Close';
    });
    links.addEventListener('click', function (e) {
      if (e.target.tagName === 'A' && !window.matchMedia(NAV_WIDE).matches) {
        toggle.setAttribute('aria-expanded', 'false');
        links.hidden = true;
        toggle.textContent = 'Menu';
      }
    });
    window.addEventListener('resize', sync);
    sync();
  }

  /* ---- copy to clipboard ----
     .cmd is the compact hero command row; it has no .code__bar but carries
     the same .code__copy button and a <code> payload, so it hooks in here. */
  document.querySelectorAll('.code, .cmd').forEach(function (block) {
    var btn = block.querySelector('.code__copy');
    var code = block.querySelector('code');
    if (!btn || !code) return;
    btn.addEventListener('click', function () {
      var text = code.innerText.replace(/ /g, ' ');
      var done = function () {
        btn.textContent = 'Copied';
        btn.dataset.done = '1';
        setTimeout(function () { btn.textContent = 'Copy'; btn.dataset.done = '0'; }, 1600);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else { fallback(); }
      function fallback() {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.cssText = 'position:absolute;left:-9999px';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); done(); } catch (e) { btn.textContent = 'Failed'; }
        document.body.removeChild(ta);
      }
    });
  });

  /* ---- docs scrollspy ---- */
  var railLinks = Array.prototype.slice.call(document.querySelectorAll('.rail a[href^="#"]'));
  if (railLinks.length) {
    var map = {};
    var targets = [];
    railLinks.forEach(function (a) {
      var el = document.getElementById(a.getAttribute('href').slice(1));
      if (el) { map[el.id] = a; targets.push(el); }
    });
    // Only start rewriting the address bar once the reader has actually
    // scrolled — otherwise the first observer callback stamps a hash on load,
    // which pollutes the URL and fights with reload/restore behaviour.
    var userScrolled = false;
    window.addEventListener('scroll', function () { userScrolled = true; }, { once: true, passive: true });

    var setActive = function (id) {
      railLinks.forEach(function (a) { a.classList.remove('active'); });
      if (map[id]) {
        map[id].classList.add('active');
        if (userScrolled && history.replaceState) history.replaceState(null, '', '#' + id);
      }
    };
    // Pick the last section whose top has passed the reading line. An
    // IntersectionObserver is the tempting choice here, but doc sections are
    // taller than the viewport and overlap the observation band, so several
    // report as visible at once and the earliest one wins incorrectly.
    var READING_LINE = 100;
    var current = null;
    var ticking = false;

    var update = function () {
      ticking = false;
      var y = window.scrollY + READING_LINE;
      var atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
      var pick = targets[0];
      if (atBottom) {
        pick = targets[targets.length - 1];
      } else {
        for (var i = 0; i < targets.length; i++) {
          if (targets[i].getBoundingClientRect().top + window.scrollY <= y) pick = targets[i];
        }
      }
      if (pick && pick.id !== current) { current = pick.id; setActive(current); }
    };

    window.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; window.requestAnimationFrame(update); }
    }, { passive: true });
    window.addEventListener('resize', update, { passive: true });
    update();
  }

  /* ---- heading anchors in docs ----
     Section ids live on the <section>, so an h2 takes its parent's id;
     sub-headings carry their own. */
  var addAnchor = function (h, id) {
    if (!id) return;
    var a = document.createElement('a');
    a.className = 'anch';
    a.href = '#' + id;
    a.textContent = '#';
    a.setAttribute('aria-label', 'Link to ' + h.textContent.trim());
    h.appendChild(a);
  };
  document.querySelectorAll('.doc section[id] > h2').forEach(function (h) {
    addAnchor(h, h.parentElement.id);
  });
  document.querySelectorAll('.doc h3[id]').forEach(function (h) {
    addAnchor(h, h.id);
  });

  /* ---- year ---- */
  document.querySelectorAll('[data-year]').forEach(function (el) {
    el.textContent = String(new Date().getFullYear());
  });
})();
