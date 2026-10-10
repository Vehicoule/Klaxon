# M3E specs — 4d P2: Avatar

Sources: no official M3/M3E Avatar spec. Cross-referenced with:
Jetpack Compose Material3 `Avatar` (experimental), Flutter `CircleAvatar`,
Material Web (MWC) `avatar`, iOS `UIImageView` circular idiom, and the
M3E token system (`src/theme.zig`).

## Design

A circular avatar: a `PrimaryContainer` circle with either initials
(1-2 letters, `OnPrimaryContainer`) or an image (clipped to the circle).
Five M3E sizes on the 4dp grid.

## Tokens

| Token | Value | Used for |
|---|---|---|
| Container color | `PrimaryContainer` | the circle fill (initials variant) |
| Content color | `OnPrimaryContainer` | initials text |
| Shape | CornerFull (size/2) | the circle |
| XS size | 24dp | extra-small avatar |
| S size | 32dp | small avatar |
| M size | 40dp | medium avatar (default) |
| L size | 56dp | large avatar |
| XL size | 96dp | extra-large avatar |
| Initials font | size × 0.4 (rounded to 1dp) | initials text size |
| Initials weight | 500 (medium) | initials text weight |

## Variants

| Variant | Content | Fill |
|---|---|---|
| `initials` | 1-2 letter text (uppercase) | `PrimaryContainer` |
| `image` | RGBA pixels clipped to circle | the image |
| `icon` | a single icon glyph | `PrimaryContainer` |

## Layout

- A square node of side = size. The circle is inscribed (CornerFull).
- Initials are centered (both axes).
- Image variant: the image is drawn stretched to fill the circle,
  clipped by a circular clip (reuses the kx clip API or a circular
  clip path — v1 uses a simple approach: draw the image then a
  circle mask via `fillRRect` with the inverse blend, or accept
  square corners in v1 and add circular clip in Phase 3).

## Interaction

- Non-interactive by default (a display element).
- Optional `on_tap` callback (the avatar becomes a button).
- State layers when tappable: hover 0.08 / pressed 0.12 over
  `OnPrimaryContainer`.

## Semantics (a11y)

- role: `.image`
- label: the `a11y_label` option, or the initials text, or "Avatar"
- focusable: only when tappable

## Registry

- `avatar` (category `display`): `size` (select: 24/32/40/56/96),
  `initials` (text), `a11y_label` (text), `tappable` (toggle).
  Image variant is not registry-serializable (binary data) — v1
  registry supports initials + icon variants only.

## v1 deviations

- Image variant: no circular clip (square image, circle fill behind).
- No badge/dot overlay (status indicator).
- No group avatar stack (overlapping avatars).
- Initials: max 2 characters, uppercase, no font fallback for
  non-Latin initials.

## Follow-ups

- Circular clip for the image variant (kx clip path or stencil).
- Badge/dot overlay (status: online/away/busy).
- Avatar group (stacked overlapping avatars with +N overflow).
