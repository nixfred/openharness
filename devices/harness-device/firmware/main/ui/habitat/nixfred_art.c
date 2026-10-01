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

// ---- slice 3 ------------------------------------------------------------------------------------------
//
// Ambient, connecting, pairing, machines, swarms, cards, collisions, transitions and the plans face. The
// render path stays integer apart from placing a particle (one sinf/cosf per agent per frame, on the
// S3's FPU). Outline masks (hexagons, the warning triangle) are rasterised once, on first use, into
// static buffers that the device links into PSRAM, so they cost no internal RAM.
#include <math.h>
#include <stdio.h>
#ifdef ESP_PLATFORM
#include "esp_attr.h"
#define NF_PSRAM EXT_RAM_BSS_ATTR
#else
#define NF_PSRAM
#endif

uint16_t nixfred_state_color(uint8_t state, unsigned phase, uint16_t background, const nixfred_palette_t *p)
{
    switch (state) {
    case NIXFRED_PERMISSION:
    case NIXFRED_FAILED: return p->red;
    case NIXFRED_WAITING: return over(p->yellow, background, 55 + tri(phase) * 45 / 8);
    case NIXFRED_WORKING: return p->accent;
    case NIXFRED_DONE: return p->green;
    case NIXFRED_OFFLINE: return over(p->ink, background, 28);
    default: return over(p->ink, background, 45);
    }
}

// A point on a circle, `a` in 1/4096 turn clockwise from 12 o'clock.
static void polar(int cx, int cy, int r, int a, int *x, int *y)
{
    float t = (float)a * 6.2831853f / HT_TURN;
    *x = cx + (int)lroundf((float)r * sinf(t));
    *y = cy - (int)lroundf((float)r * cosf(t));
}

static void text_centred(ht_scene_t *f, int cx, int y, const ht_font_t *font, uint16_t ink, uint16_t bg,
                         const char *s, int max_w)
{
    if (!s || !*s) return;
    char line[HT_TEXT_BYTES];
    snprintf(line, sizeof line, "%s", s);
    int w = ht_measure(font, line);
    for (size_t n = strlen(line); w > max_w && n > 1;) { // whole letters, then "..", until it fits
        n--;
        while (n && ((uint8_t)line[n] & 0xc0) == 0x80) n--;
        if (n + 3 > sizeof line) continue;
        memcpy(line + n, "..", 3);
        w = ht_measure(font, line);
    }
    if (w <= 0) return;
    ht_text(f, cx - w / 2, y, w, font, ink, bg, line);
}

void nixfred_ambient(ht_scene_t *f, const uint8_t *state, int n, int orbit, int scan_y, int drift_x,
                     int drift_y, const char *clock, const char *line, const nixfred_palette_t *p)
{
    int cx = CX + drift_x, cy = CY + drift_y;
    uint16_t bg = f->background;
    // Grain and scanline at 6..8 percent: texture for a resting screen, never over the words.
    ht_ring(f, cx, cy, 104, 105, 0, HT_TURN, over(p->ink, bg, 6));
    ht_ring(f, cx, cy, 210, 211, 0, HT_TURN, over(p->ink, bg, 6));
    {   // the band spans the glass's chord at its row (the corners of the square are not glass)
        int dy = scan_y + 6 - CY, half = dy * dy < 228 * 228 ? (int)sqrtf((float)(228 * 228 - dy * dy)) : 0;
        if (half < 8) half = 8;
        ht_box(f, CX - half, scan_y, half * 2, 12, 6, over(p->accent, bg, 8), over(p->accent, bg, 8));
    }
    // The hub: what the particles orbit.
    ht_ring(f, cx, cy, 86, 88, 0, HT_TURN, over(p->accent, bg, 22));
    if (n > NIXFRED_AMBIENT_MAX) n = NIXFRED_AMBIENT_MAX;
    for (int k = 0; k < n; k++) {
        static const int radius[3] = {136, 164, 192};
        int r = radius[k % 3];
        // Inner orbits run faster, like a little planetary system; the caller sets the overall pace.
        int a = k * HT_TURN / (n ? n : 1) + orbit * (5 - k % 3) / 4;
        uint16_t c = nixfred_state_color(state[k], 0, bg, p);
        ht_ring(f, cx, cy, r - 1, r + 1, a - HT_TURN / 12, HT_TURN / 12, over(c, bg, 30)); // comet tail
        int x, y;
        polar(cx, cy, r, a, &x, &y);
        ht_ring(f, x, y, 0, state[k] == NIXFRED_WORKING ? 6 : 4, 0, HT_TURN, c);
    }
    const ht_font_t *big = &ht_lv_geist_med_38.base, *small = &ht_lv_geist_reg_20.base;
    text_centred(f, cx, cy - 36, big, p->ink, bg, clock && *clock ? clock : "--:--", 160);
    text_centred(f, cx, cy + 14, small, over(p->ink, bg, 55), bg, line, 150);
}

void nixfred_connect_dots(ht_scene_t *f, int retries, uint16_t accent, uint16_t dim_ink)
{
    if (retries < 0) retries = 0;
    for (int k = 0; k < NIXFRED_CONNECT_DOTS; k++) {
        bool lit = k < retries;
        ht_ring(f, CX, CY, NIXFRED_RIM_IN - 16, NIXFRED_RIM_IN - 8, k * HT_TURN / NIXFRED_CONNECT_DOTS - HT_TURN / 160,
                HT_TURN / 80, lit ? accent : dim_ink);
    }
}

// ---- outline masks ------------------------------------------------------------------------------------

typedef struct { int16_t dx, dy, w, h; uint8_t *a; } nf_mask_t;

// Antialiased strokes of `thick` px along `segs` (x0 y0 x1 y1 each, relative to the mask's centre).
static void stroke(nf_mask_t *m, uint8_t *buf, int cap, const float *segs, int nseg, float thick)
{
    float minx = 1e9f, miny = 1e9f, maxx = -1e9f, maxy = -1e9f;
    for (int i = 0; i < nseg * 2; i++) {
        float x = segs[i * 2], y = segs[i * 2 + 1];
        minx = fminf(minx, x); maxx = fmaxf(maxx, x); miny = fminf(miny, y); maxy = fmaxf(maxy, y);
    }
    float pad = thick / 2 + 2;
    int x0 = (int)floorf(minx - pad), y0 = (int)floorf(miny - pad);
    int w = (int)ceilf(maxx + pad) - x0, h = (int)ceilf(maxy + pad) - y0;
    if (w * h > cap) h = cap / w;   // never past the buffer; the sizes below are chosen so this never cuts
    m->dx = (int16_t)x0; m->dy = (int16_t)y0; m->w = (int16_t)w; m->h = (int16_t)h; m->a = buf;
    for (int py = 0; py < h; py++)
        for (int px = 0; px < w; px++) {
            float x = (float)(x0 + px) + 0.5f, y = (float)(y0 + py) + 0.5f, best = 1e9f;
            for (int s = 0; s < nseg; s++) {
                const float *g = segs + s * 4;
                float vx = g[2] - g[0], vy = g[3] - g[1], len = vx * vx + vy * vy;
                float t = len > 0 ? ((x - g[0]) * vx + (y - g[1]) * vy) / len : 0;
                t = t < 0 ? 0 : t > 1 ? 1 : t;
                float ex = g[0] + t * vx - x, ey = g[1] + t * vy - y, d = sqrtf(ex * ex + ey * ey);
                if (d < best) best = d;
            }
            float cover = thick / 2 + 0.5f - best;
            buf[py * w + px] = (uint8_t)(cover <= 0 ? 0 : cover >= 1 ? 255 : (int)(cover * 255));
        }
}

// Flat-top hexagon corners: corner i at 60*i degrees (screen y down, so i rises clockwise).
static void hex_corner(float r, int i, float *x, float *y)
{
    float t = (float)i * 1.0471976f;
    *x = r * cosf(t); *y = r * sinf(t);
}
enum { PAIR_EDGE_CAP = 132 * 116, TILE_CAP = 100 * 88, GLOW_CAP = 116 * 104, TRI_CAP = 84 * 76 };
static NF_PSRAM uint8_t pair_buf[6][PAIR_EDGE_CAP], tile_buf[TILE_CAP], glow_buf[GLOW_CAP], tri_buf[TRI_CAP];
static nf_mask_t pair_edge[6], tile_mask, glow_mask, tri_mask;
static bool masks_ready;
static void hex_segs(float r, float *segs)
{
    for (int i = 0; i < 6; i++) {
        hex_corner(r, i, &segs[i * 4], &segs[i * 4 + 1]);
        hex_corner(r, (i + 1) % 6, &segs[i * 4 + 2], &segs[i * 4 + 3]);
    }
}
static void masks_init(void)
{
    if (masks_ready) return;
    float segs[6 * 4];
    hex_segs(NIXFRED_PAIR_R, segs);
    for (int i = 0; i < 6; i++) stroke(&pair_edge[i], pair_buf[i], PAIR_EDGE_CAP, segs + i * 4, 1, 6);
    hex_segs(NIXFRED_TILE_R, segs);
    stroke(&tile_mask, tile_buf, TILE_CAP, segs, 6, 4);
    hex_segs(NIXFRED_TILE_R + 8, segs);
    stroke(&glow_mask, glow_buf, GLOW_CAP, segs, 6, 9);
    // The warning triangle with its "!" inside: three edges, the bar, and the dot (a zero-length stroke).
    const float tri[5 * 4] = {0, -34, 29.4f, 17, 29.4f, 17, -29.4f, 17, -29.4f, 17, 0, -34,
                              0, -14, 0, 3, 0, 10, 0, 10};
    stroke(&tri_mask, tri_buf, TRI_CAP, tri, 5, 5);
    masks_ready = true;
}
static void draw_mask(ht_scene_t *f, int cx, int cy, const nf_mask_t *m, uint16_t c)
{
    ht_mask(f, cx + m->dx, cy + m->dy, m->w, m->h, m->a, c);
}

void nixfred_pair_hex(ht_scene_t *f, int cx, int cy, unsigned step, bool answered, uint16_t accent)
{
    masks_init();
    // The lit edge walks clockwise, two steps an edge, with the one behind it still fading.
    int lit = (int)(step / 2 % 6), behind = (lit + 5) % 6;
    // The top edge is corners 4..5; start the walk there so the pulse begins at 12 o'clock.
    for (int i = 0; i < 6; i++) {
        int e = (i + 4) % 6;
        unsigned pct = answered ? 100 : i == lit ? 100 : i == behind ? 55 : 22;
        draw_mask(f, cx, cy, &pair_edge[e], over(accent, f->background, pct));
    }
}

void nixfred_machine_tile(ht_scene_t *f, int cx, int cy, uint16_t edge, bool glow, int load, int aux,
                          const nixfred_palette_t *p)
{
    masks_init();
    uint16_t bg = f->background;
    // The glow is always a run (canvas colour when not selected), so selecting is a recolour, not a reshape.
    draw_mask(f, cx, cy, &glow_mask, glow ? over(edge, bg, 30) : bg);
    draw_mask(f, cx, cy, &tile_mask, edge);
    enum { R0 = NIXFRED_TILE_R + 14 };
    if (load >= 0) {
        if (load > 1000) load = 1000;
        uint16_t c = load >= 950 ? p->red : load >= 800 ? 0xfd80 /* amber, as the plan arcs */ : p->accent;
        ht_ring(f, cx, cy, R0, R0 + 5, 0, HT_TURN, over(c, bg, 18));
        if (load > 0) ht_ring(f, cx, cy, R0, R0 + 5, 0, load * HT_TURN / 1000, c);
    }
    if (aux >= 0) {
        if (aux > 1000) aux = 1000;
        ht_ring(f, cx, cy, R0 + 8, R0 + 10, 0, HT_TURN, over(p->ink, bg, 14));
        if (aux > 0) ht_ring(f, cx, cy, R0 + 8, R0 + 10, 0, aux * HT_TURN / 1000, over(p->ink, bg, 70));
    }
}

void nixfred_swarm(ht_scene_t *f, int cx, int cy, int r_parent, int r_orbit, const uint8_t *child, int n,
                   unsigned phase, const nixfred_palette_t *p)
{
    uint16_t bg = f->background;
    if (n > 12) n = 12;
    int top = NIXFRED_IDLE;
    for (int i = 0; i < n; i++) if (child[i] > top) top = child[i];
    uint16_t pc = nixfred_state_color((uint8_t)top, phase, bg, p);
    // Glow is urgency: only when a child waits on someone.
    ht_ring(f, cx, cy, r_parent, r_parent + 10, 0, HT_TURN, top >= NIXFRED_WAITING ? over(pc, bg, 20) : bg);
    ht_ring(f, cx, cy, r_parent - 5, r_parent, 0, HT_TURN, pc);
    ht_ring(f, cx, cy, r_orbit, r_orbit + 1, 0, HT_TURN, over(p->ink, bg, 10)); // the orbit itself, faint
    for (int k = 0; k < n; k++) {
        int a = k * HT_TURN / n + (int)(phase * HT_TURN / (NIXFRED_PHASES * 6)), x, y;
        polar(cx, cy, r_orbit, a, &x, &y);
        uint16_t c = nixfred_state_color(child[k], phase, bg, p);
        if (child[k] == NIXFRED_WORKING)
            ht_ring(f, x, y, 11, 17, (int)(phase * HT_TURN / NIXFRED_PHASES), HT_TURN * 3 / 4, c);
        else
            ht_ring(f, x, y, child[k] == NIXFRED_IDLE || child[k] == NIXFRED_OFFLINE ? 14 : 11, 17, 0, HT_TURN, c);
    }
}

void nixfred_card(ht_scene_t *f, int y, uint16_t edge, const char *name, const char *summary, int trail,
                  uint16_t ink, uint16_t dim_ink)
{
    uint16_t bg = f->background;
    if (trail < 0) trail = 0;
    if (trail > 1000) trail = 1000;
    y -= trail * 90 / 1000;
    int x = NIXFRED_CARD_X, w = NIXFRED_CARD_W, h = NIXFRED_CARD_H;
    // The trail: three bars under a card that is leaving, fading with distance. Canvas colour at rest.
    for (int i = 0; i < 3; i++) {
        int inset = 30 + i * 30;
        ht_box(f, x + inset, y + h + 6 + i * 9, w - inset * 2, 4, 2,
               trail ? over(edge, bg, (unsigned)(48 - i * 14) * (unsigned)(1000 - trail / 2) / 1000) : bg,
               trail ? over(edge, bg, (unsigned)(48 - i * 14) * (unsigned)(1000 - trail / 2) / 1000) : bg);
    }
    uint16_t fill = over(ink, bg, 9);
    ht_box(f, x, y, w, h, 18, fill, over(edge, bg, 40));
    ht_box(f, x + 10, y + 14, 6, h - 28, 3, edge, edge);    // the state colour on the left edge
    const ht_font_t *head = &ht_lv_geist_med_28.base, *body = &ht_lv_geist_reg_20.base;
    char line[HT_TEXT_BYTES];
    snprintf(line, sizeof line, "%s", name && *name ? name : "Harness");
    ht_text(f, x + 30, y + 8, w - 48, head, ink, fill, line);
    snprintf(line, sizeof line, "%s", summary ? summary : "");
    for (char *c = line; *c; c++) if (*c == '\n') *c = ' ';
    ht_text(f, x + 30, y + 44, w - 48, body, dim_ink, fill, line[0] ? line : " ");
}

void nixfred_collision(ht_scene_t *f, const char *a, uint8_t sa, const char *b, uint8_t sb, unsigned phase,
                       const nixfred_palette_t *p)
{
    masks_init();
    uint16_t bg = f->background;
    ht_center(f, 40, &ht_mono_20, p->red, "COLLISION");
    enum { LX = 148, RX = 318, RY = 216 };
    const char *name[2] = {a, b};
    uint8_t st[2] = {sa, sb};
    for (int i = 0; i < 2; i++) {
        int x = i ? RX : LX;
        uint16_t c = nixfred_state_color(st[i], phase, bg, p);
        ht_ring(f, x, RY, 58, 68, 0, HT_TURN, over(p->red, bg, 14));   // both are in the alert's glow
        ht_ring(f, x, RY, 50, 58, 0, HT_TURN, c);
        text_centred(f, x, RY - 14, &ht_lv_geist_reg_20.base, p->ink, bg, name[i] && *name[i] ? name[i] : "?", 92);
    }
    draw_mask(f, CX, 126, &tri_mask, over(p->red, bg, 60 + tri(phase) * 40 / 8));
}

void nixfred_sweep(ht_scene_t *f, int permille, uint16_t accent)
{
    if (permille < 0) permille = 0;
    uint16_t bg = f->background;
    if (permille >= 1000) { // at rest: the same two runs, invisible, so the end of a sweep is a damage diff
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 1, NIXFRED_RIM_OUT, 0, 1, bg);
        ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 1, NIXFRED_RIM_OUT, 0, 1, bg);
        return;
    }
    int e = 1000 - (1000 - permille) * (1000 - permille) / 1000; // ease out
    int head = e * HT_TURN / 1000, seg = HT_TURN / 9;
    int tail = head - seg;
    if (tail > 0) ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 3, NIXFRED_RIM_OUT, 0, tail, over(accent, bg, 25 * (1000 - e) / 1000 + 6));
    else ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 1, NIXFRED_RIM_OUT, 0, 1, bg);
    ht_ring(f, CX, CY, NIXFRED_RIM_IN, NIXFRED_RIM_OUT, tail, seg, accent);
}

void nixfred_plans_face(ht_scene_t *f, const nixfred_plan_t *plan, int n, int pick, uint16_t ink, uint16_t dim_ink)
{
    uint16_t bg = f->background;
    if (n > NIXFRED_PLANS_MAX) n = NIXFRED_PLANS_MAX;
    if (n <= 0) {
        ht_center(f, 214, &ht_lv_geist_reg_20.base, dim_ink, "No plans yet");
        return;
    }
    // A gauge: from 7:30 clockwise to 4:30, the gap at the bottom holds the verdict.
    enum { START = HT_TURN * 5 / 8, SWEEP = HT_TURN * 3 / 4, THICK = 20, PITCH = 32 };
    for (int i = 0; i < n; i++) {
        int outer = 214 - i * PITCH, inner = outer - THICK;
        uint16_t c = plan[i].tone;
        ht_ring(f, CX, CY, outer + 2, outer + 8, START, SWEEP, i == pick ? over(c, bg, 30) : bg); // next: glow
        ht_ring(f, CX, CY, inner, outer, START, SWEEP, over(c, bg, 16));
        int u = plan[i].used > 1000 ? 1000 : plan[i].used, fill = SWEEP * u / 1000;
        ht_ring(f, CX, CY, inner, outer, START, fill > 0 ? fill : 1, fill > 0 ? c : over(c, bg, 16));
    }
    // The centre legend, one line per plan, outermost first; the next plan carries the marker.
    const ht_font_t *font = n > 3 ? &ht_mono_16 : &ht_mono_20;
    int lh = font->height + 4, top = CY - n * lh / 2;
    for (int i = 0; i < n; i++) {
        char name[8], line[32];
        int k = 0;
        for (; k < 6 && plan[i].name[k]; k++) name[k] = (char)(plan[i].name[k] >= 'a' && plan[i].name[k] <= 'z' ? plan[i].name[k] - 32 : plan[i].name[k]);
        name[k] = 0;
        int pct = (plan[i].used + 5) / 10, bank = plan[i].banked >= 0 ? (plan[i].banked + 5) / 10 : -((-plan[i].banked + 5) / 10);
        snprintf(line, sizeof line, "%c%-6s%3d%% %+d", i == pick ? '>' : ' ', name, pct > 999 ? 999 : pct, bank);
        int w = ht_measure(font, line);
        ht_text(f, CX - w / 2, top + i * lh, w, font, i == pick ? plan[i].tone : ink, bg, line);
    }
    if (pick >= 0 && pick < n) {
        char line[24], name[10];
        snprintf(name, sizeof name, "%s", plan[pick].name);
        for (char *c = name; *c; c++) if (*c >= 'a' && *c <= 'z') *c = (char)(*c - 32);
        snprintf(line, sizeof line, "NEXT: %s", name);
        ht_center(f, 404, &ht_mono_20, plan[pick].tone, line);
    }
    (void)ink;
}

void nixfred_label(ht_scene_t *f, int cx, int y, const ht_font_t *font, uint16_t ink, const char *text, int max_w)
{
    text_centred(f, cx, y, font, ink, f->background, text, max_w);
}

void nixfred_hold_rim(ht_scene_t *f, int permille, uint16_t accent)
{
    if (permille < 0) permille = 0;
    if (permille > 1000) permille = 1000;
    // The track says "keep holding, this is how far it goes"; the fill is how far it has got.
    ht_ring(f, CX, CY, NIXFRED_RIM_OUT - 4, NIXFRED_RIM_OUT, 0, HT_TURN, dim(accent, 30));
    int sweep = permille * HT_TURN / 1000;
    ht_ring(f, CX, CY, NIXFRED_RIM_IN - 6, NIXFRED_RIM_OUT, 0, sweep > 0 ? sweep : 1,
            sweep > 0 ? accent : dim(accent, 30));
}
