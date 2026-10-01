// nixfred graphics, slice 2: the fleet rim, done, failed, voice, panic and plan arcs.
//
// Composes each face the way ui_habitat.c does (the real skin face from character.c, then the nixfred
// runs on top), proves the invariants the firmware relies on, and with NIXFRED_SHOT_DIR set writes each
// scene as a PPM: a HOST render of the compositor, not a photo of the glass.
//
//   - an animation step (phase, flash, level, sweep) never changes the run count, so ht_damage stays on
//     its banded path and a partial redraw equals a full one;
//   - the rim stays inside the glass, the busiest agent sits at 12 o'clock;
//   - the face plus a nine-agent rim fits the scene's run budget on every skin checked.
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

static const nixfred_palette_t pal = {0};
static nixfred_palette_t P;
static uint16_t INK, DIMI, BLACK;

// The home face as render_home builds it (the fields that change the layout), for one skin.
static void home(ht_scene_t *f, ht_character_t *c, const char *recap)
{
    ht_scene_clear(f, c->id == HT_CHARACTER_FOCUS ? BLACK : ht_rgb(0x181818));
    ht_character_face_t face = {.recipient = "openharness", .status = "", .hint = "", .tab = "main",
        .engine = "claude", .activity = "Working", .elapsed = 42, .detail = "", .mood = HT_CHARACTER_WORKING,
        .ink = INK, .foreground = INK, .dim = DIMI, .primary_title = true, .roomy_reading = true};
    ht_character_face(f, c, &face, P.accent, recap);
}
// What ui_habitat.c appends to the home face: the fleet rim over the top of the glass (the bottom
// quarter is the plans' sector) and the fleet summary under the top caption.
enum { FLEET_SPAN = HT_TURN * 3 / 4 };
static void fleet(ht_scene_t *f, const uint8_t *st, int n, unsigned phase, uint32_t fail_ms)
{
    nixfred_fleet_rim(f, st, n, FLEET_SPAN, phase, fail_ms, &P);
}
// With the summary line as nf_home_rim draws it when no recap owns the band (y 318 Focus, 350 creature).
static void fleet_summary(ht_scene_t *f, const uint8_t *st, int n, bool focus)
{
    char line[16]; uint16_t ink = INK;
    nixfred_fleet_summary(line, sizeof line, &ink, st, n, &P);
    ht_center(f, focus ? 318 : 350, &ht_mono_20, ink, line);
}

int main(void)
{
    (void)pal;
    BLACK = ht_rgb(0); INK = ht_rgb(0xefe7de); DIMI = ht_rgb(0xada6ad);
    P = (nixfred_palette_t){.accent = ht_rgb(0xc6aaef), .yellow = ht_rgb(0xe5e510), .red = ht_rgb(0xcd3131),
                            .green = ht_rgb(0x0dbc79), .ink = INK};
    ht_scene_t a, b;

    // Nine agents, as Fred runs them: one permission, two waiting, three working, one done, one idle,
    // one offline, in the host's (unsorted) order.
    const uint8_t nine[9] = {NIXFRED_WORKING, NIXFRED_IDLE, NIXFRED_WAITING, NIXFRED_DONE, NIXFRED_WORKING,
                             NIXFRED_PERMISSION, NIXFRED_OFFLINE, NIXFRED_WAITING, NIXFRED_WORKING};
    char sum[16]; uint16_t sc = 0;
    nixfred_fleet_summary(sum, sizeof sum, &sc, nine, 9, &P);
    assert(!strcmp(sum, "! 1/9") && sc == P.red);
    const uint8_t two_waiting[4] = {NIXFRED_WAITING, NIXFRED_WORKING, NIXFRED_WAITING, NIXFRED_IDLE};
    nixfred_fleet_summary(sum, sizeof sum, &sc, two_waiting, 4, &P);
    assert(!strcmp(sum, "? 2/4") && sc == P.yellow);

    const ht_character_id_t skins[] = {HT_CHARACTER_FOCUS, HT_CHARACTER_TIM, HT_CHARACTER_TUX};
    for (unsigned k = 0; k < sizeof skins / sizeof *skins; k++) {
        ht_character_t c = {0};
        assert(ht_character_select(&c, skins[k]));
        for (int reading = 0; reading < 2; reading++) {
            const char *recap = reading ? "Fixed the tooltip clip. 3 files, tests pass." : NULL;
            home(&a, &c, recap);
            int face_runs = a.count;
            fleet(&a, nine, 9, 0, UINT32_MAX);
            assert(a.count > face_runs + 8); // every agent got an arc
            assert(a.count <= HT_RUNS);
            render(&a);
            // The busiest (permission) sits at 12 o'clock; nothing is drawn outside the glass.
            assert(px(full, 233, 233 - 226) == P.red);
            assert(px(full, 2, 2) == a.background);
            for (unsigned phase = 1; phase < NIXFRED_PHASES; phase++) {
                home(&b, &c, recap);
                fleet(&b, nine, 9, phase, UINT32_MAX);
                assert(b.count == a.count);
                transition(&a, &b);
                a = b;
            }
            if (!reading) {
                home(&a, &c, NULL);
                fleet(&a, nine, 9, 5, UINT32_MAX);
                fleet_summary(&a, nine, 9, skins[k] == HT_CHARACTER_FOCUS);
                assert(a.count <= HT_RUNS);
                render(&a);
                char name[64];
                snprintf(name, sizeof name, "home-fleet-%s", ht_character_name(skins[k]));
                for (char *p = name; *p; p++) if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
                shot(name);
            }
        }
    }

    // A failed agent flashes twice then holds thin; every frame is the same run count.
    const uint8_t failing[3] = {NIXFRED_WORKING, NIXFRED_FAILED, NIXFRED_IDLE};
    ht_scene_clear(&a, BLACK); fleet(&a, failing, 3, 0, 0); render(&a);
    assert(px(full, 233, 233 - 226) == P.red);
    ht_scene_clear(&b, BLACK); fleet(&b, failing, 3, 0, 130); assert(b.count == a.count); transition(&a, &b);
    render(&b); assert(px(full, 233, 233 - 226) == BLACK);
    ht_scene_clear(&a, BLACK); fleet(&a, failing, 3, 0, 5000); assert(b.count == a.count); transition(&b, &a);

    // FAILED screen: flash, off, flash, off, then the thin steady ring.
    uint32_t ts[] = {0, 130, 250, 370, 600};
    ht_scene_clear(&b, BLACK);
    for (unsigned i = 0; i < 5; i++) {
        ht_scene_clear(&a, BLACK);
        nixfred_failed_rim(&a, ts[i], P.red);
        ht_center(&a, 150, &ht_mono_28, INK, "x failed");
        ht_center(&a, 214, &ht_mono_20, DIMI, "ENOENT tsconfig.json");
        if (i) { assert(a.count == b.count); transition(&b, &a); }
        render(&a);
        bool lit = px(full, 233, 233 - 229) == P.red;
        assert(lit == (i == 0 || i == 2 || i == 4));
        if (i == 0) shot("failed-flash");
        if (i == 4) { assert(px(full, 233, 233 - 222) == BLACK); shot("failed-steady"); }
        b = a;
    }

    // DONE: the ring closes from the rim to a solid dot; the dot is filled at the end.
    for (int pm = 0; pm <= 1000; pm += 250) {
        ht_scene_clear(&a, BLACK);
        nixfred_done_collapse(&a, 233, 233, pm, P.green);
        if (pm) transition(&b, &a);
        render(&a);
        if (pm == 0) { assert(px(full, 233, 233 - 227) == P.green && px(full, 233, 233) == BLACK); shot("done-0"); }
        if (pm == 500) shot("done-500");
        b = a;
    }
    assert(px(full, 233, 233) == P.green && px(full, 233, 233 - 40) == BLACK);
    // Then the recap slides up under the dot (ui_habitat.c offsets the face's text runs).
    ht_scene_clear(&a, BLACK);
    nixfred_done_collapse(&a, 233, 118, 1000, P.green);
    ht_center(&a, 160, &ht_mono_28, INK, "* done");
    ht_center(&a, 214, &ht_mono_20, INK, "Fixed the tooltip clip.");
    ht_center(&a, 244, &ht_mono_20, DIMI, "3 files, tests pass");
    render(&a);
    shot("done-recap");

    // VOICE: the level ring thickens with the microphone; sending laps the rim. Two runs throughout.
    ht_scene_clear(&a, BLACK);
    nixfred_voice_rim(&a, true, 0, 0, ht_rgb(0x00ff2f), P.accent);
    render(&a);
    assert(px(full, 233, 233 - 229) != BLACK && px(full, 233, 233 - 220) == BLACK);
    for (unsigned lv = 1; lv <= 4; lv++) {
        ht_scene_clear(&b, BLACK);
        nixfred_voice_rim(&b, true, lv, 0, ht_rgb(0x00ff2f), P.accent);
        assert(b.count == a.count); transition(&a, &b); a = b;
    }
    render(&a);
    assert(px(full, 233, 233 - 216) != BLACK);
    ht_center(&a, 214, &ht_mono_28, INK, "listening");
    render(&a);
    shot("voice-listening-loud");
    ht_scene_clear(&a, BLACK);
    nixfred_voice_rim(&a, false, 0, 0, ht_rgb(0x00ff2f), P.accent);
    for (unsigned st = 1; st < NIXFRED_VOICE_STEPS; st++) {
        ht_scene_clear(&b, BLACK);
        nixfred_voice_rim(&b, false, 0, st, ht_rgb(0x00ff2f), P.accent);
        assert(b.count == a.count); transition(&a, &b);
        ht_damage_t d; ht_damage(&a, &b, &d);
        assert(d.pixels < (uint32_t)HT_WIDTH * HT_HEIGHT * 3 / 4);
        a = b;
    }
    ht_scene_clear(&a, BLACK);
    nixfred_voice_rim(&a, false, 0, 5, ht_rgb(0x00ff2f), P.accent);
    ht_center(&a, 214, &ht_mono_28, INK, "sending");
    render(&a);
    shot("voice-sending");

    // PANIC: every ring closes together onto one red dot, then holds with the words.
    for (uint32_t t = 0; t <= 800; t += 200) {
        ht_scene_clear(&a, BLACK);
        nixfred_panic(&a, t, 9, P.red, INK, DIMI);
        if (t) { assert(a.count == b.count); transition(&b, &a); }
        b = a;
        if (t == 200) { render(&a); shot("panic-closing"); }
    }
    render(&a);
    assert(px(full, 233, 213) == P.red && px(full, 233, 233 - 227) == BLACK);
    shot("panic-held");

    // PLANS: one arc per plan in the bottom sector, filled to its weekly use in its tone.
    const uint16_t used[3] = {620, 910, 150};
    const uint16_t tone[3] = {ht_rgb(0x0dbc79), ht_rgb(0xcd3131), ht_rgb(0xc6aaef)};
    ht_character_t c = {0};
    assert(ht_character_select(&c, HT_CHARACTER_FOCUS));
    home(&a, &c, NULL);
    fleet(&a, nine, 9, 5, UINT32_MAX);
    fleet_summary(&a, two_waiting, 4, true);
    nixfred_plans_rim(&a, FLEET_SPAN / 2 + 60, HT_TURN - FLEET_SPAN - 120, used, tone, 3);
    assert(a.count <= HT_RUNS);
    render(&a);
    assert(px(full, 233, 233 + 228) != a.background); // a plan arc crosses 6 o'clock
    shot("home-fleet-plans-focus");

    // The permission badge of slice 1, with the neutral figure (no initials in a public render).
    ht_scene_clear(&a, BLACK);
    nixfred_attention(&a, true, "", P.yellow, P.red, INK);
    ht_center(&a, 214, &ht_mono_28, INK, "Allow: git push?");
    render(&a);
    shot("question-permission");
    puts("test_nixfred_screens: ok");
    return 0;
}
