// nixfred slice 5: the hub that a hold anywhere opens.
//
// With NIXFRED_SHOT_DIR set it writes frames as PPM: a HOST render of the compositor's own drawing calls,
// not a photo of the glass. Proves the bloom keeps its run count, partial redraw equals full, the live
// readouts are drawn, glow follows urgency, and nothing leaves the glass.
#include "../main/ui/habitat/terminal.h"
#include "../main/ui/habitat/nixfred_art.h"
#include "../main/ui/habitat/character.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t full[HT_WIDTH * HT_HEIGHT], incremental[HT_WIDTH * HT_HEIGHT], scratch[HT_WIDTH * HT_HEIGHT];

static uint16_t px(const uint16_t *frame, int x, int y)
{
    uint16_t v = frame[y * HT_WIDTH + x];
    return (uint16_t)((v << 8) | (v >> 8));
}
static void render(const ht_scene_t *s) { ht_raster(s, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full); }
static void transition(const ht_scene_t *before, const ht_scene_t *after)
{
    assert(before->count == after->count);
    ht_raster(before, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, incremental);
    ht_damage_t d;
    ht_damage(before, after, &d);
    for (int i = 0; i < d.count; i++) {
        ht_rect_t r = d.rect[i];
        ht_raster(after, r, scratch);
        for (int y = 0; y < r.h; y++)
            memcpy(incremental + (r.y + y) * HT_WIDTH + r.x, scratch + y * r.w, (size_t)r.w * 2);
    }
    render(after);
    assert(memcmp(incremental, full, sizeof full) == 0);
}
static void shot(const char *name)
{
    const char *dir = getenv("NIXFRED_SHOT_DIR");
    if (!dir) return;
    char path[512];
    snprintf(path, sizeof path, "%s/%s.ppm", dir, name);
    FILE *f = fopen(path, "wb");
    assert(f);
    fprintf(f, "P6\n%d %d\n255\n", HT_WIDTH, HT_HEIGHT);
    for (int y = 0; y < HT_HEIGHT; y++)
        for (int x = 0; x < HT_WIDTH; x++) {
            uint16_t v = px(full, x, y);
            unsigned char rgb[3] = {(unsigned char)((v >> 11) << 3), (unsigned char)(((v >> 5) & 63) << 2),
                                    (unsigned char)((v & 31) << 3)};
            fwrite(rgb, 1, 3, f);
        }
    fclose(f);
}
static void inside_glass(void)
{
    for (int y = 0; y < HT_HEIGHT; y += 3)
        for (int x = 0; x < HT_WIDTH; x += 3) {
            int dx = x - 233, dy = y - 233;
            if (dx * dx + dy * dy > 236 * 236) assert(px(full, x, y) == 0);
        }
}

static nixfred_palette_t P;

static uint16_t INK, DIMI, BLACK;

// The hub as the firmware fills it: SESSIONS, PLANS, MACHINES, SWARMS, INBOX.
static int wedges(nixfred_hub_wedge_t *w, bool urgent, bool empty)
{
    memset(w, 0, sizeof *w * NIXFRED_HUB_MAX);
    const char *labels[] = {"SESSIONS", "PLANS", "MACHINES", "SWARMS", "INBOX"};
    for (int i = 0; i < 5; i++) {
        w[i].glyph = (uint8_t)i; w[i].label = labels[i]; w[i].tone = P.accent; w[i].live = true;
        w[i].arc = w[i].arc2 = -1; w[i].arc_tone = P.accent;
    }
    if (empty) {
        snprintf(w[0].line, sizeof w[0].line, "no agents");
        snprintf(w[1].line, sizeof w[1].line, "no data");
        snprintf(w[2].line, sizeof w[2].line, "1 host");
        snprintf(w[3].line, sizeof w[3].line, "0 tabs");
        snprintf(w[4].line, sizeof w[4].line, "all read"); w[4].live = false;
        return 5;
    }
    snprintf(w[0].line, sizeof w[0].line, urgent ? "2/9 need you" : "9 agents");
    if (urgent) { w[0].tone = P.red; w[0].glow = true; }
    snprintf(w[1].line, sizeof w[1].line, "KIMI +8%%"); w[1].arc = 420; w[1].arc_tone = P.green;
    snprintf(w[2].line, sizeof w[2].line, "load 63%%"); w[2].arc = 630; w[2].arc2 = 380;
    snprintf(w[3].line, sizeof w[3].line, "3 tabs");
    snprintf(w[4].line, sizeof w[4].line, urgent ? "4 unread" : "all read");
    if (urgent) { w[4].glow = true; w[4].tone = P.yellow; }
    return 5;
}
static bool has_text(const ht_scene_t *sc, const char *t)
{
    for (int i = 0; i < sc->count; i++) if (!strcmp(sc->runs[i].text, t)) return true;
    return false;
}
static void hub(ht_scene_t *f, int bloom, int pressed, bool urgent, bool empty)
{
    nixfred_hub_wedge_t w[NIXFRED_HUB_MAX];
    int n = wedges(w, urgent, empty);
    ht_scene_clear(f, BLACK);
    // Slice 6: the centre is the suggested next action (a permission when urgent, the banked plan when not).
    nixfred_hub(f, w, n, bloom, pressed, urgent ? 1 : -1, empty ? "" : "14:07", empty ? "" : urgent ? "Answer Lee" : "Use Kimi",
                empty ? "" : urgent ? "Run the migration?" : "+36% banked", urgent ? P.red : P.green, urgent, &P);
}

int main(void)
{
    BLACK = ht_rgb(0); INK = ht_rgb(0xefe7de); DIMI = ht_rgb(0xada6ad);
    P = (nixfred_palette_t){.accent = ht_rgb(0xc6aaef), .yellow = ht_rgb(0xe5e510), .red = ht_rgb(0xcd3131),
                            .green = ht_rgb(0x0dbc79), .ink = INK};
    ht_scene_t a, b;
    // The bloom: every frame keeps the run count (room left for the view sweep and the hold ring), every
    // frame is a damage diff, nothing leaves the glass.
    hub(&a, 0, -1, false, false);
    int runs = a.count;
    assert(runs + 4 <= HT_RUNS);
    render(&a); inside_glass();
    for (int pm = 40; pm <= 1000; pm += 40) {
        hub(&b, pm, -1, false, false);
        assert(b.count == runs);
        transition(&a, &b);
        inside_glass();
        if (pm == 360) shot("hub-bloom-36");
        a = b;
    }
    // Settled: every label and every live line is drawn, the clock and the summary in the middle.
    const char *words[] = {"SESSIONS", "PLANS", "MACHINES", "SWARMS", "INBOX", "9 agents", "KIMI +8%", "load 63%",
                           "3 tabs", "all read", "14:07", "Use Kimi", "+36% banked"};
    for (unsigned i = 0; i < sizeof words / sizeof *words; i++) assert(has_text(&a, words[i]));
    shot("hub-settled");
    // At rest before the bloom the wedges are not yet lit: the glass at a wedge's label is canvas.
    hub(&b, 0, -1, false, false); render(&b);
    int x, y; nixfred_hub_centre(0, 5, &x, &y); assert(x == 233 && y == 233 - NIXFRED_HUB_R);
    for (int i = 0; i < 5; i++) {
        nixfred_hub_centre(i, 5, &x, &y);
        int d2 = (x - 233) * (x - 233) + (y - 233) * (y - 233);
        assert(d2 > (NIXFRED_HUB_R - 2) * (NIXFRED_HUB_R - 2) && d2 < (NIXFRED_HUB_R + 2) * (NIXFRED_HUB_R + 2));
        // Tap targets: inside the glass, clear of the centre, clear of each other.
        assert(x - NIXFRED_HUB_HIT_W / 2 >= 0 && x + NIXFRED_HUB_HIT_W / 2 <= HT_WIDTH);
        assert(y - NIXFRED_HUB_HIT_H / 2 >= 0 && y + NIXFRED_HUB_HIT_H / 2 <= HT_HEIGHT);
    }
    // Pressing a wedge and live updates (urgent readouts) are damage diffs of the same run count.
    hub(&b, 1000, 2, false, false); assert(b.count == runs); transition(&a, &b); a = b;
    hub(&b, 1000, -1, true, false); assert(b.count == runs); transition(&a, &b);
    assert(has_text(&b, "2/9 need you") && has_text(&b, "4 unread") && has_text(&b, "Answer Lee"));
    shot("hub-urgent");
    // Glow is urgency: the SESSIONS wedge's band inside the rim is red when someone waits on a permission,
    // and canvas when nobody does.
    render(&b); assert(px(full, 233, 233 - (NIXFRED_RIM_IN - 8)) != 0);
    hub(&a, 1000, -1, false, false); render(&a); assert(px(full, 233, 233 - (NIXFRED_RIM_IN - 8)) == 0);
    // Nothing known yet (no plans, no fleet frame, nothing unread): same runs, dim lines, no clock.
    hub(&b, 1000, -1, false, true); assert(b.count == runs); render(&b); inside_glass();
    assert(has_text(&b, "no data") && !has_text(&b, "14:07") && has_text(&b, "close"));
    shot("hub-empty");
    puts("nixfred slice 5: PASS (hub bloom keeps its runs, partial redraw equals full, live readouts, inside the glass)");
    return 0;
}
