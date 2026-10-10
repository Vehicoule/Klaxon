// kx_a11y.js — emscripten --js-library: ARIA hidden-DOM accessibility bridge
// for the Klaxon wasm port (Phase 3f — docs/specs/phase-3f-wasm-plan.md §5).
//
// Zig → JS (wasm imports implemented here):
//   kx_a11y_event(kind, node_id, text_ptr, text_len, region)
//     kind    0=tree_dirty 1=focus_changed 2=announce 3=control_changed
//     node_id Node pointer (decimal) — focus_changed/control_changed carry it;
//             ptrToIndex maps it to the kx_a11y_dump_tree dump order index.
//             tree_dirty carries the ROOT node pointer instead.
//     text    UTF-8 announce payload (borrowed during the call only).
//     region  0=off 1=polite 2=assertive (semantics.LiveRegion).
//   kx_js_a11y_event(...) — alias import, same signature.
//
// JS → Zig (wasm exports, EXPORTED_FUNCTIONS in the emcc link step):
//   kx_a11y_dump_tree(root_node) -> char*   free with kx_a11y_free_string
//   kx_a11y_free_string(ptr)
//   kx_a11y_key(down, key, mod)             SDL_Keycode + SDL_Keymod; pushes
//                                           SDL_EVENT_KEY_DOWN / KEY_UP

mergeInto(LibraryManager.library, {

  $KX_A11Y: {
    inited: false,
    rootEl: null,
    livePolite: null,
    liveAssertive: null,
    nodes: [],
    focusedIndex: -1,
    ptrToIndex: {},
    rootNodePtr: 0,
    rootNodeTried: false,
    warnedNoRoot: false,

    initDom: function () {
      if (KX_A11Y.inited) return;
      KX_A11Y.inited = true;
      var root = document.getElementById('kx-a11y-root');
      if (!root) return;
      KX_A11Y.rootEl = root;

      var canvas = document.getElementById('canvas');
      if (canvas) {
        canvas.setAttribute('role', 'img');
        canvas.setAttribute('aria-label', 'Klaxon application');
        canvas.setAttribute('aria-owns', 'kx-a11y-root');
        if (document.activeElement === document.body) {
          try { canvas.focus({ preventScroll: true }); } catch (e) {}
        }
      }

      KX_A11Y.livePolite = KX_A11Y.makeLiveRegion('polite');
      KX_A11Y.liveAssertive = KX_A11Y.makeLiveRegion('assertive');
      document.body.appendChild(KX_A11Y.livePolite);
      document.body.appendChild(KX_A11Y.liveAssertive);

      document.addEventListener('keydown', function (e) { KX_A11Y.onKeyEvent(1, e); }, true);
      document.addEventListener('keyup', function (e) { KX_A11Y.onKeyEvent(0, e); }, true);
    },

    makeLiveRegion: function (politeness) {
      var el = document.createElement('div');
      el.setAttribute('aria-live', politeness);
      el.setAttribute('aria-atomic', 'true');
      el.setAttribute('data-kx-live', politeness);
      el.style.position = 'absolute';
      el.style.width = '1px';
      el.style.height = '1px';
      el.style.margin = '-1px';
      el.style.overflow = 'hidden';
      el.style.clip = 'rect(0 0 0 0)';
      el.style.clipPath = 'inset(50%)';
      el.style.whiteSpace = 'nowrap';
      return el;
    },

    decode: function (ptr, len) {
      return new TextDecoder('utf-8').decode(HEAPU8.subarray(ptr, ptr + len));
    },

    dumpTree: function () {
      if (!KX_A11Y.rootNodeTried) {
        KX_A11Y.rootNodeTried = true;
        if (typeof Module !== 'undefined' && typeof Module._kx_a11y_root_node === 'function') {
          KX_A11Y.rootNodePtr = ccall('kx_a11y_root_node', 'number', [], []);
        } else if (!KX_A11Y.warnedNoRoot) {
          KX_A11Y.warnedNoRoot = true;
          console.warn('kx_a11y: no root node export — semantic tree mirror disabled');
        }
      }
      if (!KX_A11Y.rootNodePtr) return null;
      var ptr = ccall('kx_a11y_dump_tree', 'number', ['number'], [KX_A11Y.rootNodePtr]);
      if (!ptr) return null;
      var len = 0;
      while (HEAPU8[ptr + len] !== 0) len++;
      var text = KX_A11Y.decode(ptr, len);
      ccall('kx_a11y_free_string', null, ['number'], [ptr]);
      return text;
    },

    rebuild: function (dump) {
      var root = KX_A11Y.rootEl;
      while (root.firstChild) root.removeChild(root.firstChild);
      var nodes = [];
      var stack = [];
      KX_A11Y.ptrToIndex = {};
      var lines = dump.split('\n');
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (!line) continue;
        var parts = line.split('|');
        // depth|role|label|value|focusable|ptr|checked|x|y|w|h
        if (parts.length < 7) continue;
        var depth = parseInt(parts[0], 10);
        if (isNaN(depth)) continue;
        var role = parts[1];
        var ptr = parseInt(parts[5], 10);
        var checked = parseInt(parts[6], 10);
        var el = KX_A11Y.buildElement(role, parts[2], parts[3], parts[4] === '1', checked);
        while (stack.length > depth) stack.pop();
        var parent = stack.length > 0 ? stack[stack.length - 1] : root;
        parent.appendChild(el);
        stack.push(el);
        el.setAttribute('data-kx-index', String(nodes.length));
        nodes.push({ el: el, role: role, ptr: ptr });
        KX_A11Y.ptrToIndex[ptr] = nodes.length - 1;
      }
      KX_A11Y.nodes = nodes;
      if (KX_A11Y.focusedIndex >= 0 && KX_A11Y.focusedIndex < nodes.length) {
        try { nodes[KX_A11Y.focusedIndex].el.focus({ preventScroll: true }); } catch (e) {}
      }
    },

    ariaRole: function (role) {
      switch (role) {
        case 'heading': return 'heading';
        case 'button': return 'button';
        case 'link': return 'link';
        case 'image': return 'img';
        case 'text_field': return 'textbox';
        case 'toggle': return 'switch';
        case 'checkbox': return 'checkbox';
        case 'radio': return 'radio';
        case 'slider': return 'slider';
        case 'progress': return 'progressbar';
        case 'scrollbar': return 'scrollbar';
        case 'list': return 'list';
        case 'list_item': return 'listitem';
        case 'dialog': return 'dialog';
        case 'alert': return 'alert';
        case 'menu': return 'menu';
        case 'menu_item': return 'menuitem';
        case 'tab': return 'tab';
        case 'group': return 'group';
        default: return null;
      }
    },

    buildElement: function (role, label, value, focusable, checked) {
      var el = document.createElement('div');
      el.setAttribute('data-kx-role', role);
      var aria = KX_A11Y.ariaRole(role);
      if (aria) el.setAttribute('role', aria);
      if (role === 'text' || role === 'none') {
        el.textContent = label;
      } else if (label) {
        el.setAttribute('aria-label', label);
      }
      if (role === 'slider' || role === 'progress' || role === 'scrollbar') {
        var n = parseFloat(value);
        if (!isNaN(n)) el.setAttribute('aria-valuenow', String(n));
      } else if (role === 'text_field') {
        el.textContent = value;
      }
      // checked: 0 = null, 1 = false, 2 = true (only tri-state roles use it).
      if (role === 'toggle' || role === 'checkbox' || role === 'radio') {
        if (checked === 2) el.setAttribute('aria-checked', 'true');
        else if (checked === 1) el.setAttribute('aria-checked', 'false');
      }
      if (focusable) {
        el.setAttribute('tabindex', '0');
        el.setAttribute('data-kx-a11y', '1');
      }
      return el;
    },

    dispatch: function (kind, nodeId, textPtr, textLen, region) {
      KX_A11Y.initDom();
      if (!KX_A11Y.rootEl) return;
      switch (kind) {
        case 0: {
          var dump = KX_A11Y.dumpTree();
          if (dump !== null) KX_A11Y.rebuild(dump);
          break;
        }
        case 1: {
          // nodeId is a Node pointer, not a dump index — resolve via ptrToIndex.
          var idx = KX_A11Y.ptrToIndex[nodeId];
          if (idx !== undefined && idx >= 0 && idx < KX_A11Y.nodes.length) {
            KX_A11Y.focusedIndex = idx;
            try { KX_A11Y.nodes[idx].el.focus({ preventScroll: true }); } catch (e) {}
          }
          break;
        }
        case 2: {
          if (textLen > 0 && textPtr) {
            var live = region === 2 ? KX_A11Y.liveAssertive : KX_A11Y.livePolite;
            if (live) {
              live.textContent = '';
              live.textContent = KX_A11Y.decode(textPtr, textLen);
            }
          }
          break;
        }
        case 3: {
          // control_changed: a toggle/slider value flipped — re-dump so the
          // mirrored ARIA values (aria-checked, aria-valuenow, ...) refresh.
          var dump = KX_A11Y.dumpTree();
          if (dump !== null) KX_A11Y.rebuild(dump);
          break;
        }
      }
    },

    onKeyEvent: function (down, ev) {
      var t = ev.target;
      var fromCanvas = !!(t && t.id === 'canvas');
      var fromMirror = !!(t && t.getAttribute && t.getAttribute('data-kx-a11y') === '1');
      if (!fromCanvas && !fromMirror) return;
      var key = KX_A11Y.domKeyToSdl(ev);
      if (key === 0) return;
      var mod = 0;
      if (ev.shiftKey) mod |= 0x0001;
      if (ev.ctrlKey) mod |= 0x0040;
      if (ev.altKey) mod |= 0x0100;
      if (ev.metaKey) mod |= 0x0400;
      switch (ev.key) {
        case 'Tab': case ' ': case 'Spacebar':
        case 'ArrowLeft': case 'ArrowRight': case 'ArrowUp': case 'ArrowDown':
        case 'Home': case 'End': case 'PageUp': case 'PageDown':
          ev.preventDefault();
          break;
      }
      ccall('kx_a11y_key', null, ['number', 'number', 'number'], [down ? 1 : 0, key, mod]);
    },

    domKeyToSdl: function (ev) {
      switch (ev.key) {
        case 'Enter': return 13;
        case 'Escape': return 27;
        case 'Backspace': return 8;
        case 'Tab': return 9;
        case ' ': case 'Spacebar': return 32;
        case 'Delete': return 0x7F;
        case 'ArrowRight': return 0x4000004F;
        case 'ArrowLeft': return 0x40000050;
        case 'ArrowDown': return 0x40000051;
        case 'ArrowUp': return 0x40000052;
        case 'Home': return 0x4000004A;
        case 'PageUp': return 0x4000004B;
        case 'End': return 0x4000004D;
        case 'PageDown': return 0x4000004E;
      }
      if (ev.key && ev.key.length === 1) {
        var c = ev.key.charCodeAt(0);
        if (c >= 65 && c <= 90) c += 32;
        return c;
      }
      return 0;
    },
  },

  kx_a11y_event__sig: 'vijiii',
  kx_a11y_event__deps: ['$KX_A11Y'],
  kx_a11y_event: function (kind, nodeId, textPtr, textLen, region) {
    if (typeof nodeId !== 'bigint' && arguments.length === 6) {
      region = arguments[5];
      textLen = arguments[4];
      textPtr = arguments[3];
      nodeId = arguments[1] + arguments[2] * 4294967296;
    }
    KX_A11Y.dispatch(kind | 0, Number(nodeId), textPtr | 0, textLen | 0, region | 0);
  },

  kx_js_a11y_event__sig: 'vijiii',
  kx_js_a11y_event__deps: ['$KX_A11Y', 'kx_a11y_event'],
  kx_js_a11y_event: function () {
    return kx_a11y_event.apply(null, arguments);
  },

  kx_a11y_set_root__sig: 'vi',
  kx_a11y_set_root__deps: ['$KX_A11Y'],
  kx_a11y_set_root: function (ptr) {
    KX_A11Y.rootNodePtr = ptr | 0;
    KX_A11Y.rootNodeTried = true;
  },
});
