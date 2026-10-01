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

// ---- slice 2 ------------------------------------------------------------------------------------------

static unsigned tri(unsigned phase) // 0..8..0 over NIXFRED_PHASES
{
    phase %= NIXFRED_PHASES;
    return phase <= NIXFRED_PHASES / 2 ? phase : NIXFRED_PHASES - phase;
}
static bool fail_lit(uint32_t since) // the two flashes: on 0..120, off 120..240, on 240..360, off 360..480
{
    return since < NIXFRED_FAIL_FLASH_MS && (since / 120) % 2 == 0;
}

static int state_runs(uint8_t st, bool rich)
{
    if (!rich) return 1;
    return st == NIXFRED_OFFLINE ? 3 : st == NIXFRED_WORKING ? 2 : 1;
}

void nixfred_fleet_rim(ht_scene_t *f, const uint8_t *state, int n, int span, unsigned phase,
                       uint32_t fail_ms, const nixfred_palette_t *p)
{
    if (n <= 0) return;
    // Busiest first: a stable sort by priority, so two agents in one state keep the host's order.
    uint8_t order[NIXFRED_RIM_MAX];
    int m = 0;
    for (int st = NIXFRED_STATES - 1; st >= 0 && m < NIXFRED_RIM_MAX; st--)
        for (int i = 0; i < n && m < NIXFRED_RIM_MAX; i++)
            if (state[i] == st) order[m++] = (uint8_t)st;
    if (span <= 0 || span > HT_TURN) span = HT_TURN;
    int need = 0;
    for (int k = 0; k < m; k++) need += state_runs(order[k], true);
    bool rich = f->count + need <= HT_RUNS - 2; // drawn last; leave the rest of the budget to a summary
    int slot = span / m, gap = m == 1 ? 0 : slot / 10 < 24 ? 24 : slot / 10;
    int arc = slot - gap;
    unsigned t = tri(phase);
    for (int k = 0; k < m; k++) {
        int offset = k == 0 ? 0 : (k % 2 ? 1 : -1) * ((k + 1) / 2) * slot;
        int start = offset - arc / 2;
        uint8_t st = order[k];
        switch (st) {
        case NIXFRED_PERMISSION:
            ht_ring(f, CX, CY, NIXFRED_RIM_IN - 3, NIXFRED_RIM_OUT, start, arc, p->red);
            break;
        case NIXFRED_FAILED:
            if (fail_ms < NIXFRED_FAIL_FLASH_MS)
                ht_ring(f, CX, CY, NIXFRED_RIM_IN - 3, NIXFRED_RIM_OUT, start, arc,
                        fail_lit(fail_ms) ? p->red : f->background);
            else
                ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, start, arc, p->red);
            break;
        case NIXFRED_WAITING: // the breath: 55..100 percent of the yellow
            ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, start, arc, dim(p->yellow, 55 + t * 45 / 8));
            break;
        case NIXFRED_WORKING: {
            // The sweep: a bright segment travelling across the agent's own arc and back, over a dim track.
            int seg = arc * 2 / 5, at = start + (arc - seg) * (int)t / 8;
            if (rich) ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, start, arc, dim(p->accent, 30));
            ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, at, seg, p->accent);
            break;
        }
        case NIXFRED_DONE:
            ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, start, arc, p->green);
            break;
        case NIXFRED_OFFLINE:
            if (rich)
                for (int d = 0; d < 3; d++) // dotted: three short marks across the slot
                    ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, start + d * arc / 3 + arc / 12, arc / 6,
                            dim(p->ink, 35));
            else
                ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 2, NIXFRED_RIM_OUT, start, arc, dim(p->ink, 25));
            break;
        default: // idle
            ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, start, arc, dim(p->ink, 28));
            break;
        }
    }
}

void nixfred_fleet_summary(char *out, int size, uint16_t *color, const uint8_t *state, int n,
                           const nixfred_palette_t *p)
{
    static const char glyph[NIXFRED_STATES] = {'-', '.', '+', '~', '?', 'x', '!'};
    if (!out || size < 12) return;
    out[0] = 0;
    if (n <= 0) return;
    int top = 0, count = 0;
    for (int i = 0; i < n; i++) if (state[i] > top) top = state[i];
    for (int i = 0; i < n; i++) count += state[i] == top;
    if (n > 99) n = 99;
    if (count > 99) count = 99;
    // Hand-rolled rather than snprintf: this runs in the render path and is five characters.
    int k = 0;
    out[k++] = glyph[top]; out[k++] = ' ';
    if (count >= 10) out[k++] = (char)('0' + count / 10);
    out[k++] = (char)('0' + count % 10); out[k++] = '/';
    if (n >= 10) out[k++] = (char)('0' + n / 10);
    out[k++] = (char)('0' + n % 10); out[k] = 0;
    if (color) {
        uint16_t c[NIXFRED_STATES] = {over(p->ink, 0, 60), over(p->ink, 0, 60), p->green, p->accent, p->yellow, p->red, p->red};
        *color = c[top];
    }
}

void nixfred_done_collapse(ht_scene_t *f, int cx, int cy, int permille, uint16_t green)
{
    if (permille < 0) permille = 0;
    if (permille > 1000) permille = 1000;
    // Ease out: fast from the rim, settling onto the dot.
    int e = 1000 - (1000 - permille) * (1000 - permille) / 1000;
    int outer = NIXFRED_RIM_OUT - (NIXFRED_RIM_OUT - 14) * e / 1000;
    int band = 8 + (14 - 8) * e / 1000;                  // the band thickens as it closes
    int inner = e >= 1000 ? 0 : outer - band;
    if (inner < 0) inner = 0;
    ht_ring(f, cx, cy, inner, outer, 0, HT_TURN, green);
}

void nixfred_failed_rim(ht_scene_t *f, uint32_t since_ms, uint16_t red)
{
    if (since_ms < NIXFRED_FAIL_FLASH_MS) {
        uint16_t c = fail_lit(since_ms) ? red : f->background;
        ht_ring(f, CX, CY, NIXFRED_RIM_IN - 14, NIXFRED_RIM_IN, 0, HT_TURN, fail_lit(since_ms) ? dim(red, 18) : f->background);
        ht_ring(f, CX, CY, NIXFRED_RIM_IN - 2, NIXFRED_RIM_OUT, 0, HT_TURN, c);
    } else {
        ht_ring(f, CX, CY, NIXFRED_RIM_IN - 14, NIXFRED_RIM_IN, 0, HT_TURN, f->background);
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, 0, HT_TURN, red);
    }
}

void nixfred_voice_rim(ht_scene_t *f, bool listening, unsigned level, unsigned step, uint16_t green,
                       uint16_t accent)
{
    if (listening) {
        if (level > 4) level = 4;
        // A faint track, and the live ring growing inward from the glass: 3 px at silence, 19 px loud.
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3, NIXFRED_RIM_OUT, 0, HT_TURN, dim(green, 25));
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3 - (int)level * 4, NIXFRED_RIM_OUT, 0, HT_TURN, green);
    } else {
        // Sending: one bright arc lapping the rim over the dim track.
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3, NIXFRED_RIM_OUT, 0, HT_TURN, dim(accent, 30));
        ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, (int)(step % NIXFRED_VOICE_STEPS) * HT_TURN / NIXFRED_VOICE_STEPS,
                HT_TURN / 5, accent);
    }
}

void nixfred_panic(ht_scene_t *f, uint32_t since_ms, int stopped, uint16_t red, uint16_t ink, uint16_t dim_ink)
{
    int permille = since_ms >= NIXFRED_PANIC_MS ? 1000 : (int)(since_ms * 1000 / NIXFRED_PANIC_MS);
    int e = 1000 - (1000 - permille) * (1000 - permille) / 1000;
    // The words first: while the rings close they are drawn in the canvas colour (the same runs, so the
    // step is a damage diff, not a reshape) and the rings, drawn after, pass over their boxes.
    char line[24] = " ";
    if (stopped >= 0) {
        int k = 0, v = stopped > 999 ? 999 : stopped;
        if (v >= 100) line[k++] = (char)('0' + v / 100);
        if (v >= 10) line[k++] = (char)('0' + v / 10 % 10);
        line[k++] = (char)('0' + v % 10);
        memcpy(line + k, v == 1 ? " agent" : " agents", v == 1 ? 7 : 8);
    }
    ht_center(f, 250, &ht_mono_28, e >= 1000 ? ink : f->background, "ALL STOPPED");
    ht_center(f, 296, &ht_mono_20, e >= 1000 ? dim_ink : f->background, line);
    // Three rings (rim, middle, inner) close together onto one point; the red dot is what stays.
    static const int from[3] = {NIXFRED_RIM_OUT, 170, 110};
    for (int i = 0; i < 3; i++) {
        int outer = from[i] - (from[i] - 18) * e / 1000;
        int inner = outer - 6;
        if (e >= 1000) { outer = 18; inner = i ? 17 : 0; } // done: one dot; the other two rest inside it
        if (inner < 0) inner = 0;
        ht_ring(f, CX, CY - 20, inner, outer, 0, HT_TURN, i == 0 || e >= 1000 ? red : dim(red, 45));
    }
}

void nixfred_plans_rim(ht_scene_t *f, int start, int span, const uint16_t *used_permille, const uint16_t *tone, int n)
{
    if (n <= 0) return;
    if (n > NIXFRED_PLANS_MAX) n = NIXFRED_PLANS_MAX;
    int slot = span / n, gap = n > 1 ? 30 : 0, arc = slot - gap;
    for (int i = 0; i < n; i++) {
        int s0 = start + i * slot + gap / 2;
        unsigned u = used_permille[i] > 1000 ? 1000 : used_permille[i];
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3, NIXFRED_RIM_OUT, s0, arc, dim(tone[i], 25));
        int fill = (int)(arc * u / 1000);
        if (fill > 0) ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, s0, fill, tone[i]);
        else ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3, NIXFRED_RIM_OUT, s0, 1, f->background);
    }
}
