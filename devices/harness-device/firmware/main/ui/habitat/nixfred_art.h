#pragma once
// nixfred graphics (nixfred/DESIGN.md, "Device"): the faces built from rings, arcs and the logo mask.
// Pure scene composition on terminal.h: no ESP-IDF, no allocation, host-testable (test_nixfred_ring.c).
#include "terminal.h"

// The Harness mark as a one-colour alpha mask (nixfred_logo.c, generated from
// docs/branding/app-logo/harness-logo-4.svg). A host-supplied logo would replace this pointer: the cable
// protocol carries no logo today, so this is the hook, not a feature.
enum { NIXFRED_LOGO_W = 150, NIXFRED_LOGO_H = 150 };
extern const uint8_t nixfred_logo_alpha[NIXFRED_LOGO_W * NIXFRED_LOGO_H];

// Rim geometry shared by every face: the state ring sits just inside the glass.
enum { NIXFRED_RIM_IN = 223, NIXFRED_RIM_OUT = 231, NIXFRED_SCAN_STEPS = 8 };

// Boot / loading / firmware-transfer face: glow logo in the centre, wordmark under it. `pct` 0..100 fills
// the rim clockwise (a transfer); `pct` < 0 draws a scanner segment at `scan_step` (one lap a second),
// so a stuck boot reads as a stopped line.
void nixfred_boot_face(ht_scene_t *f, uint16_t accent, uint16_t ink, int pct, int scan_step);

// Question / permission chrome: the state ring on the rim with a soft glow inside it, and a badge at
// 12 o'clock: the person the agent is waiting on (initials when the host supplies them, else a neutral
// figure), plus a lock glyph beside it for a permission prompt. Yellow waits, red is permission.
void nixfred_attention(ht_scene_t *f, bool permission, const char *initials, uint16_t yellow, uint16_t red,
                       uint16_t ink);
