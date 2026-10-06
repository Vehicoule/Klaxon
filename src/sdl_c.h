/* C header for `zig translate-c` (b.addTranslateC in build.zig).
 * Zig 0.17 removed @cImport — C bindings are generated from this header.
 * SDL_main is disabled: the app provides its own main(). */
#define SDL_MAIN_HANDLED 1
#include <SDL3/SDL.h>
