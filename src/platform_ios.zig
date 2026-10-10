// platform_ios.zig — iOS platform glue (Phase 3e, aarch64-ios).
//
// Miroir de platform_wasm.zig, mais avec les SDL main callbacks : sur iOS,
// SDL fournit main() (SDL_MAIN_NEEDED) — kx_skia/src/kx_ios_sdl_main.c inclut
// SDL_main.h avec SDL_MAIN_USE_CALLBACKS, et SDL appelle les 4 callbacks
// exportés ici. SDL_AppInit construit le host + l'arbre via main_ios.start()
// (l'AppState est alloué en page_allocator : les callbacks reviennent plus
// tard, la pile de SDL_AppInit ne doit pas fuiter). SDL_AppIterate est piloté
// par un CADisplayLink (SDL_sysmain_callbacks.m) : une itération = un
// host.runIteration() (drain events + tick + render). SDL_AppEvent reçoit
// chaque événement retiré de la file SDL (SDL_main_callbacks.c consomme —
// un événement ignoré ici serait perdu) : il est routé directement dans le
// host (host.handleEvent, rendu pub par le sous-agent host.zig).
//
// Guard: ce fichier n'est compilé que pour la cible iOS (build.zig ne le
// référence que depuis le graphe ios) — le @compileError ci-dessous rend la
// contrainte explicite si un build natif l'importait par erreur.
const std = @import("std");
const builtin = @import("builtin");
const host_mod = @import("host.zig");
const ui = @import("ui.zig");
const sdl = @import("sdl.zig");
const main_ios = @import("main_ios.zig");

const Host = host_mod.Host;
const Node = ui.node.Node;

comptime {
    if (builtin.os.tag != .ios) @compileError("platform_ios.zig is iOS-only (aarch64-ios)");
}

/// État de l'app, alloué en stockage stable par main_ios.start() et transmis
/// à chaque callback via le appstate de SDL_AppInit.
pub const AppState = struct {
    host: *Host,
    root: *Node,
    on_frame: ?host_mod.OnFrame,
    on_frame_ctx: ?*anyopaque,
    max_frames: u64,
    /// Requête de quit latched par SDL_AppEvent (l'AppState est le canal entre
    /// les deux callbacks — SDL peut les appeler depuis des threads
    /// différents, même si sur iOS tout tourne sur le main thread).
    quit: bool = false,
};

/// App-implemented initial entry point (SDL_MAIN_USE_CALLBACKS). Construit le
/// host + l'arbre via main_ios.start() et stocke l'AppState dans *appstate.
export fn SDL_AppInit(appstate: [*c]?*anyopaque, argc: c_int, argv: [*c][*c]u8) callconv(.c) sdl.c.SDL_AppResult {
    _ = argc; // pas de parsing d'args sur iOS
    _ = argv;
    const state = main_ios.start() catch return sdl.c.SDL_APP_FAILURE;
    appstate.* = @ptrCast(state);
    return sdl.c.SDL_APP_CONTINUE;
}

/// App-implemented event callback: route l'événement SDL dans le host (le
/// routeur d'input + l'arbre). Un événement non consommé ici est perdu (SDL
/// le retire de la file avant de nous le donner). Retourne SDL_APP_SUCCESS
/// quand l'événement demande la fin de l'app (SDL_EVENT_QUIT → handleEvent
/// retourne true) — SDL latch alors la sortie et appelle SDL_AppQuit.
export fn SDL_AppEvent(appstate: ?*anyopaque, event: *sdl.c.SDL_Event) callconv(.c) sdl.c.SDL_AppResult {
    const state: *AppState = @ptrCast(@alignCast(appstate.?));
    if (state.host.handleEvent(state.root, event)) {
        state.quit = true;
        return sdl.c.SDL_APP_SUCCESS;
    }
    return sdl.c.SDL_APP_CONTINUE;
}

/// App-implemented iteration callback (CADisplayLink, ~vsync): exactement un
/// passage non-bloquant de la boucle — drain des événements, tick, render.
/// Retourne SDL_APP_SUCCESS quand l'app demande la fin (quit) ou que le
/// budget de frames est épuisé (borne le run sur simulateur).
export fn SDL_AppIterate(appstate: ?*anyopaque) callconv(.c) sdl.c.SDL_AppResult {
    const state: *AppState = @ptrCast(@alignCast(appstate.?));
    if (state.quit) return sdl.c.SDL_APP_SUCCESS;
    const quit = state.host.runIteration(state.root, state.on_frame, state.on_frame_ctx) catch return sdl.c.SDL_APP_FAILURE;
    if (quit or state.host.stats.frames >= state.max_frames) return sdl.c.SDL_APP_SUCCESS;
    return sdl.c.SDL_APP_CONTINUE;
}

/// App-implemented quit callback: appelé par SDL quoi qu'il arrive (même si
/// SDL_AppInit a échoué — dans ce cas appstate est null, on ne touche à rien).
export fn SDL_AppQuit(appstate: ?*anyopaque, result: sdl.c.SDL_AppResult) callconv(.c) void {
    _ = result;
    const state: *AppState = @ptrCast(@alignCast(appstate orelse return));
    state.host.deinit();
}
