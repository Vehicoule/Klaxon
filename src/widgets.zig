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
// IconButton (1): the M3E icon button (4 variants x 5 sizes x 3 widths,
// plain + toggle) — Phase 2d.2 PR B1.
// Selection controls (4): Checkbox / Radio / Switch / Slider M3E — Phase 2d.2
// PR B2 (they replace the P0 checkbox/toggle/slider; the P0 fixtures stay
// in input.zig for the legacy gallery sections).
// Chips (5): the M3E chip variants (assist / elevated / filter / input /
// suggestion) — Phase 2d.2 PR C1.
// TextField (2): the M3E text field (filled / outlined, floating label,
// icons, supporting text, error/disabled, real text entry) — Phase 2d.2
// PR C2 (the P0 text field stays in input.zig for the legacy gallery Input
// section).
// Cards (3): the M3E card variants (filled / elevated / outlined) — Phase
// 2d.3 PR D1.
// ListItem (3): the M3E list item (one / two / three lines, leading icon,
// overline/headline/supporting, trailing icon/text, selected/disabled) —
// Phase 2d.3 PR D1.
// Menu (1): the M3E dropdown menu (anchor + popup panel, signal-driven open
// state, keyboard navigation) — Phase 2d.3 PR D2.
// SegmentedButton (1): the M3E single-choice segmented button row (equal
// segments, outlined, signal-driven selection) — Phase 2d.3 PR D3.
// SplitButton (1): the M3E split button (leading action + trailing toggle,
// filled style, 5 sizes) — Phase 2d.3 PR D3.
// SearchBar (1): the M3E collapsed search bar (56dp pill, text entry, clear
// button) — Phase 2d.3 PR D4.
// NavigationRail (1): the M3E navigation rail (collapsed circle indicator /
// expanded pill, signal-driven selection) — Phase 2d.3 PR D4.
// SideSheet (1): the M3E side sheet (standard coplanar / modal + scrim,
// start/end anchored) — Phase 2d.3 PR D5.
// PullToRefresh (1): the M3E pull-to-refresh container (pull gesture +
// arc indicator, live refreshing signal) — Phase 2d.3 PR D5.
// LoadingIndicator (1): the M3E shape-morphing loading indicator
// (indeterminate morph loop / determinate via a progress signal, contained
// variant) — Phase 2d.4 PR #32.
// DatePicker (1): the M3E date picker panel (calendar: header, month nav,
// weekday row, day grid, Cancel/OK) — Phase 2d.4 PR #33.
// TimePicker (1): the M3E time picker (dial: time plates + AM/PM, clock face
// with hour/minute modes) — Phase 2d.4 PR #33.
// ~73 widgets at v1 (see docs/ROADMAP.md).
pub const layout = @import("widgets/layout.zig");
pub const text = @import("widgets/text.zig");
pub const icon = @import("widgets/icon.zig");
pub const image = @import("widgets/image.zig");
pub const container = @import("widgets/container.zig");
pub const divider = @import("widgets/divider.zig");
pub const input = @import("widgets/input.zig");
pub const button = @import("widgets/button.zig");
pub const icon_button = @import("widgets/icon_button.zig");
pub const checkbox = @import("widgets/checkbox.zig");
pub const radio = @import("widgets/radio.zig");
pub const @"switch" = @import("widgets/switch.zig");
pub const slider = @import("widgets/slider.zig");
pub const chip = @import("widgets/chip.zig");
pub const text_field = @import("widgets/text_field.zig");
pub const card = @import("widgets/card.zig");
pub const list_item = @import("widgets/list_item.zig");
pub const menu = @import("widgets/menu.zig");
pub const segmented_button = @import("widgets/segmented_button.zig");
pub const split_button = @import("widgets/split_button.zig");
pub const search_bar = @import("widgets/search_bar.zig");
pub const navigation_rail = @import("widgets/navigation_rail.zig");
pub const side_sheet = @import("widgets/side_sheet.zig");
pub const pull_to_refresh = @import("widgets/pull_to_refresh.zig");
pub const loading_indicator = @import("widgets/loading_indicator.zig");
pub const date_picker = @import("widgets/date_picker.zig");
pub const time_picker = @import("widgets/time_picker.zig");
pub const color_picker = @import("widgets/color_picker.zig");
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
pub const avatar = @import("widgets/avatar.zig");
pub const expansion_panel = @import("widgets/expansion_panel.zig");
pub const stepper = @import("widgets/stepper.zig");
pub const calendar = @import("widgets/calendar.zig");
pub const table = @import("widgets/table.zig");
pub const tree = @import("widgets/tree.zig");
