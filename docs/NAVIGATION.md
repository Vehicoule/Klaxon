# Navigation — deep-dive (Phase 2a)

> Page stack, transitions, hero (shared element) flights, deep links, back.
> Competes with Flutter's Navigator 2.0 + go_router and Qt's QStackedWidget
> + QML StackView — with the whole stack in Zig, no GC, no runtime.

## Architecture

```
ui/navigator.zig      Navigator — the page stack (UI-agnostic logic)
                      Route patterns, params, deep links, back stack
widgets/navigator.zig NavigatorView — renders the stack, drives transitions
                      Hero — shared element (the flight is driven by the view)
ui/input.zig          BackHandler — the router's back callback (Phase 2a)
host.zig              SDL Escape / AC_BACK → router.dispatchBack()
```

Two layers, one rule: **the Navigator never owns page nodes.** The builder
returns the page's root node; the NavigatorView parents it in a transform
wrapper and the tree owns its lifetime. A popped page is destroyed when its
transition completes (or immediately on an interrupted transition).

## The stack (`ui/navigator.zig`)

```zig
var nav = Navigator.init(allocator);
try nav.define("home", .{ .fn_ptr = homePage, .userdata = &app }, .none);
try nav.define("anime/{id}", .{ .fn_ptr = animePage, .userdata = &app }, .slide);
try nav.push("home", &.{});
try nav.push("anime/{id}", &.{.{ .key = "id", .value = "42" }});
```

- **Patterns**: `"anime/{id}"` — `{name}` segments capture path params.
  Static segments must match exactly; the arity must match.
- **Params**: path captures first, then query params. Fixed inline storage
  (`MAX_PARAMS = 8`) — a hop allocates nothing per param. Strings are duped
  into the navigator and freed on pop/deinit.
- **Imperative API**: `push`, `pop`, `replace`, `popToRoot`, `canPop`,
  `current`, `onBack` (pop while deeper than the root; false at the root).
  The stack never empties (the root is the floor).
- **Deep links**: `nav.navigateTo("klaxon://anime/42?tab=2")` parses the
  URI (scheme optional), matches a route, pushes it. Navigating to the route
  already on top is a no-op. Called before the first frame, it sets the
  initial stack (cold start — no transition).
- **Change notifications**: `setOnChange` — the NavigatorView subscribes;
  every mutation (`push`/`pop`/`replace`/`reset`) notifies after the stack
  changed, and the view syncs the tree + starts the transition.
- **Page ids**: monotonic, unique — the view tracks wrappers by id (an
  interrupted transition keeps the exiting page in the tree when its page is
  still in the stack).

## Transitions (`widgets/navigator.zig`)

Every page is wrapped in a transform wrapper (translate + scale + alpha
layer — kx ABI 0.4.0 `kx_layer_alpha`). A mutation starts a tween on the
process-global Timeline:

| Transition | Choreography (push) | Pop (reverse) |
|---|---|---|
| `slide` | entering slides in from the right; the page below parallaxes left (0.3 × width) | the popped page slides out right; the page below comes back from the parallax offset |
| `slide_up` | same, vertical (sheets) | same, vertical |
| `fade` | entering cross-fades in (alpha 0 → 1) | the popped page fades out |
| `scale` | entering scales 0.92 → 1 + fades in (dialog-style) | the popped page scales down + fades out |
| `none` | instant swap | instant swap |

- Default: 300 ms, M3 standard curve (`cubic-bezier(0.2, 0, 0, 1)`).
  Budget: ≤ 350 ms (see PERF-BUDGETS.md).
- The exiting page stays in the tree until the transition completes, then
  leaves — unless an interrupted transition kept it in the stack (it snaps
  back into place).
- **Interrupted transitions**: a push during a push finishes the previous
  transition instantly (no stacking, no double-writes — the Timeline channel
  cancels the previous tween).
- **Hit-testing**: while a transition runs, only the top page is interactive
  (the others' wrappers are not hittable).
- **Damage**: the wrappers' transforms drive dirty-rects (the swept region
  old ∪ new is repainted — raster stays cheap during transitions).

## Hero — shared element flight

```zig
const h = try widgets.navigator.hero(allocator, .{ .tag = "cover" });
h.add(coverWidget);
```

Two pages containing a `Hero` with the **same tag**: on a transition, the
entering page's hero child "flies" from its source rect to its destination
rect:

1. The entering hero's child is reparented into a flight wrapper (topmost
   child of the NavigatorView). `Node.add` does not detach — the child is
   explicitly removed first (double-parenting is fatal, no GC).
2. The hero wrapper keeps the **destination size** (`flight_dst`) — a
   placeholder: the entering page does not reflow while the element flies.
3. The tween animates translate + non-uniform scale (pivot = the flight
   wrapper's top-left): position lerp(src → dst), size lerp(src → dst).
4. The source hero (same tag, exiting page) is hidden while the element
   flies.
5. On completion, the child is reparented back into the hero wrapper (at the
   destination rect) and the flight wrapper is destroyed.

Heroes register with the enclosing NavigatorView at layout time (the rect
is refreshed on resize). A hero outside a page never flies.

## Back

- The NavigatorView registers the input router's **back handler**
  (`router.setBackHandler`): `dispatchBack()` delivers the key to the focused
  chain first (a text field may consume it), then pops the stack.
- The host maps `SDLK_AC_BACK` (Android hardware button) and `SDLK_ESCAPE`
  (desktop) to `router.dispatchBack()`.
- The view's `on_key` also answers `.back`/`.escape` (focused-chain delivery
  bubbles up to it).
- At the root, `onBack()` returns false — the app may quit then.

## Cold start / deep link

`navigateTo` before the first frame sets the initial stack; the
NavigatorView wraps the initial pages without a transition. Deep links after
the first frame push normally (with transition).

## Testing

- `ui/navigator.zig`: 13 unit tests — push/pop/replace/popToRoot/onBack,
  pattern matching, URI parsing, deep links, cold start, change kinds, param
  ownership (leak-checked).
- `widgets/navigator.zig`: 8 unit tests — push/pop/replace/reset animations
  (manual Timeline ticks, linear curve), interrupted transitions, `none`,
  cold start, back handler (router), `on_key`, hit-testing during transitions,
  hero flight (placeholder, reparenting, source hidden).
- 3 golden tests — slide (entering covers from the right + parallax), fade
  (cross-fade at 50% = exact channel blend), hero (flies source → destination,
  lands at the destination rect).
- `navigator` demo app (`src/navigator_main.zig`): 5 routes, all transition
  kinds, hero, deep link via CLI arg (`klaxon://detail/42`). CI runs it
  headless (600 frames, scripted push/push/pop/push/popToRoot/push).

## P0 deviations / follow-ups

- **Swipe-back gesture** (iOS edge drag) is not in 2a — it needs a
  pan-recognizer-driven transition (the gesture arena exists since 1d).
  Natural follow-up; the transition driver already supports reverse +
  progress-driven interruption.
- **Per-route transition override on pop**: the pop uses the popped page's
  transition (its wrapper carries it) — correct for symmetric transitions;
  asymmetric ones (push slide, pop fade) would need a per-route pop
  transition field.
- **Nested navigators** (tabs with their own stacks): one NavigatorView per
  tab; the router's back handler is single (single-window P0) — nested
  back routing lands with multi-window.
- **Predictive back** (Android 14): needs the OS back-progress events —
  platform layer, not the Navigator.
- **Route guards / redirects** (auth): a `define` middleware
  (`beforePush` hook) — trivial addition when needed.
