// nixfred graphics: the ring/arc run and the one-colour mask run.
//
// Proves on the host, with no board: a ring covers its annulus and nothing else, an arc covers only its
// sweep (clockwise from 12 o'clock), its damage bounds hold every pixel it draws (so a partial redraw
// equals a full one), and a mask draws its alpha in one colour. With NIXFRED_SHOT_DIR set it also writes
// the composed test scenes as PPM files: a host render of the compositor, not a photo of the glass.
#include "../main/ui/habitat/terminal.h"
#include "../main/ui/habitat/nixfred_art.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t full[HT_WIDTH * HT_HEIGHT], incremental[HT_WIDTH * HT_HEIGHT];
static uint16_t scratch[HT_WIDTH * HT_HEIGHT];

static uint16_t px(const uint16_t *frame, int x, int y)
{
    uint16_t v = frame[y * HT_WIDTH + x];
    return (uint16_t)((v << 8) | (v >> 8)); // undo the panel byte order
}
static void render(const ht_scene_t *s) { ht_raster(s, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full); }

static void transition(const ht_scene_t *before, const ht_scene_t *after)
{
    ht_raster(before, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, incremental);
    ht_damage_t d;
    ht_damage(before, after, &d);
    for (int i = 0; i < d.count; i++) {
        ht_rect_t r = d.rect[i];
        assert(r.x >= 0 && r.y >= 0 && r.x + r.w <= HT_WIDTH && r.y + r.h <= HT_HEIGHT);
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

int main(void)
{
    const uint16_t red = ht_rgb(0xff0000), black = ht_rgb(0);
    ht_scene_t a, b;

    // A whole ring: inside the band is ink, the hole and outside are canvas.
    ht_scene_clear(&a, black);
    assert(ht_ring(&a, 233, 233, 200, 220, 0, HT_TURN, red));
    render(&a);
    assert(px(full, 233, 233 - 210) == red);      // 12 o'clock, mid band
    assert(px(full, 233 + 210, 233) == red);      // 3 o'clock
    assert(px(full, 233, 233 + 210) == red);      // 6 o'clock
    assert(px(full, 233 - 210, 233) == red);      // 9 o'clock
    assert(px(full, 233, 233) == black);          // the hole
    assert(px(full, 233, 233 - 150) == black);
    assert(px(full, 2, 2) == black);              // outside

    // A quarter arc from 12 to 3 o'clock, clockwise.
    ht_scene_clear(&b, black);
    assert(ht_ring(&b, 233, 233, 200, 220, 0, HT_TURN / 4, red));
    render(&b);
    assert(px(full, 233 + 148, 233 - 148) == red); // 1:30, inside the sweep
    assert(px(full, 233 + 210, 233 + 20) == black); // just past 3 o'clock
    assert(px(full, 233 - 148, 233 - 148) == black); // 10:30, outside the sweep
    assert(px(full, 233, 233 + 210) == black);
    transition(&a, &b);
    transition(&b, &a);

    // A sweep that crosses 12 o'clock (start at 10:30, 90 degrees), and a moving scanner segment.
    ht_scene_clear(&b, black);
    assert(ht_ring(&b, 233, 233, 200, 220, HT_TURN * 7 / 8, HT_TURN / 4, red));
    render(&b);
    assert(px(full, 233, 233 - 210) == red);
    assert(px(full, 233 + 210, 233) == black);
    for (int step = 0; step < 16; step++) {
        ht_scene_clear(&a, black);
        ht_ring(&a, 233, 233, 224, 231, step * HT_TURN / 16, HT_TURN / 8, red);
        ht_scene_clear(&b, black);
        ht_ring(&b, 233, 233, 224, 231, (step + 1) * HT_TURN / 16, HT_TURN / 8, red);
        transition(&a, &b);
        // The scanner's damage is its sector, not the whole face.
        ht_damage_t d;
        ht_damage(&a, &b, &d);
        assert(d.pixels < (uint32_t)HT_WIDTH * HT_HEIGHT * 3 / 4);
    }

    // A small ring anywhere (the lock shackle, the avatar disc) with inner 0 is a filled disc.
    ht_scene_clear(&a, black);
    assert(ht_ring(&a, 60, 70, 0, 12, 0, HT_TURN, red));
    render(&a);
    assert(px(full, 60, 70) == red && px(full, 60, 90) == black);

    // A mask draws its alpha in one colour.
    static uint8_t alpha[8 * 8];
    memset(alpha, 255, sizeof alpha);
    alpha[0] = 0;
    ht_scene_clear(&a, black);
    assert(ht_mask(&a, 100, 100, 8, 8, alpha, red));
    render(&a);
    assert(px(full, 100, 100) == black && px(full, 101, 100) == red && px(full, 107, 107) == red);
    assert(px(full, 108, 108) == black);
    ht_scene_clear(&b, black);
    transition(&a, &b);
    transition(&b, &a);

    // Composite proof frames for the three screens this slice draws.
    // These are the firmware's own drawing calls (nixfred_art.c), composed as ui_habitat.c composes them.
    const uint16_t accent = ht_rgb(0xc6aaef), ink = ht_rgb(0xefe7de), yellow = ht_rgb(0xe5e510),
                   crimson = ht_rgb(0xcd3131);
    ht_scene_clear(&a, black);
    nixfred_boot_face(&a, accent, ink, -1, 0);
    render(&a);
    int lit = 0;
    for (int y = 121; y < 271; y++) for (int x = 158; x < 308; x++) lit += px(full, x, y) != black;
    assert(lit > 2000); // the logo is drawn
    shot("boot-scanning");
    ht_scene_clear(&b, black);
    nixfred_boot_face(&b, accent, ink, -1, 3);
    transition(&a, &b);
    ht_scene_clear(&a, black);
    nixfred_boot_face(&a, accent, ink, 62, 0);
    render(&a);
    assert(px(full, 233 + 227, 233 + 10) == accent || px(full, 233 + 227, 233 + 10) != black); // 3 o'clock lit at 62%
    assert(px(full, 233 - 227, 233) != accent);    // 9 o'clock (75%) not yet
    shot("boot-ota-62");
    ht_scene_clear(&a, black);
    nixfred_attention(&a, false, "", yellow, crimson, ink);
    ht_center(&a, 214, &ht_mono_28, ink, "Proceed with the plan?");
    render(&a);
    assert(px(full, 233, 233 - 227) == yellow);    // waiting ring in yellow at the rim
    shot("question-waiting");
    ht_scene_clear(&b, black);
    nixfred_attention(&b, true, "", yellow, crimson, ink); // the neutral figure: no initials in a public render
    ht_center(&b, 214, &ht_mono_28, ink, "Allow: git push?");
    render(&b);
    assert(px(full, 233, 233 + 227) == crimson);   // permission ring in red
    shot("question-permission");
    transition(&a, &b);
    // The initials path still draws (host-supplied initials; never baked into a render).
    ht_scene_clear(&b, black);
    nixfred_attention(&b, true, "AB", yellow, crimson, ink);
    render(&b);
    assert(px(full, 233, 233 + 227) == crimson);
    puts("test_nixfred_ring: ok");
    return 0;
}
