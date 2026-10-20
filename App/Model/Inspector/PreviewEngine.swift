import Foundation

/// The script a Preview page runs so Hermes can use it (`drive_preview`, `docs/inspector.md` §2).
/// It inventories what can be clicked or typed into under legible refs (`btn-join-the-beta`,
/// `inp-email`), answers later looks with a delta, acts on a ref, rings the target for the person
/// to see, and tells the app when the person touches the page. Handles live as long as the page:
/// a navigation retires them. Shapes follow the desktop's `lib/preview-act/types.ts`.
enum PreviewEngine {
    static let source = #"""
    (function () {
      if (window.__hermesApp) { return; }
      var app = { book: [], coined: {}, url: location.href, seen: null };
      window.__hermesApp = app;

      var post = function (name, body) {
        try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {}
      };
      // The person's own touches and keys (synthetic events aren't trusted).
      document.addEventListener('pointerdown', function (e) { if (e.isTrusted) { post('hermesPerson', 'pointer'); } }, true);
      document.addEventListener('keydown', function (e) { if (e.isTrusted) { post('hermesPerson', 'key'); } }, true);

      var MAX = 120;
      var clamp = function (s, n) { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
      var visible = function (el) {
        if (!el.isConnected) { return false; }
        var style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) { return false; }
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };
      var roleOf = function (el) {
        var tag = el.tagName.toLowerCase();
        return el.getAttribute('role') || (tag === 'input' ? 'input:' + (el.type || 'text') : tag);
      };
      var stemOf = function (role) {
        if (role === 'button' || role === 'summary' || role === 'input:submit' || role === 'input:button') { return 'btn'; }
        if (role === 'a' || role === 'link') { return 'lnk'; }
        if (role === 'input:search' || role === 'searchbox') { return 'srch'; }
        if (role === 'input:checkbox' || role === 'checkbox') { return 'chk'; }
        if (role === 'input:radio' || role === 'radio') { return 'rdo'; }
        if (role === 'select' || role === 'combobox') { return 'sel'; }
        if (role === 'textarea') { return 'txt'; }
        if (role === 'switch') { return 'sw'; }
        if (role === 'tab') { return 'tab'; }
        if (role === 'menuitem') { return 'mi'; }
        if (role === 'option') { return 'opt'; }
        return role.indexOf('input') === 0 || role === 'textbox' ? 'inp' : 'el';
      };
      var slug = function (s) {
        return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').split('-').slice(0, 4).join('-').slice(0, 28);
      };
      var labelOf = function (el) {
        var aria = el.getAttribute('aria-label');
        if (aria) { return clamp(aria, 80); }
        var by = el.getAttribute('aria-labelledby');
        if (by) {
          var text = by.split(/\s+/).map(function (id) { var n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ');
          if (text.trim()) { return clamp(text, 80); }
        }
        if (el.id && el.labels === undefined) {
          var label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (label) { return clamp(label.textContent, 80); }
        }
        if (el.labels && el.labels.length) { return clamp(el.labels[0].textContent, 80); }
        var inner = (el.innerText || el.textContent || '').trim();
        if (inner) { return clamp(inner, 80); }
        return clamp(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || (el.type === 'submit' ? el.value : ''), 80);
      };
      var valueOf = function (el) {
        if (el.type === 'password') { return el.value ? '••••' : ''; }
        if (el.type === 'checkbox' || el.type === 'radio') { return el.checked ? 'checked' : ''; }
        if ('value' in el && typeof el.value === 'string' && el.tagName !== 'BUTTON') { return clamp(el.value, 60); }
        if (el.isContentEditable) { return clamp(el.textContent, 60); }
        return '';
      };
      var stableOf = function (el) {
        return el.id || el.getAttribute('data-testid') || el.getAttribute('name') || el.getAttribute('aria-label') || '';
      };
      var selectorFor = function (el) {
        if (el.id) { return '#' + CSS.escape(el.id); }
        var test = el.getAttribute('data-testid');
        return test ? '[data-testid="' + test + '"]' : undefined;
      };
      var offOf = function (el) { return !!(el.disabled || el.getAttribute('aria-disabled') === 'true'); };

      var retireIfNavigated = function () {
        if (app.url !== location.href) {
          app.url = location.href;
          app.book = [];
          app.coined = {};
          app.seen = null;
          return true;
        }
        return false;
      };

      var mint = function (role, label) {
        var stem = stemOf(role) + (slug(label) ? '-' + slug(label) : '');
        var nth = app.coined[stem] || 0;
        app.coined[stem] = nth + 1;
        return nth ? stem + '-' + nth : stem;
      };

      // The handle for an element: its own, one rebuilt by a re-render (same role and stable
      // name, or same role and label), or a new one.
      var bind = function (el, rebound) {
        for (var i = 0; i < app.book.length; i++) { if (app.book[i].el === el) { return app.book[i]; } }
        var role = roleOf(el), label = labelOf(el), stable = stableOf(el);
        for (var j = 0; j < app.book.length; j++) {
          var old = app.book[j];
          if (old.el.isConnected || old.role !== role) { continue; }
          if ((stable && old.stable === stable) || (!stable && old.label === label && label)) {
            old.el = el;
            rebound.push(old.ref);
            return old;
          }
        }
        var entry = { el: el, ref: mint(role, label), role: role, label: label, stable: stable };
        app.book.push(entry);
        return entry;
      };

      var CANDIDATES = 'a[href], button, input:not([type="hidden"]), select, textarea, summary, label[for], ' +
        '[role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [role="menuitem"], ' +
        '[role="switch"], [role="option"], [role="combobox"], [role="searchbox"], [role="textbox"], ' +
        '[contenteditable=""], [contenteditable="true"], [onclick], [tabindex]:not([tabindex="-1"])';

      var survey = function (max, full) {
        var navigated = retireIfNavigated();
        var rebound = [];
        var elements = [];
        var nodes = document.querySelectorAll(CANDIDATES);
        for (var i = 0; i < nodes.length && elements.length < max; i++) {
          var el = nodes[i];
          if (!visible(el)) { continue; }
          var entry = bind(el, rebound);
          entry.label = labelOf(el);
          var row = { ref: entry.ref, role: entry.role, label: entry.label };
          var selector = selectorFor(el); if (selector) { row.selector = selector; }
          var value = valueOf(el); if (value) { row.value = value; }
          if (offOf(el)) { row.disabled = true; }
          elements.push(row);
        }
        var previous = app.seen;
        var now = {};
        elements.forEach(function (row) { now[row.ref] = row; });
        app.seen = now;
        if (!previous || navigated || full) { return { elements: elements }; }
        var added = [], changed = [], removed = [], same = 0;
        elements.forEach(function (row) {
          var was = previous[row.ref];
          if (!was) { added.push(row); return; }
          var change = { ref: row.ref }, moved = false;
          if ((was.label || '') !== (row.label || '')) { change.label = row.label; moved = true; }
          if ((was.value || '') !== (row.value || '')) { change.value = row.value || ''; moved = true; }
          if (!!was.disabled !== !!row.disabled) { change.disabled = !!row.disabled; moved = true; }
          if (moved) { changed.push(change); } else if (rebound.indexOf(row.ref) < 0) { same += 1; }
        });
        Object.keys(previous).forEach(function (ref) { if (!now[ref]) { removed.push(ref); } });
        var churn = added.length + removed.length;
        if (churn * 2 >= Math.max(1, Object.keys(previous).length)) { return { elements: elements }; }
        var delta = { same: same };
        if (added.length) { delta.added = added; }
        if (changed.length) { delta.changed = changed; }
        if (removed.length) { delta.removed = removed; }
        var kept = rebound.filter(function (ref) { return now[ref]; });
        if (kept.length) { delta.rebound = kept; }
        return { delta: delta };
      };

      var resolve = function (a) {
        if (a.ref) {
          if (retireIfNavigated()) {
            return { error: 'The page navigated since the last look, so ' + a.ref + ' no longer points anywhere. Call elements again.' };
          }
          var bound = app.book.filter(function (entry) { return entry.ref === a.ref; })[0];
          if (!bound) { return { error: 'Unknown element ' + a.ref + '. Call elements to get current refs.' }; }
          if (!bound.el.isConnected) {
            survey(MAX, false);
            if (!bound.el.isConnected) { return { error: a.ref + ' has been removed from the page since the last look. Call elements again.' }; }
          }
          return { el: bound.el };
        }
        var selector = (a.selector || '').trim();
        if (!selector) { return { error: 'Pass a ref from elements, or a CSS selector.' }; }
        var el = null;
        try { el = document.querySelector(selector); } catch (e) { return { error: 'Not a valid CSS selector: ' + selector }; }
        return el ? { el: el } : { error: 'No element matches ' + selector + '.' };
      };

      var describe = function (el) { var label = labelOf(el); return el.tagName.toLowerCase() + (label ? ' "' + label + '"' : ''); };
      var answer = function (result) { result.url = location.href; result.title = document.title || ''; return result; };
      var wait = function (ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); };
      var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

      var pointAt = function (el) {
        var r = el.getBoundingClientRect();
        return { clientX: Math.round(r.left + r.width / 2), clientY: Math.round(r.top + r.height / 2), bubbles: true, cancelable: true, view: window };
      };
      var fire = function (el, type, init, Kind) {
        try { return el.dispatchEvent(new (Kind || MouseEvent)(type, init)); } catch (e) { return el.dispatchEvent(new Event(type, init)); }
      };
      var setValue = function (el, text) {
        var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value');
        if (setter && setter.set) { setter.set.call(el, text); } else { el.value = text; }
      };
      var keyInit = function (key) {
        var named = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, ' ': 32, Space: 32 };
        var code = named[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
        return { key: key === 'Space' ? ' ' : key, code: key.length === 1 ? 'Key' + key.toUpperCase() : key, keyCode: code, which: code, bubbles: true, cancelable: true };
      };
      var submitFrom = function (el) {
        var form = el.form || (el.closest && el.closest('form'));
        if (!form) { return false; }
        if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); }
        return true;
      };
      var press = function (el, key) {
        var init = keyInit(key);
        var go = fire(el, 'keydown', init, KeyboardEvent);
        if (key.length === 1) { fire(el, 'keypress', init, KeyboardEvent); }
        fire(el, 'keyup', init, KeyboardEvent);
        if (!go) { return; }
        var tag = el.tagName;
        if (key === 'Enter') {
          if (tag === 'INPUT' && el.type !== 'checkbox' && el.type !== 'radio') { submitFrom(el); }
          else if (tag === 'BUTTON' || tag === 'A' || tag === 'SUMMARY' || el.getAttribute('role') === 'button') { el.click(); }
        } else if ((key === ' ' || key === 'Space') && (tag === 'BUTTON' || el.type === 'checkbox' || el.type === 'radio' || el.getAttribute('role') === 'button')) {
          el.click();
        }
      };

      // The ring Hermes draws around what it's about to touch (`agentHighlight`).
      app.ring = function (a, label, ink, onInk) {
        app.unring();
        var target = resolve(a);
        if (!target.el) { return false; }
        target.el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: still ? 'auto' : 'smooth' });
        var layer = document.createElement('div');
        layer.id = '__hermesRing';
        layer.setAttribute('aria-hidden', 'true');
        layer.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:3px solid ' + ink + ';border-radius:12px;box-sizing:border-box;transition:all .18s ease-out;';
        var tag = document.createElement('div');
        tag.textContent = '✦ Hermes · ' + label;
        tag.style.cssText = 'position:absolute;right:-3px;bottom:100%;margin-bottom:6px;padding:3px 9px;border-radius:7px;background:' + ink + ';color:' + onInk + ';font:600 11px -apple-system,system-ui,sans-serif;white-space:nowrap;';
        layer.appendChild(tag);
        document.documentElement.appendChild(layer);
        var place = function () {
          if (!layer.isConnected) { return; }
          var r = target.el.getBoundingClientRect();
          layer.style.left = (r.left - 6) + 'px';
          layer.style.top = (r.top - 6) + 'px';
          layer.style.width = (r.width + 12) + 'px';
          layer.style.height = (r.height + 12) + 'px';
          requestAnimationFrame(place);
        };
        place();
        return true;
      };
      app.unring = function () { var old = document.getElementById('__hermesRing'); if (old) { old.remove(); } };

      // The page's visible text, for `preview.read`.
      app.read = function () {
        return JSON.stringify({ url: location.href, title: document.title || '', text: (document.body ? document.body.innerText : '') || '' });
      };

      app.run = async function (a) {
        var kind = a.kind;
        if (kind === 'elements') {
          var looked = survey(Math.max(1, Math.min(a.max || MAX, MAX)), !!a.full);
          var empty = !looked.delta && !(looked.elements || []).length;
          if (empty) { looked.note = 'No interactive elements found; the page may still be loading.'; }
          looked.success = true;
          return answer(looked);
        }
        if (kind === 'scroll') {
          var t = a.ref || a.selector ? resolve(a) : {};
          if (t.error) { return answer({ success: false, error: t.error }); }
          var by = a.to === 'top' ? -1e7 : a.to === 'bottom' ? 1e7 : (a.amount != null ? a.amount : Math.round(innerHeight * 0.9));
          (t.el || window).scrollBy({ top: by, behavior: still ? 'auto' : 'smooth' });
          return answer({ success: true, acted: t.el ? 'scrolled ' + describe(t.el) : 'scrolled the page' });
        }
        if (kind === 'strobe') {
          var s = a.ref || a.selector ? resolve(a) : { el: document.body };
          if (s.error) { return answer({ success: false, error: s.error }); }
          return answer({ success: true, acted: 'showed ' + describe(s.el) });
        }
        var target = resolve(a);
        if (target.error) { return answer({ success: false, error: target.error }); }
        var el = target.el;
        if (offOf(el)) { return answer({ success: false, error: describe(el) + ' is disabled right now.' }); }
        var at = pointAt(el);
        var acted;
        if (kind === 'hover') {
          fire(el, 'pointerover', at, PointerEvent); fire(el, 'pointerenter', at, PointerEvent);
          fire(el, 'mouseover', at); fire(el, 'mouseenter', at); fire(el, 'mousemove', at);
          acted = 'hovered ' + describe(el);
        } else if (kind === 'click') {
          fire(el, 'pointerdown', at, PointerEvent); fire(el, 'mousedown', at);
          if (el.focus) { el.focus({ preventScroll: true }); }
          fire(el, 'pointerup', at, PointerEvent); fire(el, 'mouseup', at);
          el.click();
          acted = 'clicked ' + describe(el);
        } else if (kind === 'type') {
          var text = a.text || '';
          if (el.focus) { el.focus({ preventScroll: true }); }
          if (el.isContentEditable) {
            document.getSelection().selectAllChildren(el);
            document.execCommand('insertText', false, text);
          } else if ('value' in el) {
            setValue(el, text);
            fire(el, 'input', { bubbles: true, data: text, inputType: 'insertText' }, InputEvent);
            fire(el, 'change', { bubbles: true }, Event);
          } else {
            return answer({ success: false, error: describe(el) + ' does not take text. Click it, or type into a field.' });
          }
          acted = 'typed into ' + describe(el);
          if (a.submit) { press(el, 'Enter'); acted += ' and pressed Enter'; }
        } else if (kind === 'press') {
          var key = a.key || '';
          var on = document.activeElement && document.activeElement !== document.body ? document.activeElement : el;
          if (key.length === 1 && (on === document.body || on === document.documentElement) && !a.allowShortcut) {
            return answer({ success: false, error: 'A printable key on the page itself would be a shortcut. Focus a field first, or pass allow_shortcut.' });
          }
          press(on, key);
          acted = 'pressed ' + key + ' on ' + describe(on);
        } else {
          return answer({ success: false, error: 'Unknown action ' + kind + '.' });
        }
        await wait(220);
        var after = survey(MAX, false);
        after.success = true;
        after.acted = acted;
        return answer(after);
      };
    })();
    """#
}
