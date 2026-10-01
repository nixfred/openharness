// nixfred slice 4: the hold feedback ring (hold anywhere for the session list).
//
// With NIXFRED_SHOT_DIR set it writes each frame as a PPM: a HOST render of the compositor's own drawing
// calls over the Focus home face and the question face, not a photo of the glass. Proves:
//   - every step of the fill keeps the run count, so a partial redraw equals a full one;
//   - the fill grows clockwise from 12 o'clock and only as far as the hold has got;
//   - nothing lands outside the glass and the face fits the run budget with the ring on it.
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
// Nothing outside the round glass (a 4 px margin for antialiasing at the rim).
static void inside_glass(void)
{
    for (int y = 0; y < HT_HEIGHT; y += 3)
        for (int x = 0; x < HT_WIDTH; x += 3) {
            int dx = x - 233, dy = y - 233;
            if (dx * dx + dy * dy > 236 * 236) assert(px(full, x, y) == 0);
        }
}

static void centre(ht_scene_t *f, int y, const ht_font_t *font, uint16_t ink, const char *t)
{
    int w = ht_measure(font, t);
    ht_text(f, 233 - w / 2, y, w, font, ink, f->background, t);
}
static nixfred_palette_t P;
static uint16_t INK, DIMI, BLACK;

static void home(ht_scene_t *f)
{
    ht_character_t c = {0};
    assert(ht_character_select(&c, HT_CHARACTER_FOCUS));
    ht_scene_clear(f, BLACK);
    ht_character_face_t face = {.recipient = "api-server", .status = "", .hint = "", .tab = "main",
        .engine = "claude", .activity = "Working", .elapsed = 42, .detail = "", .mood = HT_CHARACTER_WORKING,
        .ink = INK, .foreground = INK, .dim = DIMI, .primary_title = true, .roomy_reading = true};
    ht_character_face(f, &c, &face, P.accent, NULL);
}

// A pixel on the fill band (radius 225) at `turn` permille of the lap, clockwise from 12 o'clock.
static uint16_t at(int turn)
{
    static const int pts[][2] = {{233, 8}, {458, 233}, {233, 458}, {8, 233}}; // 0, 250, 500, 750
    return px(full, pts[turn / 250][0], pts[turn / 250][1]);
}

int main(void)
{
    BLACK = ht_rgb(0); INK = ht_rgb(0xefe7de); DIMI = ht_rgb(0xada6ad);
    P = (nixfred_palette_t){.accent = ht_rgb(0xc6aaef), .yellow = ht_rgb(0xe5e510), .red = ht_rgb(0xcd3131),
                            .green = ht_rgb(0x0dbc79), .ink = INK};
    ht_scene_t a, b;
    const uint8_t st[5] = {NIXFRED_WORKING, NIXFRED_IDLE, NIXFRED_WAITING, NIXFRED_DONE, NIXFRED_IDLE};

    // HOME: the fleet rim under it, the ring filling over 20 steps; every step a damage diff.
    home(&a);
    nixfred_fleet_rim(&a, st, 5, HT_TURN * 3 / 4, 4, UINT32_MAX, &P);
    nixfred_hold_rim(&a, 0, P.accent);
    int runs = a.count;
    assert(runs <= HT_RUNS);
    for (int pm = 50; pm <= 1000; pm += 50) {
        home(&b);
        nixfred_fleet_rim(&b, st, 5, HT_TURN * 3 / 4, 4, UINT32_MAX, &P);
        nixfred_hold_rim(&b, pm, P.accent);
        assert(b.count == runs);
        transition(&a, &b);
        inside_glass();
        // Filled up to where the hold has got, and not past it.
        for (int t = 0; t < 1000; t += 250) {
            if (t + 40 < pm) assert(at(t) == P.accent);
            else if (t > pm + 40) assert(at(t) != P.accent);
        }
        if (pm == 250) shot("hold-25");
        if (pm == 600) shot("hold-60");
        if (pm == 950) shot("hold-95");
        a = b;
    }
    // Clamped either side, still two runs.
    ht_scene_clear(&a, BLACK); nixfred_hold_rim(&a, -5, P.accent); assert(a.count == 2);
    ht_scene_clear(&a, BLACK); nixfred_hold_rim(&a, 4000, P.accent); assert(a.count == 2);
    render(&a); assert(at(750) == P.accent);

    // QUESTION: the ring over a permission prompt. Drawing it answers nothing (that is the touch layer's
    // rule, tested in test_touch_ui); this shows Fred the same feedback on the red ring.
    ht_scene_clear(&a, BLACK);
    nixfred_attention(&a, true, "", P.yellow, P.red, INK);
    centre(&a, 200, &ht_lv_geist_reg_20.base, INK, "Run the migration?");
    nixfred_hold_rim(&a, 600, P.accent);
    assert(a.count <= HT_RUNS);
    render(&a);
    inside_glass();
    assert(at(250) == P.accent);
    shot("hold-question");
    puts("nixfred slice 4: PASS (hold ring fills clockwise, constant runs, partial redraw equals full, inside the glass)");
    return 0;
}
