// main_ios.zig — racine de la lib statique iOS (Phase 3e).
//
// Sur iOS, SDL fournit main() (SDL_MAIN_NEEDED) : kx_skia/src/kx_ios_sdl_main.c
// inclut SDL_main.h avec SDL_MAIN_USE_CALLBACKS, et les 4 callbacks SDL sont
// exportés par platform_ios.zig. Ce fichier n'a PAS de pub fn main (interdit
// avec les callbacks) : il expose start(), appelé par SDL_AppInit, qui
// construit le Host + l'arbre dans du stockage stable (page_allocator — les
// callbacks reviennent plus tard, la pile de SDL_AppInit ne doit pas fuiter).
//
// SQUELETTE : la taille de fenêtre est un placeholder (0x0) — le vrai code
// lira SDL_GetWindowSize après la création de la fenêtre (l'événement
// SDL_EVENT_WINDOW_RESIZED re-layout l'arbre via host.handleEvent). Le
// backend demandé est Graphite-Metal, avec un fallback raster si kx_create
// échoue (simulateur sans Metal, etc.).
//
// Guard: racine du graphe ios uniquement (build.zig) — le @compileError rend
// la contrainte explicite si un build natif la compilait par erreur.
const std = @import("std");
const builtin = @import("builtin");
const host_mod = @import("host.zig");
const kx = @import("kx.zig");
const ui = @import("ui.zig");
const input_mod = @import("ui/input.zig");
const demo_mod = @import("demo.zig");
const gallery_mod = @import("gallery.zig");
const platform_ios = @import("platform_ios.zig");
const sdl = @import("sdl.zig");

const Host = host_mod.Host;
const Node = ui.node.Node;

comptime {
    if (builtin.os.tag != .ios) @compileError("main_ios.zig is iOS-only (aarch64-ios)");
}

// Force-link the SDL main callbacks (consumed by SDL_main in
// kx_ios_sdl_main.c): Zig only emits referenced symbols — analyzing the
// platform_ios.zig file emits its export decls (same pattern as host.zig's
// a11y_bridge force-link).
comptime {
    _ = @import("platform_ios.zig");
}

pub const AppKind = enum { hello, gallery };

// Option de build -Dios-app=hello|gallery (défaut: gallery).
// TODO(build.zig): remplacer par b.addOption quand le step ios sera câblé sur
// ce fichier (le root du graphe ios est encore gallery_main.zig, placeholder).
const ios_app: AppKind = .gallery;

const max_frames: u64 = 0; // 0 = run forever (mobile: OS terminates the app)

/// Construit le Host + l'arbre et retourne l'AppState des callbacks SDL.
/// Appelé une fois par SDL_AppInit (platform_ios.zig). Tout est alloué en
/// page_allocator : l'AppState doit survivre à la pile de SDL_AppInit (même
/// pattern que le chemin wasm de main.zig — fuite intentionnelle, l'app vit
/// aussi longtemps que le process).
pub fn start() !*platform_ios.AppState {
    const stable = std.heap.page_allocator;

    // Backend: Graphite-Metal (GPU), fallback raster si kx_create échoue.
    const host_ptr = try stable.create(Host);
    host_ptr.* = host_mod.Host.init(stable, 0, 0, kx.c.KX_BACKEND_GRAPHITE_METAL, null) catch |err| blk: {
        if (err == error.KxCreate) {
            // SDL_Log (pas std.debug.print : sur iOS, Zig 0.17 std.debug.print
            // passe par std.Io.Threaded, dont le vtable référence spawnDarwin →
            // getDevNullFd → null_file.fd — NullFile n'a pas de champ fd sur
            // iOS, bug std 0.17. SDL_Log écrit sur stderr/OSLog, sans std.Io).
            sdl.c.SDL_Log("kx_create failed (Graphite-Metal), fallback raster");
            break :blk try host_mod.Host.init(stable, 0, 0, kx.c.KX_BACKEND_RASTER, null);
        }
        return err;
    };
    // Pas de defer host.deinit() : le host vit aussi longtemps que l'app
    // (SDL_AppQuit appelle host.deinit).

    input_mod.setCurrent(&host_ptr.input); // le routeur est process-global (single-window P0)
    ui.anim.setCurrent(&host_ptr.timeline); // la timeline d'animation, même pattern

    // Arbre selon l'app demandée (-Dios-app).
    const root: *Node = switch (ios_app) {
        .hello => blk: {
            const demo_ptr = try stable.create(demo_mod.Demo);
            demo_ptr.* = try demo_mod.buildTree(stable);
            // Pas de defer demo.deinit() : stockage stable, même raison.
            break :blk demo_ptr.root;
        },
        .gallery => blk: {
            const g = try gallery_mod.Gallery.init(stable);
            break :blk g.root;
        },
    };
    // Layout at the real window size (queried from SDL in Host.init on
    // mobile — the 0x0 passed to init is just a placeholder).
    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(host_ptr.width), .h = @floatFromInt(host_ptr.height) });

    const state = try stable.create(platform_ios.AppState);
    state.* = .{
        .host = host_ptr,
        .root = root,
        .on_frame = null,
        .on_frame_ctx = null,
        .max_frames = max_frames,
    };
    return state;
}
