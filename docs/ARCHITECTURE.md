# Klaxon — Architecture

> Klaxon is a cross-platform UI framework written in Zig, targeting desktop, mobile, and web (WASM). It aims to compete with Flutter and Qt on performance, binary size, and developer experience — with a modern renderer (Skia Graphite) and a compile-time DSL unique to Zig.

## Vision

- **Framework first.** Klaxon is a reusable framework. The Vehicoule app is a consumer, not the product.
- **Contribute to the Zig ecosystem.** No viable UI framework exists for Zig today. Klaxon fills that gap.
- **Own the stack.** Zig + C + C++ only. No Rust, no runtime, no GC.
- **Performance is contractual.** Every module is born with a budget. A perf regression is a red build.
- **v1 means everything.** All platforms, 50 widgets, full testing, DevTools, packaging. No V1/V2 split.

## Stack

| Layer | Technology | Why |
|---|---|---|
| **Language** | Zig 0.17 (pinned) | C interop, no runtime, static binaries, fast compile, comptime DSL |
| **Renderer** | Skia (Graphite primary + Ganesh fallback + raster last resort) | Industry-proven 2D renderer (Chrome, Flutter, Android). Graphite = Vulkan/Metal/Dawn/WebGPU. |
| **Platform** | SDL3 | Windows, input, audio device, mobile lifecycle, IME. Proven cross-platform. |
| **WASM runtime** | WAMR 2.4.4 fast-interp | C runtime, no JIT (iOS-compatible), fuel metering, Linux Foundation. For the app's plugins, not the framework. |
| **C++ shim** | `kx_skia/` (inside the framework) | Bridge between Zig and Skia C++. Required because Skia is C++ and has no C API for Graphite. |
| **Build** | `zig build` | Single entry point. Cross-compiles to all targets natively. Split by ABI for smallest binaries. |
| **CLI** | `klaxon` (Zig binary) | `create`, `run`, `build`, `test`, `bench`, `package`, `doctor`, `gallery` |

**Policy: no Rust.** All owned code is Zig, C, or C++. This eliminates Wasmi, AccessKit, tiny-skia, and forces WAMR + a custom a11y layer. The trade-off is more code to maintain, but full ownership of the stack.

## Architecture layers

```
┌─────────────────────────────────────────────────────┐
│  App (Vehicule, gallery, user apps)                 │
├─────────────────────────────────────────────────────┤
│  Widgets (Button, Text, ListView, Dialog, ...)       │  ← klaxon/src/widgets/
├─────────────────────────────────────────────────────┤
│  UI core (Node tree, layout, input, gestures, anim, state) │  ← klaxon/src/ui/
├─────────────────────────────────────────────────────┤
│  Platform (host, events, lifecycle, integration)    │  ← klaxon/src/host.zig, klaxon/src/platform/
├─────────────────────────────────────────────────────┤
│  Bindings (kx → Skia ABI, sdl → SDL3 ABI)           │  ← klaxon/src/kx.zig, klaxon/src/sdl.zig
├─────────────────────────────────────────────────────┤
│  C++ shim (Skia Graphite/Ganesh/raster)             │  ← klaxon/kx_skia/
├─────────────────────────────────────────────────────┤
│  Skia + SDL3 + system GPU drivers                   │  ← deps/ (built by fetch-deps.sh)
└─────────────────────────────────────────────────────┘
```

## Modules

### `kx.zig` — Skia ABI bindings

Pure Zig `extern fn` declarations against `kx_skia.h`. Opaque handles (`kx_ctx`, `kx_target`, `kx_paint`, `kx_para`, `kx_path`, `kx_image`). No C++ types leak into Zig. Backend enum aligned with the C header.

### `sdl.zig` — SDL3 ABI bindings

Zig bindings for SDL3: window, events, input, audio device, clipboard, haptics, system theme. Constants verified against SDL3 3.2.16 headers.

### `host.zig` — Platform layer

Window lifecycle, event loop (dirty-flag, 0-frame idle), GL/Vulkan/Metal/Dawn onscreen targets, lifecycle events (pause/resume/low-memory), RSS ledger, stats (fps, frame time, TTFF). Backend selection: static map platform→backend, never probing.

### `ui/` — UI core

| Module | Responsibility |
|---|---|
| `node.zig` | Retained widget tree: `Node`, `Rect`, hit-test, dirty flags, draw |
| `layout.zig` | Two-pass layout (measure → layout). Flex (Row/Column), Stack, Grid, Custom |
| `paint.zig` | Paint (color, gradient, blur, stroke, blend), Path, Image wrappers over `kx_*` |
| `gestures.zig` | GestureArena + recognizers: tap, double-tap, long-press, pan, swipe/fling, pinch, rotate |
| `anim.zig` | Animation primitives: Spring (M3E physics), Tween (curves), staggered, hero transitions. SIMD `@Vector` for multi-property interpolation |
| `state.zig` | Fine-grained reactivity: `Signal(T)`, `Memo(T)`, `Effect`. SolidJS-style dependency tracking |
| `input.zig` | Input router: pointer/keyboard dispatch, capture (drags), hover, focus, popup barrier |
| `navigator.zig` | Navigator 2.0 style: declarative page stack, push/pop/replace, transitions, deep links |
| `semantics.zig` | Accessibility semantic tree (role, label, hint, actions, focus) |
| `i18n.zig` | Internationalization: `tr(key)`, ARB locale files, RTL auto, pluralization, ICU date/number |
| `theme.zig` | Design tokens (colors, typography, spacing, radius, elevation, motion). V2 (not v1 priority) |
| `lazy_list.zig` | Virtualized list (only visible items materialized) |
| `text_field.zig` | TextField + IME state machine (compose, commit, caret, selection) |
| `focus.zig` | Keyboard focus navigation (Tab, arrows, focus ring) |
| `scroll.zig` | Scroll container (offset, inertia, drag, ensureVisible) |

### `widgets/` — Widget library (50 widgets for v1)

Each widget: designed API, unit tested, golden tested, documented (English doc comments), themable.

Categories:
- **Layout** (8): Row, Column, Stack, Grid, Padding, Center, Align, ConstrainedBox
- **Basics** (6): Text, RichText, Icon, Image, Container, Divider
- **Input** (8): Button, Toggle, Checkbox, Radio, Slider, TextField, Dropdown, Chip
- **Scroll** (4): ListView, GridView, ScrollView, Scrollbar
- **Navigation** (6): AppBar, NavBar, Drawer, Tabs, BottomSheet, Dialog
- **Feedback** (4): ProgressIndicator (linear/circular), Badge, Tooltip, SnackBar
- **Media** (2): Video (GPU zero-copy texture, 120 fps-gated scene), Audio (player controls)
- **Advanced** (12): Table, Tree, Calendar, DatePicker, ColorPicker, Avatar, Card, ExpansionPanel, Stepper, SegmentedControl, SearchBar, Menu

### `platform/` — Platform integration (14 services)

| Service | API | Status |
|---|---|---|
| Clipboard | `platform.clipboard.get/set(text)` | v1 |
| File picker | `platform.picker.openFile/saveFile()` | v1 |
| Share sheet | `platform.share(text/url)` | v1 |
| URL launcher | `platform.openUrl(url)` | v1 |
| Notifications | `platform.notify(title, body)` | v1 |
| Haptics | `platform.haptic(light/medium/heavy)` | v1 |
| System theme | `platform.theme.dark/light` | v1 |
| Safe areas | `platform.safeArea.top/bottom/left/right` | v1 |
| Keyboard insets | `platform.keyboard.height` | v1 |
| Sensors | `platform.sensor.accel/gyro` | V2 |
| Camera | `platform.camera.capture()` | V2 |
| Bluetooth | `platform.bluetooth.*` | V2 |
| WASM plugins | `runtime.PluginRuntime` (abstract) | App-level, not framework |
| Process / env | `platform.env.get/set`, `platform.process.exit` | v1 |

Each service: Zig interface in `klaxon/src/platform/` + native implementation per platform.

### `kx_skia/` — C++ shim (inside the framework)

```
kx_skia/
├── include/kx_skia.h           ← C ABI (103 lines, stable contract)
└── src/
    ├── kx_skia_common.cpp      ← Shared: KxFontMgr, contexts, surfaces, readback, paint, para, image, path
    ├── kx_skia_platform.h      ← Platform interface: create_gpu_ctx(), create_onscreen_surface(), swapchain
    ├── kx_skia_macos.mm        ← macOS impl (Metal + raster) — built first (Phase 0), arm64 only, no x64
    ├── kx_skia_linux.cpp       ← Linux impl (EGL + Vulkan) — Phase 3a
    ├── kx_skia_android.cpp     ← Android impl (GLES + Vulkan)
    ├── kx_skia_win.cpp         ← Windows impl (Dawn D3D12 + Vulkan + GL)
    ├── kx_skia_ios.mm          ← iOS impl (Metal)
    ├── kx_skia_wasm.cpp        ← WASM impl (WebGL2/WebGPU via emscripten)
    ├── kx_draw.cpp             ← Drawing API (common, ~40 fns + v2 extensions)
    ├── kx_scenes.cpp           ← Canonical benchmark scenes (common)
    └── kx_a11y_*.cpp           ← A11y bridges per platform
```

**Rule**: no C++ type crosses the ABI. Zig sees only opaque handles and C functions.

## Widget tree — retained with dirty flags

**Decision (ADR-0004): retained tree, not immutable.**

Zig has no GC. An immutable tree (Flutter-style) would recreate hundreds of widgets per frame = allocations = jank. The retained tree with dirty flags enables a **zero-alloc frame loop**.

```zig
pub const Node = struct {
    // identity (persists across frames)
    parent: ?*Node,
    children: std.ArrayList(*Node),

    // mutable state
    bounds: Rect,
    dirty: bool,           // needs redraw?
    layout_dirty: bool,    // needs relayout?

    // content
    paint: Paint,
    semantics: Semantics,
    on_event: ?EventHandler,
    gesture: ?GestureHandler,
    userdata: ?*anyopaque,  // widget state (Button.onPress, etc.)

    pub fn markDirty(n: *Node) void {
        n.dirty = true;
        if (n.parent) |p| p.markDirty();  // propagate up
    }
};
```

**Frame loop**: walk the tree, draw only dirty subtrees, clear dirty flags.

## State management — fine-grained reactivity (signals)

**Decision: SolidJS-style signals, built complete from day one.**

```zig
// Signal — observable value
pub fn Signal(T: type) type {
    return struct {
        value: T,
        version: u64 = 0,
        subscribers: std.ArrayList(*ui.Node),

        pub fn get(self: *@This()) T {
            // Track dependency: the widget currently building subscribes
            if (ui.current_builder) |node| {
                self.subscribers.append(node);
            }
            return self.value;
        }

        pub fn set(self: *@This(), v: T) void {
            self.value = v;
            self.version += 1;
            for (self.subscribers.items) |node| node.markDirty();
        }
    };
}

// Memo — derived value, recomputed when dependencies change
pub fn Memo(T: type, comptime compute: fn () T) type { ... }

// Effect — side effect, runs when dependencies change
pub fn Effect(comptime effect: fn () void) type { ... }
```

**Usage in a widget:**

```zig
const Counter = struct {
    count: State.Signal(i32) = .init(0),

    fn build(self: *Counter) ui.Node {
        // Reading count.get() subscribes this widget to count changes
        return Column(.{}, .{
            Text(self.count.get()),
            Button(.{ .label = "+", .onPress = self.increment }),
        });
    }

    fn increment(self: *Counter) void {
        self.count.set(self.count.get() + 1);  // only this widget rebuilds
    }
};
```

**Why not BLoC/Riverpod for v1**: signals give fine-grained reactivity with zero boilerplate. When cross-screen shared state is needed, `Store<T>` (a global signal registry) is added. No architecture rewrite later.

## Layout engine — two-pass

```
Pass 1 — measure (top-down):
  Parent gives constraints (min/max width/height) to children
  Children respond with desired size

Pass 2 — layout (bottom-up):
  Parent computes bounds for each child
  Children position themselves within those bounds
```

Strategies: Flex (Row/Column with weights, gap, padding), Stack (Z-order superposition), Grid (N×M with spans), Custom (user-defined measure/layout callbacks).

Layout runs only when `layout_dirty`. No relayout per frame.

## Renderer — backend selection

Static map platform→backend. **Never probing** (creators crash instead of returning NULL — measured).

| Platform | Primary | Fallback | Last resort |
|---|---|---|---|
| macOS (arm64) | graphite-metal | raster | — |
| iOS (arm64) | graphite-metal | raster | — |
| Android ≥ API 33 | graphite-vulkan | ganesh-gles | raster |
| Android < API 33 | ganesh-gles | raster | — |
| Linux x64/arm64 | graphite-vulkan | ganesh-gl | raster |
| Windows x64 | graphite-dawn-d3d12 | dawn-vulkan → ganesh-gl | raster |
| Web (WASM) | graphite-webgpu | ganesh-webgl2 | raster |

**No macOS x64.** Apple Silicon only.

**Renderer discipline (GPU rules)** — adopted from SDL_gpu's performance guidance. SDL_GPU stays **off** (Skia Graphite is the GPU layer), but the principles are the contract for our renderer:

1. **Few render passes.** One render pass per frame where possible; batch everything into a single Skia display list.
2. **Minimal state changes.** Sort/batch draw calls by paint state; a pipeline bind is cheap, hundreds per frame is not.
3. **Upload early.** Vertex/uniform/texture uploads at frame start, never mid-pass.
4. **No resource churn.** Textures, atlases, buffers are created up front and cached (pool allocators). Creating/releasing per frame is a bug.
5. **No large per-frame buffers.** Small uniforms only; big data goes through cached storage.
6. **Cycle correctly.** Frame-in-flight management (vsync-aligned pacing, no driver stalls).
7. **Cull.** Dirty-rect + viewport culling: redraw only what moved and what is visible. Virtualized lists materialize only visible items.
8. **Don't Touch The Driver.** The golden rule: doing things is more expensive than not doing things. Fewer draw calls, fewer flushes, fewer presents.

## Animation system — 3 layers

```
Layer 1 — Primitives (CPU, SIMD):
  Spring(stiffness, damping, mass) → M3E physics
  Tween(curve, duration) → driven interpolation
  @Vector(4, f32) → 4 properties interpolated in one instruction

Layer 2 — Scheduling (CPU):
  Timeline: list of active animations
  Tick at 240 Hz fixed → step(dt) → value
  Staggered: per-child delay
  Hero: shared element between routes

Layer 3 — GPU effects (Skia shaders):
  Animated blur, gradient, ripple → shaders
  CPU sends uniforms (t), GPU does pixel work
```

**Anti-jank**: dirty-rect (redraw only moving regions), frame budget (skip lowest-priority anim if frame > 8.3ms), vsync-aligned pacing.

## Gesture system — GestureArena

Pointer events (SDL3, multi-touch) → GestureArena → recognizers → callbacks.

The arena arbitrates conflicts: multiple recognizers competing for the same pointer — first to "claim" wins.

| Recognizer | Trigger |
|---|---|
| Tap | down + up within slop (12dp) and < 200ms |
| DoubleTap | 2 taps < 300ms apart |
| LongPress | down > 500ms without move |
| Pan | move > slop → drag |
| Swipe/Fling | pan + velocity > 500dp/s at release |
| Pinch | 2 pointers → scale = current distance / initial |
| Rotate | 2 pointers → angle = atan2 delta |

## Build system

```bash
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # release (smallest binary)
zig build run                      # build + run
zig build test                     # unit + widget tests
zig build test-golden              # golden tests (readback + diff)
zig build bench                    # run benchmarks
zig build -Dtarget=android         # cross-compile Android (split ABI: arm64, x64)
zig build -Dtarget=ios             # cross-compile iOS (arm64 only)
zig build -Dtarget=wasm            # cross-compile WASM
zig build package                  # package for current platform
zig build package-all              # package for all platforms (CI)
```

**Split by ABI**: each architecture produces a separate binary/APK. arm64 and x64 are never bundled together. Smallest possible binaries.

## Testing — 4 levels

| Level | What | How | Command |
|---|---|---|---|
| **Unit** | Pure functions (layout math, spring, gesture thresholds) | `std.testing` | `zig build test` |
| **Widget** | A widget without a window (layout, hit-test, state) | Instantiate `ui.Node`, call `layout()`, assert bounds | `zig build test` |
| **Golden** | Visual render → screenshot → diff | `kx_readback` (offscreen) → PNG → diff at 1% tolerance | `zig build test-golden` |
| **Integration** | Full app on device/simulator | `gates/device.sh` → install → run scenes → check metrics | `gates/device.sh` |

**Device matrix** (integration tests + device-tier perf gates):

| Target | Location | Access |
|---|---|---|
| macOS arm64 (dev host) | local | `zig build run` — dev loop, goldens (raster), gates (Metal) |
| iOS Simulator | local (dev Mac) | `xcrun simctl` + `gates/device.sh ios-sim` |
| Android Emulator | local (dev Mac) | `emulator` + `adb` + `gates/device.sh android-emu` |
| Android phone (retail, Adreno 750) | USB, when available | `adb` + `gates/device.sh android-device` — reference device for gates |
| Linux x64 machine | remote (ssh) | `gates/device.sh ssh-linux` |
| Windows x64 machine | remote (ssh) | `gates/device.sh ssh-windows` |
| CI runners (GitHub Actions) | cloud | Linux/Windows/macOS build+test, Android emulator, headless goldens (raster) |

**Cross-framework conformance** (Phase 4c.7): no cross-framework UI conformance suite exists today (WPT is web-only; Appium/Espresso/XCUITest are per-platform E2E). Klaxon publishes a behavioral conformance spec + a runner that scores any UI framework (Klaxon, Flutter, Qt, Compose) against it — the WPT ambition for UI frameworks.

Goldens: one per widget × per backend. Stored in `tests/golden/expected/`. Diff > tolerance = red build.

## DevTools

Activated by F12 (desktop) or 3-finger tap (mobile) or `--devtools` flag.

- **Overlay**: FPS graph (60s rolling), frame time (CPU/GPU), draw calls, RSS (idle/peak), allocs/frame, backend + driver
- **Inspector**: interactive widget tree, click to see properties (bounds, paint, semantics), hover highlights bounds
- **Memory ledger**: RSS graph per subsystem (renderer, fonts, images, UI, WASM)
- **Frame timeline**: where time goes (layout, record, submit, present)

## Memory discipline

No GC. Typed allocators:

| Allocator | Use |
|---|---|
| Arena (per frame) | Freed at present. Zero alloc in steady-state. |
| Pool (per subsystem) | Reused objects (textures, display lists, glyphs). |
| GPA (debug) | Detects leaks, double-free, use-after-free. |
| General | Init, config (never in hot path). |

C/C++ is contained in `kx_skia/` (the shim). No C++ type crosses the ABI. Skia manages its own memory (ref-counted, internal pools).

**Rule**: no `new`/`malloc` in Zig hot-path code. A frame that allocates is a bug.

## Packaging matrix

| Platform | Format | Arch | Priority |
|---|---|---|---|
| Linux | AppImage, .deb, .rpm, Flatpak | x64, arm64 | v1 |
| Windows | .exe (portable), .msi | x64 | v1 |
| macOS | .app, .dmg | arm64 only | v1 |
| Android | .apk (sideload), .aab (Play) | arm64, x64 (split) | v1 |
| iOS | .ipa (TestFlight) | arm64 | v1 |
| Web | .wasm + .html + .js | wasm32 | v1 |
| FreeBSD | pkg | x64, arm64 | V2 |
| Snap | .snap | x64 | V2 |
| HarmonyOS | .hap | arm64 | V2 |

## Repos

```
github.com/Vehicoule/
├── klaxon              ← The framework (this project)
├── vehicule            ← The app (consumer of klaxon, WASM plugins)
├── klaxon-plugin-sdk   ← Plugin SDK (independent semver, WASM contract)
└── klaxon-spikes        ← Experiments (archive, recipes, measurements)
```

## What Klaxon is NOT

- Not a toy. Competes with Flutter/Qt on performance, binary size, dev experience.
- Not a runtime-heavy framework. No GC, no VM, static binaries.
- Not a package registry (v1). Dependencies are normal `build.zig.zon` entries (Qt-style).
- No hot reload in v1 (V2). Static binaries make it low-ROI.
- No macOS x64. Apple Silicon only.
