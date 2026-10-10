package com.klaxon.gallery;

import org.libsdl.app.SDLActivity;

/**
 * Klaxon gallery — Android launcher activity (Phase 3d).
 *
 * The whole UI is native: this class only wires the Android lifecycle to SDL.
 * SDLActivity loads the shared libraries returned by getLibraries()
 * (libSDL3.so, then libmain.so) and runs the native SDL_main() entry point
 * exported by src/gallery_main.zig on SDL's main thread.
 */
public class KlaxonActivity extends SDLActivity {

    /**
     * Libraries to load, in order. The LAST entry is the one SDLActivity runs
     * SDL_main from: "main" -> libmain.so, built by CMake from
     * zig-out/lib/libgallery.a + the kx_skia shim.
     */
    @Override
    protected String[] getLibraries() {
        return new String[] {
            "SDL3",
            "main",
        };
    }

    /**
     * No CLI arguments on device — the gallery picks its default
     * (raster) backend from SDL_main.
     */
    @Override
    protected String[] getArguments() {
        return new String[0];
    }
}
