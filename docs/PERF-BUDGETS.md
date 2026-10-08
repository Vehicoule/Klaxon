# Perf Budgets — Klaxon

> Performance is contractual. Every module is born with a budget. A perf regression is a red build, same as a failing test.

## Target metrics (v1)

| Metric | Target | Measured (retail, Adreno 750) | Status |
|---|---|---|---|
| **fps p99** (scroll_10k, real scenes) | ≥ 120 | ~135 avg on empty app — **too easy, target real scenes** | 🎯 Target real scenes (gallery, scroll, anim) |
| **frame p99** | ≤ 3 ms (tightened 2026-10-08 from 4 ms; measured 0.63 hello / 3.31 gallery / 0.98 navigator / 1.19 i18n / 0.71 a11y, raster headless) | 10.6 ms — jank to eliminate | ✅ dirty-rect landed (Phase 1e: retained surface + damage clip + 8.3 ms pacing; low-priority anims pause on overrun) |
| **RSS hello** | < 40 Mo (measured 24.0 Mo — continuous improvement target) | ~45 Mo estimated (Skia floor ~14 + app ~5 + overhead) | 🎯 Ambitious. Gate v1 = < 40 Mo. May take time. |
| **TTFF** (time to first frame) | < 20 ms (tightened 2026-10-08 from 50 ms; measured 0.1 hello / 4.2 gallery / 0.0 navigator / 0.0 i18n / 0.0 a11y, run-start → first frame, raster headless) | 126 ms retail | 🔧 Vulkan init one-shot (~80-140 ms) to optimize |
| **Binary size hello** (arm64 .so / desktop bin) | < 5 Mo (CI gate < 6,8 Mo — tightened 2026-10-08 from 7 Mo; current 6.30 Mo) | 8.59 Mo (libmain.so) | 🔧 ReleaseSmall + strip done; Skia trim (args.gn) to get under 5 Mo |
| **Input latency** (key/tap → repaint) | ≤ 1 frame (≤ 8.3 ms) | synchronous dispatch in the loop | ✅ Router + dirty-flag (Phase 1c/1d) |
| **Nav transition duration** | ≤ 350 ms (target 300 ms, M3 standard curve) | — (target; lands with Phase 2a) | 🎯 Phase 2a |
| **WASM size hello** | < 5 Mo | 6.9 Mo | 🔧 Skia wasm trim |
| **Build time e2e** (gradle included) | Always shorter than Flutter/Qt | 4.7s vs Flutter ~60s, Qt ~120s | ✅ Already winning |
| **allocs_per_frame** (steady-state) | 0 | 0 (target met by design) | ✅ Arena allocator |
| **Widget count v1** | 50 | 22 today (14 P0 + 8 input) | 🎯 Phase 1-4 |
| **Idle CPU** | 0% (0 frames, 0 wakeups) | 0 frames at idle proven | ✅ Dirty-flag loop |

## Two tiers: Gate CI vs North Star

| Tier | Role | Failure consequence |
|---|---|---|
| **Gate CI** | Protects the build. Measured on every commit. | Build goes red. |
| **North Star** | Design direction. Ambitious, approached by construction. | Not a failure. Informs architecture decisions. |

Gates migrate toward the North Star at each major version.

## Gates by scene

### Scene: hello (empty window + one text)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| TTFF | < 100 ms (proxy llvmpipe) → **< 20 ms (device)** (tightened 2026-10-08 from 50 ms) | < 10 ms |
| RSS | < 60 Mo (llvmpipe proxy) → **< 40 Mo (device)** | < 20 Mo |
| Binary size | < 6,8 Mo (tightened 2026-10-08 from 7 Mo) | < 5 Mo |
| frame p99 | ≤ 3 ms (tightened 2026-10-08 from 4 ms) | ≤ 1,5 ms |
| WASM size | < 8 Mo | < 5 Mo |
| Idle | 0 frames, 0% CPU | 0 wakeups/min |

### Scene: scroll_10k (10,000 item list, scroll)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| fps p99 | ≥ 120 (device) / ≥ 60 (llvmpipe proxy) | 120 everywhere |
| frame p99 | ≤ 3 ms (device; tightened 2026-10-08) / ≤ 12 ms (proxy) | ≤ 4 ms everywhere |
| frame avg | ≤ 4 ms | ≤ 2 ms |
| RSS peak | < 80 Mo | < 50 Mo |
| allocs_per_frame | 0 | 0 |
| draw_calls | < 100 | < 50 (aggressive batching) |

### Scene: text_cjk (Japanese/Chinese text + emoji + Arabic RTL)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| frame p99 | ≤ 16.7 ms | ≤ 8.3 ms |
| RSS (fonts loaded) | < 60 Mo (fonts per language, never TTC 32 Mo) | < 40 Mo |
| Glyph raster time | < 1 ms per 100 glyphs | < 0.5 ms |

### Scene: glass_blur (backdrop blur card — Liquid Glass)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| frame p99 (GPU) | ≤ 8.3 ms | ≤ 8.3 ms |
| frame p99 (raster CPU) | ≤ 16.7 ms (blur capped) | ≤ 16.7 ms |
| RSS (5000 blur layers) | < 30 Mo (blur capped/cached) | < 25 Mo |

### Scene: anim_100 (100 widgets animating simultaneously)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| fps p99 | ≥ 120 (GPU) / ≥ 60 (proxy) | 120 everywhere |
| frame CPU p99 | ≤ 8.3 ms | ≤ 6 ms |
| allocs_per_frame | 0 | 0 |

### Scene: gallery (50+ varied widgets)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| fps p99 | ≥ 120 (GPU) / ≥ 60 (proxy) | 120 everywhere |
| draw_calls | < 200 | < 100 |
| RSS peak | < 100 Mo | < 60 Mo |

### Scene: video_playback (4K60 video, GPU zero-copy texture composited over UI)

The Vehicoule app is a media hub (music, video, books, manga) — **120 fps must hold during video playback**. Decode runs on the OS codec (AVFoundation / MediaCodec), frames arrive as GPU textures, composited by Graphite. Decode is off the critical path; UI + compositor stay at 120 fps p99.

| Metric | Gate CI v1 | North Star |
|---|---|---|
| fps p99 (playback) | ≥ 120 (device) / ≥ 60 (proxy) | 120 everywhere |
| frame p99 (composite) | ≤ 8.3 ms | ≤ 8.3 ms |
| dropped UI frames during decode | 0 | 0 |
| RSS (codec + textures) | < 80 Mo | < 60 Mo |
| texture path | GPU zero-copy (no CPU round-trip) | zero-copy |

### Scene: resize (window resize, layout reflow)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| relayout time | < 16.7 ms (one frame) | < 8.3 ms |
| fps during resize | ≥ 60 | 120 |

### Scene: input_ime (TextField with CJK IME composition)

| Metric | Gate CI v1 | North Star |
|---|---|---|
| input latency | < 16.7 ms (key → render) | < 4 ms |
| fps during composition | ≥ 60 | 120 |

## Gates by platform × backend

| Platform | Backend | fps p99 gate | RSS gate | Notes |
|---|---|---|---|---|
| Android (high-end) | graphite-vulkan | ≥ 120 | < 40 Mo | Adreno 750 reference |
| Android (low-end) | ganesh-gles | ≥ 60 | < 40 Mo | Device: Cortex-A53, 2-3 Go RAM |
| Android (no GPU) | raster | ≥ 60 | < 30 Mo | Blur capped, fonts per language |
| iOS | graphite-metal | ≥ 120 | < 40 Mo | Simulator proxy until device |
| macOS | graphite-metal | ≥ 120 | < 40 Mo | arm64 only |
| Linux | graphite-vulkan | ≥ 120 | < 40 Mo | Real GPU |
| Linux | ganesh-gl | ≥ 60 | < 40 Mo | Fallback |
| Linux | raster | ≥ 60 | < 30 Mo | CI proxy (llvmpipe disqualified for RSS/cold) |
| Windows | graphite-dawn-d3d12 | ≥ 120 | < 40 Mo | Real GPU |
| Windows | ganesh-gl | ≥ 60 | < 40 Mo | WARP fallback |
| Web | graphite-webgpu | ≥ 60 | < 40 Mo | Browser GPU |
| Web | ganesh-webgl2 | ≥ 60 | < 40 Mo | Fallback |
| Web | raster | ≥ 30 | < 30 Mo | Last resort |

## Measurement methodology

1. **Frames ≥ N before averaging.** A single idle frame must never become "the average." Minimum 120 frames (2s at 60fps) before computing stats.
2. **Idle-throttle gaps excluded from pacing_p99.** The OS may throttle between frames when idle. These gaps are not jank.
3. **Driver is recorded in every result.** llvmpipe = software, never extrapolated to hardware. Every JSON result carries a `driver` field.
4. **Cold start = median of 3.** Variance on first run is high (page cache, shader compile).
5. **RSS = peak (ru_maxrss).** Not current. The peak is what matters for OOM.
6. **Binary size = post-strip, post-zipalign.** Measure the final artifact, not intermediate objects.
7. **Build time = e2e cold cache.** Full pipeline: zig + C shim + link + package (gradle for Android). Not just `zig build`.

## RSS breakdown targets (hello world)

| Subsystem | Target | Notes |
|---|---|---|
| Skia core (libskia.a stripped) | ~10 Mo | Graphite + Ganesh + raster |
| ICU data (trimmed) | ~2 Mo | Only needed locales, not full ICU |
| Harfbuzz + FreeType | ~1.5 Mo | Text shaping |
| SDL3 (trimmed) | ~2 Mo | Disable unused subsystems (haptic, sensors, camera) |
| Fonts (per language) | ~4.5 Mo | NotoSansJP, not the 32 Mo TTC |
| Zig app (ReleaseSmall + strip) | ~1.2 Mo | Hello world |
| Driver/OS overhead | ~15 Mo | Vulkan/Metal driver, window system |
| **Total** | **~36 Mo** | Under the < 40 Mo gate with ~4 Mo margin |

## Test devices

CI-tier gates run on GitHub Actions runners (Linux/Windows/macOS + Android emulator, headless raster goldens). Device-tier gates run on the device matrix (ROADMAP Phase 4b.4): local iOS Simulator + Android Emulator on the dev Mac, retail Android phone (Adreno 750) via adb as the reference device, remote Linux/Windows machines via ssh.

## CI gates

`gates/thresholds.json` — machine-readable. `zig build test` reads it and fails on violation.

```json
{
  "gates": [
    { "scene": "hello", "metric": "ttff_ms", "op": "<", "value": 100, "tier": "ci", "platform": "linux-llvmpipe" },
    { "scene": "hello", "metric": "ttff_ms", "op": "<", "value": 20, "tier": "device", "platform": "android-arm64" },
    { "scene": "hello", "metric": "peak_rss_mb", "op": "<", "value": 40, "tier": "device", "platform": "android-arm64" },
    { "scene": "scroll_10k", "metric": "fps_p99", "op": ">=", "value": 120, "tier": "device", "platform": "android-arm64" },
    { "scene": "scroll_10k", "metric": "fps_p99", "op": ">=", "value": 60, "tier": "ci", "platform": "linux-llvmpipe" },
    { "scene": "scroll_10k", "metric": "allocs_per_frame", "op": "==", "value": 0, "tier": "ci", "platform": "all" },
    { "scene": "hello", "metric": "binary_size_mb", "op": "<", "value": 6.8, "tier": "ci", "platform": "linux-x64" },
    { "scene": "hello", "metric": "binary_size_mb", "op": "<", "value": 5, "tier": "north_star", "platform": "all" }
  ]
}
```

## Benchmark harness

8 canonical scenes (see ROADMAP Phase 4c). Same scenes run on Klaxon, Flutter, Qt, Compose. Metrics collected identically. Results published as JSON + HTML comparison.

**Klaxon's advantages to prove**:
- fps p99 (Zig + Graphite vs Dart + Impeller/Skia)
- RSS (no GC, no runtime, static binary)
- TTFF (no JIT warmup, fast init)
- Binary size (ReleaseSmall + strip vs Flutter's ~15 Mo)
- Build time (4.7s e2e vs Flutter ~60s)
- WASM (native Skia wasm vs CanvasKit)
