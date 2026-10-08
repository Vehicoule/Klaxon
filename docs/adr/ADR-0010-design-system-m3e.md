# ADR-0010 — Material 3 Expressive as the design system

**Status**: Accepted
**Date**: 2026-10-08

## Context

Phase 2d starts the real widget set (AppBar, NavBar, Drawer, Tabs, BottomSheet, Dialog, ProgressIndicator, Badge, Tooltip, SnackBar). The P0 widgets are test fixtures with ad-hoc hardcoded colors — they do not implement any design system. The framework targets Flutter/Qt-level quality with one visual language on mobile, desktop and web, and must leave room for app-level branding (the Vehicoule app will reskin on top).

Candidates: Material 3 (M3), Material 3 Expressive (M3E), Apple HIG, Fluent, Cupertino, or a bespoke system.

## Decision

**Material 3 Expressive (M3E) is the base design system**, as a token layer (`src/theme.zig`), with two explicit layers on top:

1. **Platform adaptation** (ours): desktop density, hover/focus treatment, keyboard navigation, safe areas, hit-target sizes. Behavior borrowed from HIG/Fluent, never their visuals.
2. **App overrides** (the app's): a custom `Theme` value overriding tokens — this is where custom branding lands.

The previous 10-token placeholder theme is dropped outright (no backward compatibility — nothing is released).

## Rationale

| Criterion | M3E | HIG | Fluent | Bespoke |
|---|---|---|---|---|
| Fully tokenized spec (maps to a `Theme` struct) | Yes | Partial | Partial | No |
| Adaptive mobile/desktop (size classes, canonical layouts) | Yes | Per-platform | Per-platform | No |
| Spring-based motion (fits the 120 fps goal) | Yes | UIKit dynamics | Yes | No |
| Open reference implementations to port from | Compose, Flutter (partial) | SwiftUI (Swift-only) | WinUI (C#/C++-only) | None |
| One visual language, all platforms | Yes | No (per-platform look) | No | Yes but unproven |
| Accessibility spec (contrast, targets, focus) | Yes | Yes | Yes | No |

M3E is a superset of M3: same color roles and type scale, plus spring motion, more expressive shapes and updated component variants. Adopting it costs nothing over plain M3 and buys the motion system the framework's feel depends on. The existing `ui.anim.Spring` (closed-form, tick-rate independent) already implements M3E-style springs.

## Risks

- **M3E is young (2025)**: the spec is still evolving. Mitigation: tokens isolate us — a spec change is a value change, not an architecture change.
- **Thin desktop coverage**: M3E is mobile-first. Mitigation: the platform-adaptation layer (ours) fills the desktop gap; that layer is also where the product's own taste lands.
- **Thin reference implementations**: Flutter's M3E support is partial. Mitigation: per widget, take the M3E spec where it exists and the M3 spec where M3E is silent; Compose is the primary reference.

## Consequences

- `src/theme.zig` becomes the full M3E token set: `ColorScheme` (light/dark M3 baselines), `TypeScale` (15 styles), `Shape`, `Elevation`, `Motion` (durations, easings, M3E spring presets), `StateLayers`, `Spacing`. Plus helpers: `stateLayer`, `relativeLuminance`, `contrastRatio`.
- `ui.anim.Spring.fromDampingRatio` bridges the M3E spec parameterization (stiffness + damping ratio) to the engine's (k, c).
- P1 widgets take a `theme: Theme` in their options (default `theme.light`) and never hardcode colors, sizes, durations or springs.
- The gallery migrates to the new roles (`docs/DESIGN-SYSTEM.md` documents the mapping).
- P0 widgets keep their hardcoded fixture colors until they are migrated to tokens (tracked in ROADMAP).
- See `docs/DESIGN-SYSTEM.md` for the token reference and the widget → spec mapping.
