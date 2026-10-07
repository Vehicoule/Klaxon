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
// 50 widgets at v1 (see docs/ROADMAP.md).
pub const layout = @import("widgets/layout.zig");
pub const text = @import("widgets/text.zig");
pub const icon = @import("widgets/icon.zig");
pub const image = @import("widgets/image.zig");
pub const container = @import("widgets/container.zig");
pub const divider = @import("widgets/divider.zig");
pub const input = @import("widgets/input.zig");
pub const gestures = @import("widgets/gestures.zig");
pub const anim = @import("widgets/anim.zig");
pub const list_view = @import("widgets/list_view.zig");
pub const grid_view = @import("widgets/grid_view.zig");
pub const scroll_view = @import("widgets/scroll_view.zig");
pub const scrollbar = @import("widgets/scrollbar.zig");
