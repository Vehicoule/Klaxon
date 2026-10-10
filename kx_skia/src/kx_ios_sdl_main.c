// kx_ios_sdl_main.c — fournit main() pour SDL3 iOS (Phase 3e).
//
// Sur iOS, SDL_MAIN_NEEDED : SDL fournit le main() — SDL_main.h, inclus ici
// avec SDL_MAIN_USE_CALLBACKS, embarque l'implémentation inline de SDL_main
// (SDL_main_impl.h) qui délègue à SDL_EnterAppMainCallbacks avec les 4
// callbacks de l'app. Les symboles SDL_AppInit / SDL_AppEvent /
// SDL_AppIterate / SDL_AppQuit sont exportés par src/platform_ios.zig (Zig) ;
// ce TU est le seul endroit où SDL_main.h est inclus avec
// SDL_MAIN_USE_CALLBACKS, il ancre la référence à ces symboles dans la lib
// finale (SDL_main est header-only en SDL3 : un seul TU d'inclusion).
#define SDL_MAIN_USE_CALLBACKS
#include <SDL3/SDL_main.h>
