// The 180 degree panel turn. THE one place it is written down; the panel layer (pro_display.c) applies each helper once,
// and the host tests call these same functions to play the glass. Callers above the panel layer see an upright
// PRO_DISPLAY_PX x PRO_DISPLAY_PX glass and must never turn anything.
//
// The turn is a runtime flag (pro_turn_get / pro_turn_set, pro_turn.c). Build with -DPOD_PANEL_TURN=180 and it starts
// turned; otherwise upright. That build flag is only the default: the owner's setting (NVS, via the app) overrides it
// per unit at boot. Whoever changes the flag at runtime must redraw the whole glass between frames (pro_app.c does).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PRO_TURN_PX 720

#if defined(POD_PANEL_TURN) && POD_PANEL_TURN != 180
#error "POD_PANEL_TURN must be 180 when defined"
#endif

// What the flag is before NVS is read: turned when built with POD_PANEL_TURN=180.
static inline bool pro_turn_build_default(void)
{
#if defined(POD_PANEL_TURN) && POD_PANEL_TURN == 180
    return true;
#else
    return false;
#endif
}

bool pro_turn_get(void);
void pro_turn_set(bool turned);   // atomic; the caller redraws the glass (see above)

// A coordinate on the controller's axes <-> on the upright glass (the turn is its own inverse). Identity upright.
static inline int pro_turn_coord(int v) { return pro_turn_get() ? PRO_TURN_PX - 1 - v : v; }
// A contact (x, y): one read of the flag, so a turn landing between the two axes cannot split them.
static inline void pro_turn_point(int *x, int *y)
{
    if (!pro_turn_get()) return;
    *x = PRO_TURN_PX - 1 - *x;
    *y = PRO_TURN_PX - 1 - *y;
}

// Reverse a w*h block of pixels in place: with the rectangle mapped by pro_turn_rect this is a 180 degree turn.
static inline void pro_turn_pixels(uint16_t *px, size_t count)
{
    if (!pro_turn_get() || count < 2) return;
    for (uint16_t *a = px, *b = px + count - 1; a < b; a++, b--) {
        const uint16_t v = *a;
        *a = *b;
        *b = v;
    }
}

// The rectangle (x, y, w, h) of the upright glass -> its top-left corner on the panel.
static inline void pro_turn_rect(int x, int y, int w, int h, int *panel_x, int *panel_y)
{
    const bool turned = pro_turn_get();
    *panel_x = turned ? PRO_TURN_PX - x - w : x;
    *panel_y = turned ? PRO_TURN_PX - y - h : y;
}
