// nixfred graphics, slice 3: ambient face, connecting dots, pairing hexagon, machine tiles, swarm ring of
// rings, notification card, collision card, transition sweep and the plans face.
//
// Proves what the firmware relies on and, with NIXFRED_SHOT_DIR set, writes each face as a PPM: a HOST
// render of the compositor's own drawing calls, not a photo of the glass.
//
//   - every animation step keeps its run count, so ht_damage stays on its banded path and a partial
//     redraw equals a full one (the ambient orbit and scan band, the pairing pulse, the card's slide and
//     dismiss, the swarm phase, the sweep through to rest);
//   - each face fits the scene's run budget with room to spare, nothing lands outside the glass;
//   - the burn-in drift moves the whole ambient face by exactly the drift.
#include "../main/ui/habitat/terminal.h"
#include "../main/ui/habitat/nixfred_art.h"
#include "../main/ui/habitat/focus_faces.h"
#include "../main/ui/habitat/character.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t full[HT_WIDTH * HT_HEIGHT], incremental[HT_WIDTH * HT_HEIGHT], scratch[HT_WIDTH * HT_HEIGHT];
static uint16_t shifted[HT_WIDTH * HT_HEIGHT];

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

int main(void)
{
    BLACK = ht_rgb(0); INK = ht_rgb(0xefe7de); DIMI = ht_rgb(0xada6ad);
    P = (nixfred_palette_t){.accent = ht_rgb(0xc6aaef), .yellow = ht_rgb(0xe5e510), .red = ht_rgb(0xcd3131),
                            .green = ht_rgb(0x0dbc79), .ink = INK};
    ht_scene_t a, b;

    // AMBIENT: six agents (three working), orbit and scan band moving; same runs every frame.
    const uint8_t six[6] = {NIXFRED_WORKING, NIXFRED_IDLE, NIXFRED_WORKING, NIXFRED_DONE, NIXFRED_WORKING,
                            NIXFRED_OFFLINE};
    ht_scene_clear(&a, BLACK);
    nixfred_ambient(&a, six, 6, 0, 40, 0, 0, "14:07", "3 working", &P);
    assert(a.count <= HT_RUNS - 12);
    for (int step = 1; step < 40; step++) {
        ht_scene_clear(&b, BLACK);
        nixfred_ambient(&b, six, 6, step * 37, (40 + step * 11) % HT_HEIGHT, 0, 0, "14:07", "3 working", &P);
        transition(&a, &b);
        a = b;
    }
    ht_scene_clear(&a, BLACK);
    nixfred_ambient(&a, six, 6, 300, 150, 0, 0, "14:07", "3 working", &P);
    render(&a);
    inside_glass();
    shot("ambient");
    memcpy(shifted, full, sizeof full);
    // Drift: the face moved by (2, -1) is the same picture moved by (2, -1). The scan band is a full-width
    // row and does not drift; compare away from it.
    ht_scene_clear(&b, BLACK);
    nixfred_ambient(&b, six, 6, 300, 150, 2, -1, "14:07", "3 working", &P);
    render(&b);
    for (int y = 200; y < 300; y++)
        for (int x = 100; x < 360; x++) assert(px(full, x + 2, y - 1) == px(shifted, x, y));
    // An empty fleet still has a clock and the hub.
    ht_scene_clear(&a, BLACK);
    nixfred_ambient(&a, NULL, 0, 0, 0, 0, 0, "", "no agents", &P);
    render(&a);

    // CONNECTING: the dotted ring draws itself one dot per retry; constant run count.
    ht_scene_clear(&a, BLACK);
    nixfred_boot_face(&a, P.accent, INK, -1, 0);
    nixfred_connect_dots(&a, 0, P.accent, ht_rgb(0x262626));
    for (int r = 1; r <= 30; r++) {
        ht_scene_clear(&b, BLACK);
        nixfred_boot_face(&b, P.accent, INK, -1, r);
        nixfred_connect_dots(&b, r, P.accent, ht_rgb(0x262626));
        transition(&a, &b);
        a = b;
        if (r == 7) {
            ht_center(&b, 352, &ht_mono_20, DIMI, "retry 7");
            render(&b);
            inside_glass();
            shot("connecting");
        }
    }

    // PAIRING: hexagon edges pulse in turn; answered snaps all six solid.
    ht_scene_clear(&a, BLACK);
    nixfred_pair_hex(&a, 233, 226, 0, false, P.accent);
    for (unsigned st = 1; st < 14; st++) {
        ht_scene_clear(&b, BLACK);
        nixfred_pair_hex(&b, 233, 226, st, false, P.accent);
        transition(&a, &b);
        a = b;
    }
    ht_scene_clear(&a, BLACK);
    nixfred_pair_hex(&a, 233, 226, 0, false, P.accent);
    ht_center(&a, 72, &ht_mono_20, DIMI, "PAIR DEVICE");
    ht_center(&a, 206, &ht_pixel_40, INK, "482 913");
    render(&a);
    assert(px(full, 233, 226 - 102) == P.accent);   // the top edge is the lit one at step 0
    inside_glass();
    shot("pairing");
    ht_scene_clear(&b, BLACK);
    nixfred_pair_hex(&b, 233, 226, 0, true, P.accent);
    ht_center(&b, 72, &ht_mono_20, DIMI, "PAIR DEVICE");
    ht_center(&b, 206, &ht_pixel_40, INK, "482 913");
    transition(&a, &b);
    assert(px(full, 233, 226 + 102) == P.accent);   // answered: the bottom edge is solid too

    // MACHINES: four hexagon tiles; this machine carries load and VRAM arcs, the selected one glows.
    ht_scene_clear(&a, BLACK);
    centre(&a, 24, &ht_lv_inter_20.base, DIMI, "machines");
    const char *names[4] = {"workstation", "laptop", "build-box", "mini"};
    const int cxs[4] = {150, 316, 150, 316}, cys[4] = {140, 140, 290, 290};
    for (int i = 0; i < 4; i++) {
        uint16_t edge = i == 3 ? DIMI : P.accent;
        nixfred_machine_tile(&a, cxs[i], cys[i], edge, i == 0, i == 0 ? 640 : i == 1 ? 870 : -1, i == 0 ? 410 : i == 1 ? 780 : -1, &P);
        int w = ht_measure(&ht_mono_16, names[i]);
        ht_text(&a, cxs[i] - w / 2, cys[i] + 60, w, &ht_mono_16, INK, BLACK, names[i]);
    }
    assert(a.count <= HT_RUNS);
    render(&a);
    inside_glass();
    shot("machines");

    // SWARM: parent in the centre, nine children orbiting in their own states; phase steps are diffs.
    const uint8_t kids[9] = {NIXFRED_WORKING, NIXFRED_WAITING, NIXFRED_IDLE, NIXFRED_WORKING, NIXFRED_DONE,
                             NIXFRED_OFFLINE, NIXFRED_WORKING, NIXFRED_IDLE, NIXFRED_DONE};
    ht_scene_clear(&a, BLACK);
    nixfred_swarm(&a, 233, 233, 116, 176, kids, 9, 0, &P);
    for (unsigned ph = 1; ph < 2 * NIXFRED_PHASES; ph++) {
        ht_scene_clear(&b, BLACK);
        nixfred_swarm(&b, 233, 233, 116, 176, kids, 9, ph, &P);
        transition(&a, &b);
        a = b;
    }
    ht_scene_clear(&a, BLACK);
    nixfred_swarm(&a, 233, 233, 116, 176, kids, 9, 3, &P);
    centre(&a, 24, &ht_lv_inter_20.base, DIMI, "tabs");
    centre(&a, 214, &ht_lv_inter_30.base, P.accent, "release-train");
    render(&a);
    inside_glass();
    shot("swarm");

    // NOTIFICATION CARD over the home face: slides up from the rim, holds, then a swipe up dismisses it
    // with a trail. Every frame of both motions is the same run count.
    home(&a);
    int face = a.count;
    nixfred_card(&a, 466, P.green, "docs-writer", "Rewrote the install guide, 4 files.", 0, INK, DIMI);
    assert(a.count - face == 7 && a.count <= HT_RUNS);
    for (int y = 446; y >= 300; y -= 20) {
        home(&b);
        nixfred_card(&b, y, P.green, "docs-writer", "Rewrote the install guide, 4 files.", 0, INK, DIMI);
        transition(&a, &b);
        a = b;
    }
    render(&a);
    inside_glass();
    shot("card");
    for (int t = 100; t <= 1000; t += 150) {
        home(&b);
        nixfred_card(&b, 300, P.green, "docs-writer", "Rewrote the install guide, 4 files.", t, INK, DIMI);
        transition(&a, &b);
        a = b;
        if (t == 400) shot("card-dismiss");
    }

    // LANE TAG under the agent name (nf_home_extras: a dim ring at y 302 with the lane's letter), with the
    // fleet rim and plan arcs as the home face draws them.
    home(&a);
    ht_ring(&a, 233, 302, 10, 12, 0, HT_TURN, DIMI);
    ht_text(&a, 233 - ht_mono_16.width / 2, 302 - ht_mono_16.height / 2, ht_mono_16.width, &ht_mono_16, INK, BLACK, "P");
    {
        const uint8_t st[5] = {NIXFRED_WORKING, NIXFRED_IDLE, NIXFRED_WORKING, NIXFRED_DONE, NIXFRED_IDLE};
        nixfred_fleet_rim(&a, st, 5, HT_TURN * 3 / 4, 4, UINT32_MAX, &P);
        const uint16_t used[3] = {620, 910, 140}, tone[3] = {P.accent, ht_rgb(0xffb000), P.green};
        nixfred_plans_rim(&a, HT_TURN * 3 / 8 + 60, HT_TURN / 4 - 120, used, tone, 3);
    }
    assert(a.count <= HT_RUNS);
    render(&a);
    inside_glass();
    shot("home-lane");

    // COLLISION: two rings side by side under a warning triangle.
    ht_scene_clear(&a, BLACK);
    nixfred_collision(&a, "api-server", NIXFRED_WORKING, "migrations", NIXFRED_WAITING, 0, &P);
    for (unsigned ph = 1; ph < NIXFRED_PHASES; ph++) {
        ht_scene_clear(&b, BLACK);
        nixfred_collision(&b, "api-server", NIXFRED_WORKING, "migrations", NIXFRED_WAITING, ph, &P);
        transition(&a, &b);
        a = b;
    }
    ht_scene_clear(&a, BLACK);
    nixfred_collision(&a, "api-server", NIXFRED_WORKING, "migrations", NIXFRED_WAITING, 8, &P);
    centre(&a, 318, &ht_lv_inter_20.base, INK, "Both edited src/db/schema.ts");
    centre(&a, 346, &ht_lv_inter_20.base, DIMI, "inside the last hour");
    render(&a);
    assert(px(full, 148, 216 - 54) == P.accent);
    inside_glass();
    shot("collision");

    // TRANSITION: the sweep laps once over the next face and comes to rest as invisible runs.
    home(&a);
    nixfred_sweep(&a, 0, P.accent);
    for (int pm = 100; pm <= 1100; pm += 100) {
        home(&b);
        nixfred_sweep(&b, pm, P.accent);
        transition(&a, &b);
        a = b;
        if (pm == 500) shot("transition");
    }

    // PLANS: one gauge per plan, the next plan glowing, legend in the centre.
    nixfred_plan_t plans[4] = {
        {"claude", 620, 80, 0}, {"codex", 910, -120, 0}, {"kimi", 140, 310, 0}, {"grok", 400, 0, 0}};
    plans[0].tone = ht_rgb(0xc6aaef); plans[1].tone = ht_rgb(0xffb000); plans[2].tone = P.green; plans[3].tone = P.accent;
    for (int n = 1; n <= 4; n++) {
        ht_scene_clear(&a, BLACK);
        nixfred_plans_face(&a, plans, n, 2 < n ? 2 : 0, INK, DIMI);
        assert(a.count <= HT_RUNS - 4);
        render(&a);
        inside_glass();
    }
    shot("plans");
    ht_scene_clear(&a, BLACK);
    nixfred_plans_face(&a, plans, 0, -1, INK, DIMI);
    render(&a);

    puts("nixfred slice 3: PASS (ambient orbit+drift, connecting dots, pairing hexagon, machine tiles, swarm, card slide+dismiss, collision, sweep, plans)");
    return 0;
}
