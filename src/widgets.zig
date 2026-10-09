// Widgets — the P0 widget library (Phase 1b).
//
// Widgets are factories over the retained node tree (ui/node.zig): each
// factory returns a *Node with a vtable and an owned state; children are
// attached with node.add(child). Widgets compose; see widgets/layout.zig for
// the container semantics contract (fill vs positioning containers).
//
// P0 (14): Row, Column, Stack, Grid, Padding, Center, Align, ConstrainedBox,
// Text, RichText, Icon, Image, Container, Divider.
// Input (8): Button, Toggle, Checkbox, Radio, Slider, TextField, Dropdown, Chip.
// Gestures (1): GestureDetector (wrapper, feeds ui/gestures.zig's arena).
// Animations (3): AnimatedContainer, AnimatedOffset, AnimatedScale.
// Scroll (4): ListView (virtualized), GridView (virtualized), ScrollView,
// Scrollbar.
// Navigation (2): NavigatorView (page stack + transitions), Hero (shared
// element) — Phase 2a.
// i18n (1): L10nText (localized text: plain, with args, plural, plural+signal)
// — Phase 2b.
// Navigation chrome (4): AppBar, NavBar, Drawer, Tabs — Phase 2d.1 batch 1
// (M3E).
// Button (1): the M3E button (5 variants x 5 sizes) — Phase 2d.2 PR A; the
// P0 button stays in input.zig (legacy gallery sections, progressive
// migration).
// ~65 widgets at v1 (see docs/ROADMAP.md).
pub const layout = @import("widgets/layout.zig");
pub const text = @import("widgets/text.zig");
pub const icon = @import("widgets/icon.zig");
pub const image = @import("widgets/image.zig");
pub const container = @import("widgets/container.zig");
pub const divider = @import("widgets/divider.zig");
pub const input = @import("widgets/input.zig");
pub const button = @import("widgets/button.zig");
pub const gestures = @import("widgets/gestures.zig");
pub const anim = @import("widgets/anim.zig");
pub const list_view = @import("widgets/list_view.zig");
pub const grid_view = @import("widgets/grid_view.zig");
pub const scroll_view = @import("widgets/scroll_view.zig");
pub const scrollbar = @import("widgets/scrollbar.zig");
pub const navigator = @import("widgets/navigator.zig");
pub const i18n = @import("widgets/i18n.zig");
pub const app_bar = @import("widgets/app_bar.zig");
pub const nav_bar = @import("widgets/nav_bar.zig");
pub const drawer = @import("widgets/drawer.zig");
pub const tabs = @import("widgets/tabs.zig");
pub const progress = @import("widgets/progress.zig");
pub const badge = @import("widgets/badge.zig");
pub const tooltip = @import("widgets/tooltip.zig");
pub const bottom_sheet = @import("widgets/bottom_sheet.zig");
pub const dialog = @import("widgets/dialog.zig");
pub const snackbar = @import("widgets/snackbar.zig");
