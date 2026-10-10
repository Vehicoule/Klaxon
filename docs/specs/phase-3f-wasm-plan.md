# Phase 3f — Web (WASM) port — implementation plan

Status: PLAN (research-backed, not started). Stack: Emscripten + SDL3
(emscripten video driver) + Skia Ganesh **WebGL2**. Zig target:
`wasm32-emscripten`. Graphite/WebGPU is Phase 3g (out of scope).

Research base (verified against `deps/skia` @ 8643b1d, `deps/SDL` @
release-3.2.16, web sources in §10):

| Topic | Finding |
|---|---|
| Skia WASM | `target_cpu = "wasm"` implies `target_os = "wasm"` (gn/BUILDCONFIG.gn:51). GN wasm toolchain compiles with `emcc`/`em++` from `third_party/externals/emsdk` (`bin/activate-emsdk` pins emsdk 4.0.7); non-CanvasKit builds emit `lib<name>.wasm.a`. `skia_use_webgl`/`skia_use_webgpu` default to `is_wasm` (gn/skia.gni:101); `skia_enable_fontmgr_custom_embedded`/`_directory` default on with freetype. |
| Ganesh WebGL2 | `GrGLInterfaces::MakeWebGL()` (`include/gpu/ganesh/gl/GrGLMakeWebGLInterface.h`) binds GLES3 statically (no GetProcAddress). Onscreen (CanvasKit, canvaskit_bindings.cpp:288-320): `GrDirectContexts::MakeGL()`, per frame wrap FBO 0: `GrBackendRenderTargets::MakeGL(w,h,0,8,{.fFBOID=0,.fFormat=GR_GL_RGBA8})` + `SkSurfaces::WrapBackendRenderTarget(..., kBottomLeft_GrSurfaceOrigin, kRGBA_8888, sRGB)`. |
| SDL3 WASM | Official port (`src/video/emscripten/`, `docs/README-emscripten.md`); build with `emcmake`/`emmake`. `SDL_GL_CONTEXT_MAJOR_VERSION=3` → WebGL2 (SDL_emscriptenopengles.c:92). SDL main callbacks use `emscripten_set_main_loop(...,0,0)` = rAF. Present is implicit: the browser composites when the rAF callback returns. |
| Zig WASM | `wasm32-emscripten` exists in Zig 0.17 (musl libc). Zig cannot link an exe for it → build the app as a **static library**, compile C deps with the emscripten sysroot include path, link all with `emcc` (sokol-zig `emLinkStep` pattern). Constraints: single-threaded, no native FS (MEMFS), **LTO miscompiles wasm** (dvui report) → no LTO. |
| Event loop | The browser owns the main thread: `emscripten_set_main_loop_arg(cb, 0, 0)` runs `cb` per rAF. Never block — on emscripten `SDL_WaitEvent`/`SDL_Delay` busy-poll (SDL_events.c + SDL_systimer.c without Asyncify) → tab freeze. Use non-blocking `SDL_PollEvent` drains. |
| A11y | A canvas is invisible to assistive tech. Established pattern (Figma "synthetic DOM", Flutter web semantics): a **hidden DOM** mirroring the semantic tree with ARIA roles/labels, linked to the canvas (`aria-owns`), mirrored focus, `aria-live` announcements. Klaxon already has the semantic tree + bridge events + `kx_a11y_dump_tree` — the wasm bridge reuses them verbatim. |

## 1. Architecture

```
Zig app (src/*_main.zig)
  │  zig build-lib -target wasm32-emscripten   (static lib, no link_libc)
  ▼
lib<app>.a ─┐
kx_skia shim │  kx_skia_common.cpp + kx_skia_wasm.cpp  (zig cc + emscripten sysroot)
libSDL3.a ──┤
Skia        ├─► emcc ─► zig-out/web/<app>.html + .js + .wasm
libskia… ───┘        (--shell-file web/shell.html --js-library web/kx_a11y.js)
```

| Path | Action | Purpose |
|---|---|---|
| `kx_skia/src/kx_skia_wasm.cpp` | create | Platform impl of `kx_skia_platform.h`: Ganesh WebGL2 onscreen, embedded font mgr (`kx_font_wasm.h`, generated default-font bytes) |
| `src/platform_wasm.zig` | create | Emscripten externs, rAF loop glue, wasm a11y bridge registration |
| `web/shell.html` + `web/kx_a11y.js` | create | `--shell-file` (canvas, a11y container, loader, CSS) + `--js-library` (hidden-DOM builder, focus/keyboard forwarding, aria-live) |
| `scripts/fetch-deps.sh` | modify | Add `web-wasm` tag: emsdk install, Skia wasm args.gn + build, SDL3 emcmake build |
| `build.zig` | modify | `wasm32-emscripten` target: shim sources/flags, static-lib + emcc link step (`web`) |
| `src/host.zig` | modify | Extract non-blocking `runIteration`; gate blocking waits + `SDL_Delay` pacing; wasm a11y init |
| `src/main.zig` (+ `gallery_main.zig`, …) | modify | Default backend `ganesh-webgl2` (raster fallback); `runWasm` on emscripten |
| `src/kx.zig`, `.github/workflows/ci.yml` | modify | wasm a11y entry points for JS; add `build-wasm` job (Linux) |

`kx_skia/include/kx_skia.h` needs **no change**: `KX_BACKEND_GANESH_WEBGL2 = 7`
already exists in ABI v0.10.0.

## 2. Build system

**One emsdk, one version.** `fetch-deps.sh` installs emsdk (pinned to Skia's
`bin/activate-emsdk` version, 4.0.7) into `deps/emsdk`; the Skia args.gn sets
`skia_emsdk_dir` to it (overriding the `third_party/externals/emsdk` default),
and the final `emcc` link uses `deps/emsdk/upstream/emscripten/emcc` — a
version mismatch between Skia objects and the app link is the #1 wasm failure
mode.

- **Skia** (`deps/skia/out/web-wasm/args.gn`): `target_cpu = "wasm"`, `is_official_build = true`, `skia_enable_ganesh = true`, `skia_enable_graphite = false` (3g), `skia_use_webgpu = false` (avoids Dawn), `skia_use_vulkan/metal/direct3d/x11/egl/dawn = false`, `skia_use_freetype/harfbuzz/icu/libpng/zlib = true` (same externals as native), `skia_enable_skparagraph/skshaper = true`, `skia_enable_fontmgr_custom_embedded/_directory = true`, `extra_cflags = ["-Wno-error"]`. Then `python3 bin/activate-emsdk`, `./bin/gn gen out/web-wasm`, `ninja -C out/web-wasm skia modules/skparagraph:skparagraph modules/skshaper:skshaper` → `lib*.wasm.a`.
- **SDL3**: `emcmake cmake -S deps/SDL -B deps/SDL/build-web-wasm` with the same trimmed options as native (`SDL_SHARED=OFF SDL_STATIC=ON`, camera/sensor/GPU off) + `-DSDL_PTHREADS=OFF`; `emmake make` → `libSDL3.a`.
- **Zig** (`zig build -Dtarget=wasm32-emscripten web`):
  - app module → `b.addLibrary` (static, **no `link_libc`** — emcc links musl);
  - shim: `kx_skia_common.cpp` + `kx_skia_wasm.cpp`, flags `-std=c++20 -fno-exceptions -fno-rtti -DSK_GANESH -DSK_GL -DSK_FORCE_8_BYTE_ALIGNMENT`
    + emsdk sysroot include path (`upstream/emscripten/cache/sysroot/include`) for `<emscripten.h>`, `<GLES3/gl32.h>`, musl headers;
  - `addTranslateC` for `sdl_c.h` / `kx_skia.h` with the emscripten target + sysroot include path;
  - emcc link run step: `emcc lib<app>.a libkx_skia.a libSDL3.a <skia .wasm.a…> -o zig-out/web/<app>.html --shell-file web/shell.html --js-library web/kx_a11y.js -sUSE_WEBGL2=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB -sENVIRONMENT=web -sSTACK_SIZE=1MB -sEXPORTED_FUNCTIONS=_main,_kx_a11y_dump_tree,_kx_a11y_free_string,_kx_a11y_key -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,FS -O3` (ReleaseSmall: `-Oz`). No pthreads, no Asyncify, **no LTO**, no closure (needs java; skip in CI).
- Native builds unchanged; `run`/`test`/`test-golden`/`package-macos` steps are skipped for the wasm target.

## 3. Event loop (rAF, canvas, input)

`main()` on emscripten: init host → build tree →
`emscripten_set_main_loop_arg(wasmFrameCallback, 0, 0)` (fps 0 = rAF/vsync).
The callback is one `host.runIteration()`:

1. drain pending SDL events with **non-blocking** `SDL_PollEvent` (SDL's emscripten backend fills the queue from JS handlers; no pump needed);
2. tick the animation timeline, run the app tick;
3. render **only when the tree is dirty** (idle = one cheap rAF tick, 0 GPU frames — the dirty-flag design survives the port);
4. return — the browser composites the WebGL drawing buffer.

- `host.zig` refactor: extract `runIteration()` (one pass) from `run()`; native keeps its blocking `SDL_WaitEvent` paths. On emscripten the blocking branches and `paceIteration` (`SDL_Delay`) are compiled out — rAF paces the loop.
- GL context: before `kx_create`, `SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)` + `SDL_GL_CreateContext(window)` + `SDL_GL_MakeCurrent` (WebGL2).
- Input mapping unchanged: SDL emscripten delivers mouse/touch/keyboard/text-input (IME)/wheel as the same SDL events `host.handleEvent` already maps.
- Resize: `SDL_EVENT_WINDOW_RESIZED` → `kx_resize` → shim recreates the backend render target. SDL handles CSS size vs backing store (DPR).
- Present: `kx_end_frame` → shim `flushAndSubmit()` + `SDL_GL_SwapWindow`. No `preserveDrawingBuffer` needed with a rAF-driven loop.

## 4. Backend Skia (Ganesh WebGL2)

`kx_skia_wasm.cpp` implements `kx_skia_platform.h`:

- `gpu_init`: require a current GL context (`SDL_GL_GetCurrentContext`); `GrGLInterfaces::MakeWebGL()` → `GrDirectContexts::MakeGL()` → `GpuState`.
- `gpu_begin_frame`: `glBindFramebuffer(GL_FRAMEBUFFER, 0)`; `dctx->resetContext(kRenderTarget_GrGLBackendState | kMisc_GrGLBackendState)`; `GrBackendRenderTargets::MakeGL(w, h, 0, 8, {.fFBOID=0, .fFormat=GR_GL_RGBA8})`; `SkSurfaces::WrapBackendRenderTarget(dctx, target, kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr)` → canvas.
- `gpu_end_frame`: `dctx->flushAndSubmit()`; `SDL_GL_SwapWindow(window)`.
- `gpu_resize`: store new size; target recreated on next `gpu_begin_frame`.
- `platform_font_mgr`: `SkFontMgr_New_Custom_Embedded` + `SkTypeface::MakeFromData` over the embedded default font (`kx_font_wasm.h`). (Later alternative: `--embed-file fonts/` + MEMFS + custom-directory mgr.)

`kx_skia_common.cpp` is untouched (backend-agnostic). `kx_readback_rgba` stays
raster-only. ABI v0.10.0 unchanged; `KX_BACKEND_GRAPHITE_WEBGPU = 6` lands in
Phase 3g (Dawn `emdawnwebgpu` port).

## 5. A11y (ARIA hidden DOM)

Reuse the existing semantic infrastructure — no Zig-side tree changes:

- `src/ui/semantics.zig` bridge events: `tree_dirty`, `focus_changed`, `announce`, `control_changed`; `src/a11y_bridge.zig` exports `kx_a11y_set_bridge`, `kx_a11y_dump_tree` (flat dump `depth|role|label|value|focusable|x|y|w|h`), `kx_a11y_free_string`.
- `src/platform_wasm.zig`: registers the bridge (`setBridgeC`) and forwards each event to JS via an extern `kx_js_a11y_event(...)` implemented in `web/kx_a11y.js` (a `--js-library` import — no EM_ASM string soup).
- `web/kx_a11y.js`:
  - **tree_dirty** → `ccall('kx_a11y_dump_tree')` → parse the flat dump → build a visually-hidden DOM (clip pattern: NOT `aria-hidden`) mirroring roles/labels/values (button→`button`, textfield→`textbox`, toggle→`switch`/`checkbox`, slider→`slider`, …) under `#kx-a11y-root`, linked to the canvas via `aria-owns`; canvas gets `role="img"` + `aria-label="Klaxon application"`.
  - **focus_changed** → move DOM focus (`tabindex=-1` + `.focus()`) to the mirrored node; `keydown`/`keyup` on it → exported `_kx_a11y_key(...)` → Zig pushes `SDL_EVENT_KEY_DOWN` via `SDL_PushEvent` → the existing `host.handleEvent` → focus manager path. Full keyboard a11y, no native widgets.
  - **announce** → write into an `aria-live="polite"|"assertive"` region (matches Klaxon `LiveRegion`); **control_changed** → update `aria-valuenow`/`aria-checked` in place.
  - Build eagerly (small tree; Flutter-style `ensureSemantics`) — also benefits text zoom/selection.

## 6. Packaging

`zig-out/web/`: `<app>.html` (custom shell), `<app>.js` (emscripten glue),
`<app>.wasm` (+ `.map` in debug). `web/shell.html`: `<canvas id="canvas"
tabindex="0">`, `#kx-a11y-root`, loading overlay, minimal CSS (full-viewport
canvas, `touch-action: none`). Serve over HTTP (wasm fetch needs it);
COOP/COEP **not** required (no pthreads). Size budget: gate in CI after the
first build (placeholder: `< 15 MB` ReleaseSmall; refine in 3f.8).

## 7. CI (Linux runner)

New `build-wasm` job on `ubuntu-latest` (native jobs untouched):

1. Zig 0.17.0 (existing install step), python3, ninja, cmake.
2. `scripts/fetch-deps.sh` (adds `web-wasm` components; extend the existing `deps` cache key with the wasm artifacts).
3. `zig build -Dtarget=wasm32-emscripten web`.
4. Size gate on `zig-out/web/hello.wasm`.
5. Smoke: `python3 -m http.server` + Playwright chromium — load page, assert no console errors, canvas non-blank (pixel sample), `#kx-a11y-root` populated.

## 8. Implementation order (incremental)

1. **Deps**: `fetch-deps.sh web-wasm` — emsdk, Skia `out/web-wasm` (`libskia.wasm.a`), SDL3 `build-web-wasm` (`libSDL3.a`). No Zig changes.
2. **Link plumbing**: build.zig wasm target with a stub `kx_skia_wasm.cpp` (`gpu_init` returns false) → `hello.html` links and runs; first milestone is the **raster** backend end-to-end (SDL's emscripten renderer is GLES2→WebGL), proving the whole zig-lib → emcc → browser pipeline.
3. **Event loop**: `runIteration` extraction + `platform_wasm.zig` rAF loop; verify args parsing and a 600-frame animation in the browser smoke.
4. **Ganesh WebGL2 shim**: `gpu_init/begin/end/resize` (CanvasKit FBO-0 pattern); `hello` renders via `KX_BACKEND_GANESH_WEBGL2`; resize verified.
5. **Fonts**: embedded font mgr; text renders in the browser.
6. **Gallery**: `web-gallery` step — real widget tree; mouse/keyboard/touch verified manually on macOS Safari/Chrome + iOS Safari.
7. **A11y**: `web/kx_a11y.js` + bridge; verify with VoiceOver/ChromeVox + DOM assertions in the smoke test.
8. **CI + gates**: `build-wasm` job, wasm size gate, browser smoke.
9. **Polish**: i18n/navigator apps, DPR edge cases, `pagehide` → `emscripten_cancel_main_loop`, docs.

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| emcc version mismatch (Skia vs app link) | link/UB failures | single pinned emsdk in `deps/emsdk`, used by both |
| Zig can't link an exe for emscripten | build blocked | static-lib + `emcc` link (sokol-zig pattern); no `link_libc` in the Zig lib |
| LTO miscompiles wasm (dvui report) | silent corruption | no `-flto` anywhere in the wasm path |
| `SDL_WaitEvent`/`SDL_Delay` block the main thread | tab freeze | `runIteration` never blocks; rAF paces; pacing compiled out (no Asyncify: bloat) |
| WebGL2 context loss (tab switch) | black screen | handle `webglcontextlost/restored` → `resetContext` + recreate target (3f.9) |
| Skia wasm build time (~15-45 min) | slow CI | extend the existing `deps` cache to wasm artifacts |
| wasm binary size (Skia+ICU) | slow load | `-Oz`, `-sENVIRONMENT=web`, size gate; later: `skia_use_icu=false` (libgrapheme/icu4x) |
| No system fonts on wasm | no text | embedded default font; custom fonts later via additive ABI `kx_font_register` (0.11.0) |
| Threads assumed somewhere | crash | Klaxon ABI is thread-confined; build without pthreads (no COOP/COEP) |
| `std.process` args on emscripten | startup crash | verify in step 3; fallback: parse args via JS/EM_ASM |
| PPM dump / golden tests on wasm | false failures | wasm smoke samples browser pixels; native golden tests unchanged |

## 10. Non-goals, ABI impact, sources

**Non-goals for 3f**: Graphite/WebGPU backend (3g), pthreads/COOP/COEP,
`wasm32-wasi` (non-browser runtimes), GPU readback, gamepad, shell-page theming.
**ABI**: stays v0.10.0 for 3f. Deferred additive change (minor bump to 0.11.0,
per ADR-0009): `kx_font_register(const uint8_t* ttf, size_t len)` for
app-provided fonts on wasm.

**Sources**: Skia `deps/skia/gn/{BUILDCONFIG.gn,toolchain/BUILD.gn,toolchain/wasm.gni,skia.gni}`,
`bin/activate-emsdk`, `include/gpu/ganesh/gl/GrGLMakeWebGLInterface.h`,
`src/gpu/ganesh/gl/webgl/GrGLMakeNativeInterface_webgl.cpp`,
`modules/canvaskit/canvaskit_bindings.cpp:288-320`, skia.org/docs/user/build,
skia.org/docs/user/modules/canvaskit, olilarkin/skia-builder (wasm args.gn);
SDL3 `deps/SDL/src/video/emscripten/*`, `src/main/emscripten/SDL_sysmain_callbacks.c`,
`src/timer/unix/SDL_systimer.c`, `src/events/SDL_events.c:1593+`,
`docs/README-emscripten.md`, wiki.libsdl.org/SDL3/README-emscripten;
Zig/Emscripten: `zig targets` (0.17.0), floooh/sokol-zig `build.zig`
(`emLinkStep`, web static-lib pattern), ziggit.dev/t/running-dvui-sdl3-on-web
(LTO breakage), ziggit.dev/t/7000 (wasm32-emscripten libc),
emscripten.org/docs (emscripten.h, html5.h, OpenGL-support, settings);
a11y: figma.com/blog/building-accessibility-into-a-canvas-based-product,
docs.flutter.dev/ui/accessibility/web-accessibility, pauljadam.com/demos/canvas.html.
