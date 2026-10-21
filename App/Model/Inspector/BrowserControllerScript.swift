import Foundation
import WebKit

/// The scripts the app's browser runs while Hermes drives it (`docs/web.md` §6.3), in a content
/// world of their own: the page can't see them, call them, fake their answers or post to their
/// handler. `person` runs in every frame from the start; `control` in the main frame once it has
/// loaded: an outline of the page with refs like `@e5` (what `browser_snapshot` answers and
/// `browser_click` / `browser_type` take back), and the actions themselves.
///
/// What the person typed never goes to Hermes: a field they edited, or one that holds a secret by
/// its kind (ever a password, a card or one-time-code autocomplete, a name or label that says so,
/// masked text), shows only "(filled)". Hermes never types into a secret field, and no screenshot
/// is taken while one with something in it is on the page.
enum BrowserControllerScript {
    static let world = WKContentWorld.world(name: "hermes-browser")

    /// Every frame, at document start: the person's own touches and keys (Take Over), the fields
    /// they edited, and fields that were ever a password (a "Show password" button flips them).
    static let person = #"""
    (function () {
      if (window.__hermesSecrets) { return; }
      var S = { edited: new WeakSet(), everPassword: new WeakSet() };
      window.__hermesSecrets = S;
      var post = function (body) {
        try { window.webkit.messageHandlers.hermesPerson.postMessage(body); } catch (e) {}
      };
      document.addEventListener('pointerdown', function (e) { if (e.isTrusted) { post('pointer'); } }, true);
      document.addEventListener('keydown', function (e) { if (e.isTrusted) { post('key'); } }, true);
      var mark = function (e) {
        if (!e.isTrusted || !e.target) { return; }
        var el = e.target.isContentEditable && e.target.closest ? (e.target.closest('[contenteditable]') || e.target) : e.target;
        S.edited.add(el);
      };
      document.addEventListener('input', mark, true);
      document.addEventListener('change', mark, true);
      new MutationObserver(function (records) {
        records.forEach(function (r) {
          if ((r.oldValue || '').toLowerCase() === 'password') { S.everPassword.add(r.target); }
        });
      }).observe(document, { attributes: true, attributeFilter: ['type'], attributeOldValue: true, subtree: true });
    })();
    """#

    /// The main frame, at document end.
    static let control = #"""
    (function () {
      if (window.__hermesControl) { return; }
      var c = { refs: {} };
      window.__hermesControl = c;
      var S = window.__hermesSecrets || { edited: new WeakSet(), everPassword: new WeakSet() };

      var clamp = function (s, n) { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
      var visible = function (el) {
        if (!el.isConnected) { return false; }
        var style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) { return false; }
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };
      var INTERACTIVE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],' +
        '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[role=combobox],' +
        '[role=searchbox],[role=textbox],[contenteditable=""],[contenteditable=true]';
      var FIELDS = 'input:not([type=hidden]),select,textarea,[contenteditable=""],[contenteditable=true]';
      var roleOf = function (el) {
        var role = el.getAttribute('role');
        if (role) { return role; }
        var tag = el.tagName.toLowerCase();
        if (tag === 'a') { return 'link'; }
        if (tag === 'select') { return 'combobox'; }
        if (tag === 'textarea') { return 'textbox'; }
        if (tag === 'summary') { return 'button'; }
        if (tag === 'input') {
          var type = (el.type || 'text').toLowerCase();
          if (type === 'submit' || type === 'button' || type === 'reset') { return 'button'; }
          if (type === 'checkbox' || type === 'radio') { return type; }
          if (type === 'search') { return 'searchbox'; }
          return 'textbox';
        }
        return el.isContentEditable ? 'textbox' : tag;
      };
      var isField = function (el) {
        if (el.tagName === 'INPUT') { return !/^(submit|button|reset|image)$/i.test(el.type || ''); }
        return el.tagName === 'SELECT' || el.tagName === 'TEXTAREA' || el.isContentEditable;
      };
      // A field's own words: never its contents (an editable element's text is what was typed).
      var labelOf = function (el) {
        var aria = el.getAttribute('aria-label');
        if (aria) { return clamp(aria, 80); }
        if (el.labels && el.labels.length) { return clamp(el.labels[0].textContent, 80); }
        if (!isField(el)) {
          var inner = el.tagName === 'INPUT' ? (el.value || '') : (el.innerText || el.textContent || '');
          if (inner.trim()) { return clamp(inner, 80); }
        }
        return clamp(el.getAttribute('placeholder') || el.getAttribute('data-placeholder') || el.getAttribute('title') ||
                     el.getAttribute('alt') || el.getAttribute('name') || '', 80);
      };
      var isPassword = function (el) {
        if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') { S.everPassword.add(el); return true; }
        return S.everPassword.has(el);
      };
      var SECRET_AUTOCOMPLETE = /(^|\s)(cc-[a-z-]+|one-time-code|current-password|new-password)(\s|$)/i;
      var SECRET_WORDS = /(passw|passcode|passphrase|card.?num|cc.?num|cardnumber|\bcvc|\bcvv|\bcsc|security.?code|one.?time|\botp\b|2fa|mfa|verification.?code|auth.?code|\bpin\b|ssn|social.?security)/i;
      // A secret by its kind: Hermes never types into it, and the outline never shows it.
      var isSecretKind = function (el) {
        if (!isField(el)) { return false; }
        if (isPassword(el)) { return true; }
        if (SECRET_AUTOCOMPLETE.test(el.getAttribute('autocomplete') || '')) { return true; }
        var words = [el.getAttribute('name'), el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
                     el.labels && el.labels.length ? el.labels[0].textContent : ''].join(' ');
        if (SECRET_WORDS.test(words)) { return true; }
        var masked = getComputedStyle(el).webkitTextSecurity;
        return !!masked && masked !== 'none';
      };
      var valueOf = function (el) {
        if (el.isContentEditable) { return el.textContent || ''; }
        return typeof el.value === 'string' ? el.value : '';
      };
      var withheld = function (el) { return isSecretKind(el) || S.edited.has(el); };
      // What the field holds, for the model: "(filled)" for anything withheld.
      var stateOf = function (el) {
        if (el.type === 'checkbox' || el.type === 'radio') { return el.checked ? ' (checked)' : ''; }
        if (!isField(el)) { return el.disabled ? ' (disabled)' : ''; }
        if (isPassword(el)) { return valueOf(el) ? ' (password, filled)' : ' (password)'; }
        if (withheld(el)) { return valueOf(el) ? ' (filled)' : ''; }
        if (el.disabled) { return ' (disabled)'; }
        return valueOf(el) ? ': "' + clamp(valueOf(el), 60) + '"' : '';
      };
      // The person's turn: a password or a one-time code is asked for.
      var signInField = function () {
        var fields = document.querySelectorAll(FIELDS);
        for (var i = 0; i < fields.length; i++) {
          var el = fields[i];
          var ac = el.getAttribute('autocomplete') || '';
          if ((isPassword(el) || /one-time-code|current-password|new-password/i.test(ac)) && visible(el)) { return true; }
        }
        return false;
      };
      c.signIn = signInField;
      // Something withheld, with something in it, on screen: no screenshot then.
      c.showsWithheld = function () {
        var fields = document.querySelectorAll(FIELDS);
        for (var i = 0; i < fields.length; i++) {
          var el = fields[i];
          if (withheld(el) && valueOf(el) && visible(el)) { return true; }
        }
        return false;
      };

      c.snapshot = function (full) {
        c.refs = {};
        var lines = [], n = 1, LIMIT = full ? 800 : 400;
        var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
        var node;
        while ((node = walker.nextNode()) && lines.length < LIMIT) {
          var tag = node.tagName.toLowerCase();
          if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template') { continue; }
          if (/^h[1-6]$/.test(tag)) {
            if (visible(node)) { lines.push('- heading "' + clamp(node.textContent, 120) + '" [level=' + tag[1] + ']'); }
            continue;
          }
          if (node.matches(INTERACTIVE)) {
            if (!visible(node)) { continue; }
            var ref = 'e' + (n++);
            c.refs[ref] = node;
            lines.push('- ' + roleOf(node) + ' "' + labelOf(node) + '"' + stateOf(node) + ' [@' + ref + ']');
            continue;
          }
          if (full && (tag === 'p' || tag === 'li' || tag === 'td' || tag === 'th' || tag === 'label' || tag === 'span' && node.children.length === 0)) {
            if (node.closest && node.closest('[contenteditable=""],[contenteditable=true]')) { continue; }
            var text = clamp(node.textContent, 200);
            if (text && visible(node)) { lines.push('- text "' + text + '"'); }
          }
        }
        return JSON.stringify({ success: true, url: location.href, title: document.title, snapshot: lines.join('\n'),
                                element_count: n - 1, sign_in: signInField() });
      };

      var find = function (ref) {
        ref = String(ref || '').replace(/^\[|\]$/g, '').replace(/^ref=/, '').replace(/^@/, '');
        var el = c.refs[ref];
        return el && el.isConnected ? el : null;
      };
      c.click = function (ref) {
        var el = find(ref);
        if (!el) { return JSON.stringify({ error: 'No element ' + ref + ' on the page now. Take a new snapshot.' }); }
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        if (el.focus) { el.focus(); }
        el.click();
        return JSON.stringify({ success: true, clicked: ref });
      };
      c.type = function (ref, text) {
        var el = find(ref);
        if (!el) { return JSON.stringify({ error: 'No element ' + ref + ' on the page now. Take a new snapshot.' }); }
        if (isPassword(el)) {
          return JSON.stringify({ error: 'That is a password field. Signing in is the person\'s turn in this app: ask them to take over, then wait.', sign_in: true });
        }
        if (isSecretKind(el)) {
          return JSON.stringify({ error: 'That field takes a card number, a security code or a one-time code. Entering those is the person\'s turn in this app: ask them to take over, then wait.', sign_in: signInField() });
        }
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        if (el.focus) { el.focus(); }
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) { setter.set.call(el, text); } else { el.value = text; }
        }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return JSON.stringify({ success: true, typed: ref, characters: String(text).length });
      };
      c.scroll = function (direction) {
        var amount = Math.round(window.innerHeight * 0.8) * (direction === 'up' ? -1 : 1);
        window.scrollBy({ top: amount, behavior: 'instant' });
        return JSON.stringify({ success: true, scrolled: direction === 'up' ? 'up' : 'down', y: Math.round(window.scrollY) });
      };
      c.press = function (key) {
        var target = document.activeElement || document.body;
        var options = { key: key, bubbles: true, cancelable: true };
        var allowed = target.dispatchEvent(new KeyboardEvent('keydown', options));
        target.dispatchEvent(new KeyboardEvent('keyup', options));
        if (allowed && key === 'Enter' && target.form) {
          if (target.form.requestSubmit) { target.form.requestSubmit(); } else { target.form.submit(); }
        }
        if (allowed && key === 'Tab') {
          var focusable = Array.prototype.filter.call(document.querySelectorAll(INTERACTIVE), visible);
          var next = focusable[(focusable.indexOf(target) + 1) % Math.max(focusable.length, 1)];
          if (next && next.focus) { next.focus(); }
        }
        return JSON.stringify({ success: true, pressed: key });
      };
    })();
    """#
}
