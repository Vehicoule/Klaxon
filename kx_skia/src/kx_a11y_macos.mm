// kx_a11y_macos.mm — macOS NSAccessibility bridge (Phase 3a).
//
// Maps Klaxon's semantic tree (ui/semantics.zig) to macOS NSAccessibility.
// Receives BridgeEventC events via setBridgeC, rebuilds the NSAccessibility
// hierarchy on tree_dirty, syncs focus, posts announcements.
//
// v1: basic role mapping (button, text, text_field, toggle, checkbox, radio,
// slider, image, group, list, list_item, dialog, progress, scrollbar, menu,
// tab). Focus sync + announcements. No actions (click via VoiceOver) yet.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include "kx_skia.h"
#include <stdint.h>
#include <stddef.h>

// --- Forward declarations from Zig (semantics bridge C ABI) ---
extern "C" {
    // BridgeEventC kinds (mirrors BridgeEvent.Kind in ui/semantics.zig).
    enum {
        KX_A11Y_TREE_DIRTY = 0,
        KX_A11Y_FOCUS_CHANGED = 1,
        KX_A11Y_ANNOUNCE = 2,
        KX_A11Y_CONTROL_CHANGED = 3,
    };
    // Install the C bridge callback (from ui/semantics.zig).
    void kx_a11y_set_bridge(void (*fn)(void* userdata, uint32_t kind, uint64_t node_id,
                                       const char* text, size_t text_len, uint32_t region),
                            void* userdata);
    // Build the semantic tree and return a JSON-ish flat description.
    // Returns a malloc'd string (caller frees) or NULL on error.
    // Format: "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n" per node
    // (ptr = Node pointer in decimal, checked = 0/1/2; both ignored here).
    char* kx_a11y_dump_tree(void* root_node);
    void kx_a11y_free_string(char* s);
}

// --- KXA11yElement: wraps a flat semantic node description ---
@interface KXA11yElement : NSObject <NSAccessibilityElement>
{
@public
    NSString* _role;
    NSString* _label;
    NSString* _value;
    BOOL _focusable;
    NSRect _frame;
    NSMutableArray<KXA11yElement*>* _children;
    KXA11yElement* _parent;
}
- (instancetype)initWithRole:(NSString*)role
                       label:(NSString*)label
                       value:(NSString*)value
                   focusable:(BOOL)focusable
                       frame:(NSRect)frame;
@end

@implementation KXA11yElement

- (instancetype)initWithRole:(NSString*)role label:(NSString*)label value:(NSString*)value
                   focusable:(BOOL)focusable frame:(NSRect)frame {
    self = [super init];
    if (self) {
        _role = role;
        _label = label;
        _value = value;
        _focusable = focusable;
        _frame = frame;
        _children = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSRect)accessibilityFrame { return _frame; }
- (id)accessibilityParent { return _parent ?: [NSApp mainWindow]; }
- (NSArray*)accessibilityChildren { return _children; }
- (BOOL)isAccessibilityFocused { return NO; } // v1: focus sync is logged only

- (NSString*)accessibilityRole {
    // Map Klaxon role → NSAccessibility role.
    if ([_role isEqualToString:@"button"]) return NSAccessibilityButtonRole;
    if ([_role isEqualToString:@"text"]) return NSAccessibilityStaticTextRole;
    if ([_role isEqualToString:@"heading"]) return NSAccessibilityHeadingRole;
    if ([_role isEqualToString:@"text_field"]) return NSAccessibilityTextFieldRole;
    if ([_role isEqualToString:@"toggle"]) return NSAccessibilityCheckBoxRole;
    if ([_role isEqualToString:@"checkbox"]) return NSAccessibilityCheckBoxRole;
    if ([_role isEqualToString:@"radio"]) return NSAccessibilityRadioButtonRole;
    if ([_role isEqualToString:@"slider"]) return NSAccessibilitySliderRole;
    if ([_role isEqualToString:@"image"]) return NSAccessibilityImageRole;
    if ([_role isEqualToString:@"progress"]) return NSAccessibilityProgressIndicatorRole;
    if ([_role isEqualToString:@"scrollbar"]) return NSAccessibilityScrollBarRole;
    if ([_role isEqualToString:@"list"]) return NSAccessibilityListRole;
    if ([_role isEqualToString:@"list_item"]) return NSAccessibilityRowRole;
    if ([_role isEqualToString:@"dialog"]) return NSAccessibilityGroupRole;
    if ([_role isEqualToString:@"alert"]) return NSAccessibilityGroupRole;
    if ([_role isEqualToString:@"menu"]) return NSAccessibilityMenuRole;
    if ([_role isEqualToString:@"menu_item"]) return NSAccessibilityMenuItemRole;
    if ([_role isEqualToString:@"tab"]) return NSAccessibilityRadioButtonRole;
    if ([_role isEqualToString:@"link"]) return NSAccessibilityLinkRole;
    return NSAccessibilityGroupRole;
}

- (NSString*)accessibilityLabel { return _label; }
- (NSString*)accessibilityValue { return _value; }

@end

// --- Bridge state ---
static KXA11yElement* g_root = nil;
static void* g_zig_root_node = NULL;

// Parse the flat tree dump and build the NSAccessibility hierarchy.
static KXA11yElement* buildHierarchy(const char* dump) {
    if (!dump) return nil;
    // v1: create a single root group (full hierarchy rebuild is a follow-up).
    // The dump format is "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
    // per line. ptr/checked are parsed for format compatibility and ignored
    // — this bridge keys off the x/y/w/h rects.
    KXA11yElement* root = [[KXA11yElement alloc] initWithRole:@"group"
                                                        label:@"Klaxon"
                                                        value:nil
                                                    focusable:NO
                                                        frame:NSMakeRect(0, 0, 800, 600)];
    // Count lines for a basic child list.
    const char* p = dump;
    int line_count = 0;
    while (*p) {
        if (*p == '\n') line_count++;
        p++;
    }
    // v1: add one child per line (flat list under the root).
    p = dump;
    int idx = 0;
    while (*p && idx < line_count) {
        // Parse: depth|role|label|value|focusable|ptr|checked|x|y|w|h
        int depth = 0;
        char role[64] = {0};
        char label[256] = {0};
        char value[256] = {0};
        int focusable = 0;
        unsigned long long ptr = 0; // node pointer — ignored (v1 keys off rects)
        int checked = 0;            // 0=null 1=false 2=true — ignored
        float x = 0, y = 0, w = 0, h = 0;
        int consumed = 0;
        // Simple sscanf-like parse (depth is the leading integer before '|').
        if (sscanf(p, "%d|%63[^|]|%255[^|]|%255[^|]|%d|%llu|%d|%f|%f|%f|%f%n",
                   &depth, role, label, value, &focusable, &ptr, &checked,
                   &x, &y, &w, &h, &consumed) >= 5) {
            KXA11yElement* child = [[KXA11yElement alloc] initWithRole:
                [NSString stringWithUTF8String:role]
                label:[NSString stringWithUTF8String:label]
                value:[NSString stringWithUTF8String:value]
                focusable:(BOOL)focusable
                frame:NSMakeRect(x, y, w, h)];
            child->_parent = root;
            [root->_children addObject:child];
            p += consumed;
            idx++;
        } else {
            // Skip to next line.
            while (*p && *p != '\n') p++;
        }
        if (*p == '\n') p++;
    }
    return root;
}

// Bridge event callback (called from Zig via setBridgeC).
static void a11y_bridge_callback(void* userdata, uint32_t kind, uint64_t node_id,
                                  const char* text, size_t text_len, uint32_t region) {
    (void)userdata;
    (void)node_id;
    switch (kind) {
        case KX_A11Y_TREE_DIRTY: {
            // Rebuild the hierarchy from the semantic tree dump.
            if (g_zig_root_node) {
                char* dump = kx_a11y_dump_tree(g_zig_root_node);
                if (dump) {
                    @autoreleasepool {
                        KXA11yElement* new_root = buildHierarchy(dump);
                        if (new_root) {
                            g_root = new_root;
                        }
                    }
                    kx_a11y_free_string(dump);
                }
            }
            break;
        }
        case KX_A11Y_FOCUS_CHANGED:
            // v1: logged only (NSAccessibility focus sync is a follow-up).
            break;
        case KX_A11Y_ANNOUNCE: {
            if (text && text_len > 0) {
                NSString* msg = [[NSString alloc] initWithBytes:text
                                                          length:text_len
                                                        encoding:NSUTF8StringEncoding];
                if (msg) {
                    NSDictionary* info = @{
                        NSAccessibilityAnnouncementKey: msg,
                        NSAccessibilityPriorityKey: @(region == 2 ? 10 : 5) // assertive=high
                    };
                    NSAccessibilityPostNotificationWithUserInfo([NSApp mainWindow], NSAccessibilityAnnouncementRequestedNotification, info);
                }
            }
            break;
        }
        case KX_A11Y_CONTROL_CHANGED:
            break;
    }
}

// --- Public C API (called from Zig host.zig) ---
extern "C" {

/// Initialize the NSAccessibility bridge. `root_node` is the Klaxon root Node
/// (used to dump the semantic tree on tree_dirty).
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11y_bridge_callback, NULL);
    // Register the app as an accessibility client.
    [NSApplication sharedApplication];
}

/// Shut down the bridge.
void kx_a11y_shutdown(void) {
    g_root = nil;
    g_zig_root_node = NULL;
    kx_a11y_set_bridge(NULL, NULL);
}

/// Returns the root NSAccessibility element (for NSApp accessibility hookup).
id kx_a11y_root_element(void) {
    return g_root;
}

} // extern "C"
