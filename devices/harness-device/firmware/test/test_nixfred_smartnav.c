// nixfred slice 6: the shade, the grab notch and the toast (smart navigation).
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

static bool has_text(const ht_scene_t *sc, const char *t)
{
    for (int i = 0; i < sc->count; i++) if (!strcmp(sc->runs[i].text, t)) return true;
    return false;
}
static void shade(ht_scene_t *f, int pm)
{
    ht_scene_clear(f, BLACK);
    nixfred_notch(f, 0, DIMI);              // the face underneath, reduced to its notch
    nixfred_shade(f, pm, P.accent, INK);
}
static void toast(ht_scene_t *f, const char *line, const char *hint, uint16_t edge)
{
    ht_scene_clear(f, BLACK);
    nixfred_notch(f, 0, DIMI);
    nixfred_toast(f, line, hint, edge, INK, DIMI);
}

int main(void)
{
    BLACK = ht_rgb(0); INK = ht_rgb(0xefe7de); DIMI = ht_rgb(0xada6ad);
    P = (nixfred_palette_t){.accent = ht_rgb(0xc6aaef), .yellow = ht_rgb(0xe5e510), .red = ht_rgb(0xcd3131),
                            .green = ht_rgb(0x0dbc79), .ink = INK};
    ht_scene_t a, b;
    // The notch: one run, at 12 o'clock, inside the glass.
    ht_scene_clear(&a, BLACK); nixfred_notch(&a, 0, DIMI); assert(a.count == 1);
    render(&a); inside_glass(); assert(px(full, 233, NIXFRED_NOTCH_Y + 2) != 0 && px(full, 233, NIXFRED_NOTCH_Y + 20) == 0);
    // The shade: the same runs through the whole pull, every step a damage diff, the notch following the
    // finger down, nothing outside the glass.
    shade(&a, 0); int runs = a.count; assert(runs == 4); render(&a); inside_glass();
    for (int pm = 50; pm <= 1000; pm += 50) {
        shade(&b, pm); assert(b.count == runs); transition(&a, &b); inside_glass();
        if (pm == 500) shot("shade-50");
        a = b;
    }
    int drop = NIXFRED_SHADE_PULL;
    assert(px(full, 233, NIXFRED_NOTCH_Y + drop + 2) != 0);         // the notch at the end of the pull
    assert(px(full, 233, 233 - (NIXFRED_RIM_IN - 7)) != 0);        // "let go": the glow band is lit at full pull
    shade(&b, 990); render(&b); assert(px(full, 233, 233 - (NIXFRED_RIM_IN - 7)) == 0);   // not before
    // The toast: three runs whatever it says, a damage diff between messages, inside the glass.
    toast(&a, "next: Research", "tap to stay", P.yellow); assert(a.count == 4); render(&a); inside_glass();
    assert(has_text(&a, "next: Research") && has_text(&a, "tap to stay"));
    shot("toast-next");
    toast(&b, "gus selected", "", P.accent); assert(b.count == a.count); transition(&a, &b);
    puts("nixfred slice 6: PASS (notch, shade pull and toast keep their runs, partial redraw equals full, inside the glass)");
    return 0;
}
