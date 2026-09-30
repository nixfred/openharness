// nixfred graphics: see nixfred_art.h and nixfred/DESIGN.md ("Device").
//
// Every mark here answers a question a person has at that moment: is it still booting (the scanner
// moves), how far is the transfer (the rim fills), who is it waiting on and is it asking permission
// (the ring's colour, the badge and the lock). Black canvas; colours come in from the theme.
#include "nixfred_art.h"
#include <string.h>

// `c` at `pct` percent over `under`, in RGB565: the glow's falloff without a blend per pixel.
static uint16_t over(uint16_t c, uint16_t under, unsigned pct)
{
    unsigned r = ((c >> 11) * pct + (under >> 11) * (100 - pct)) / 100;
    unsigned g = (((c >> 5) & 63) * pct + ((under >> 5) & 63) * (100 - pct)) / 100;
    unsigned b = ((c & 31) * pct + (under & 31) * (100 - pct)) / 100;
    return (uint16_t)((r << 11) | (g << 5) | b);
}
#define dim(c, pct) over((c), f->background, (pct))

enum { CX = HT_WIDTH / 2, CY = HT_HEIGHT / 2, LOGO_CY = 196 };

void nixfred_boot_face(ht_scene_t *f, uint16_t accent, uint16_t ink, int pct, int scan_step)
{
    // The glow: three soft bands just outside the mark's own circle (r 67 at this size), fading out.
    ht_ring(f, CX, LOGO_CY, 69, 75, 0, HT_TURN, dim(accent, 38));
    ht_ring(f, CX, LOGO_CY, 75, 83, 0, HT_TURN, dim(accent, 18));
    ht_ring(f, CX, LOGO_CY, 83, 95, 0, HT_TURN, dim(accent, 7));
    ht_mask(f, CX - NIXFRED_LOGO_W / 2, LOGO_CY - NIXFRED_LOGO_H / 2, NIXFRED_LOGO_W, NIXFRED_LOGO_H,
            nixfred_logo_alpha, accent);
    ht_center(f, 306, &ht_mono_28, ink, "Harness");
    // The rim: a faint track, then either the transfer's percentage or the scanner.
    ht_ring(f, CX, CY, NIXFRED_RIM_IN + 2, NIXFRED_RIM_OUT - 2, 0, HT_TURN, dim(accent, 14));
    if (pct >= 0) {
        if (pct > 100) pct = 100;
        if (pct > 0) ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, 0, pct * HT_TURN / 100, accent);
        char label[8];
        int n = 0;
        if (pct >= 100) { memcpy(label, "100%", 5); n = 4; }
        else if (pct >= 10) { label[0] = (char)('0' + pct / 10); label[1] = (char)('0' + pct % 10); label[2] = '%'; n = 3; }
        else { label[0] = (char)('0' + pct); label[1] = '%'; n = 2; }
        label[n] = 0;
        ht_center(f, 352, &ht_mono_20, dim(ink, 70), label);
    } else {
        int step = ((scan_step % NIXFRED_SCAN_STEPS) + NIXFRED_SCAN_STEPS) % NIXFRED_SCAN_STEPS;
        ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, step * HT_TURN / NIXFRED_SCAN_STEPS,
                HT_TURN / 10, accent);
    }
}

void nixfred_attention(ht_scene_t *f, bool permission, const char *initials, uint16_t yellow, uint16_t red,
                       uint16_t ink)
{
    uint16_t state = permission ? red : yellow;
    // Glow is urgency: a soft band inside the rim, then the state ring itself on the rim.
    ht_ring(f, CX, CY, NIXFRED_RIM_IN - 12, NIXFRED_RIM_IN, 0, HT_TURN, dim(state, 12));
    ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, 0, HT_TURN, state);
    // The badge at 12 o'clock: who this is waiting on. Initials when the host supplies them; until the
    // protocol carries an avatar, a neutral figure. Never a bundled face.
    enum { BX = CX, BY = 36, BR = 20 };
    ht_ring(f, BX, BY, BR - 3, BR, 0, HT_TURN, state);
    if (initials && initials[0]) {
        char two[3] = {initials[0], initials[1] ? initials[1] : 0, 0};
        int w = (int)strlen(two) * ht_mono_20.width;
        ht_text(f, BX - w / 2, BY - ht_mono_20.height / 2, w, &ht_mono_20, ink, f->background, two);
    } else {
        uint16_t figure = dim(ink, 75);
        ht_ring(f, BX, BY - 6, 0, 5, 0, HT_TURN, figure);                 // head
        ht_ring(f, BX, BY + 10, 0, 10, HT_TURN * 3 / 4, HT_TURN / 2, figure); // shoulders, the upper half
    }
    if (permission) {
        // The lock beside the badge: shackle (upper half ring) over a rounded body with a keyhole.
        enum { LX = CX + 42, LY = 36 };
        ht_ring(f, LX, LY - 4, 5, 8, HT_TURN * 3 / 4, HT_TURN / 2, red);
        ht_box(f, LX - 11, LY - 4, 22, 17, 3, red, red);
        ht_box(f, LX - 1, LY + 1, 3, 7, 1, f->background, f->background);
    }
}
