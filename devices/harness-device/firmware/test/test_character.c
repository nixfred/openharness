// The public character contract: reaction state, every mood/size, swapping, and
// DMA damage replay. Uses the same immutable assets and renderer as the board.
#include "../main/ui/habitat/character.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint16_t full[HT_WIDTH * HT_HEIGHT], partial[HT_WIDTH * HT_HEIGHT];
static uint16_t scratch[HT_WIDTH * HT_HEIGHT];
static unsigned redraws;

static void redraw(const ht_scene_t *before, const ht_scene_t *after)
{
    ht_damage_t d; ht_damage(before, after, &d);
    for (unsigned i = 0; i < d.count; i++) {
        ht_rect_t r = d.rect[i];
        assert(r.x >= 0 && r.y >= 0 && r.x + r.w <= HT_WIDTH && r.y + r.h <= HT_HEIGHT);
        assert(!((r.x | r.y | r.w | r.h) & 1));
        ht_raster(after, r, scratch);
        for (int y = 0; y < r.h; y++)
            memcpy(partial + (r.y + y) * HT_WIDTH + r.x, scratch + y * r.w, r.w * 2);
    }
    ht_raster(after, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
    assert(!memcmp(full, partial, sizeof full));
    redraws++;
}

static void tick(ht_character_t *c, uint32_t now, ht_character_mood_t mood,
                 bool quiet, bool visible, bool down, unsigned level)
{
    ht_character_tick(c, now, mood, quiet, visible, down, 330, level, now / 100);
    assert(c->motion.next_ms >= 1 && c->motion.next_ms <= 1000);
    assert(c->motion.frame < c->motion.animation->frames);
}

static void clocks(void)
{
    for (int id = 0; id < HT_CHARACTER_ILLUSTRATED_TIM; id++) {
        ht_character_t c = {0}; assert(ht_character_select(&c, id));
        tick(&c, UINT32_MAX - 49, HT_CHARACTER_WORKING, false, true, false, 0);
        tick(&c, 50, HT_CHARACTER_WORKING, false, true, false, 0);
        assert(c.motion.phase == 100);
        tick(&c, 80, HT_CHARACTER_WORKING, false, true, true, 0);
        uint16_t held = c.motion.phase;
        tick(&c, 3000, HT_CHARACTER_WORKING, false, true, true, 0);
        assert(c.motion.phase == held && c.motion.reaction.pose.pressed && c.motion.reaction.pose.look == 2);
        tick(&c, 4000, HT_CHARACTER_WORKING, false, true, false, 0);
        assert(c.motion.phase == held); // No backlog on release.
        tick(&c, 4100, HT_CHARACTER_LISTENING, false, true, false, 99);
        assert(c.motion.reaction.pose.level == 4);
        held = c.motion.phase;
        for (uint32_t t = 4101; t < 4225; t++) {
            tick(&c, t, HT_CHARACTER_LISTENING, false, true, false, 0);
            assert(c.motion.reaction.pose.level == 4 && c.motion.running && c.motion.rate == 2);
        }
        tick(&c, 4225, HT_CHARACTER_LISTENING, false, true, false, 0);
        assert(!c.motion.reaction.pose.level &&
               c.motion.phase == (held + 62) % c.motion.animation->duration);
        // A silent microphone must not freeze the body; every authored frame
        // remains reachable at half speed during a complete listening cycle.
        bool listening_seen[256] = {0};
        for (uint32_t t=4226;t<=4225+c.motion.animation->duration*2u;t++) {
            tick(&c,t,HT_CHARACTER_LISTENING,false,true,false,0);
            assert(!c.motion.reaction.pose.level);
            listening_seen[c.motion.frame]=true;
        }
        for (unsigned f=0;f<c.motion.animation->frames;f++) assert(listening_seen[f]);
        for (int state = 0; state < 4; state++) {
            ht_character_mood_t mood = state == 2 ? HT_CHARACTER_ASLEEP :
                state == 3 ? HT_CHARACTER_OFFLINE : HT_CHARACTER_WORKING;
            tick(&c, 5000, mood, state == 0, state != 1, false, 0);
            held = c.motion.phase;
            for (uint32_t t = 5001; t < 5100; t++) {
                tick(&c, t, mood, state == 0, state != 1, false, 0);
                assert(c.motion.phase == held && c.motion.next_ms == 1000);
            }
        }
        // A full idle cycle runs at half speed for either character.
        memset(&c.motion, 0, sizeof c.motion);
        tick(&c, 0, HT_CHARACTER_IDLE, false, true, false, 0);
        unsigned duration = c.motion.animation->duration;
        bool seen[256] = {0};
        for (unsigned t = 0; t <= duration * 2; t++) {
            tick(&c, t, HT_CHARACTER_IDLE, false, true, false, 0);
            seen[c.motion.frame] = true;
        }
        assert(!c.motion.phase && !c.motion.frame);
        for (unsigned i = 0; i < c.motion.animation->frames; i++) assert(seen[i]);
        ht_character_motion_t before = c.motion;
        assert(ht_character_select(&c, id));
        assert(!memcmp(&before, &c.motion, sizeof before));
        assert(!ht_character_select(&c, HT_CHARACTER_COUNT) && c.id == (ht_character_id_t)id);
        assert(!ht_character_select(&c, (ht_character_id_t)-1));
        assert(ht_character_select(&c, (id + 1) % HT_CHARACTER_ILLUSTRATED_TIM));
        assert(!c.motion.initialized && !c.motion.reaction.initialized);
        tick(&c, 10000, (ht_character_mood_t)255, false, true, false, 0);
        assert(c.motion.reaction.mood == HT_CHARACTER_IDLE);
    }
}

static void portraits(void)
{
    ht_scene_t a, b;
    ht_character_t c = {0};
    ht_character_face_t f = {.recipient = "Parser helper", .status = "Working", .hint = "tap to talk",
        .detail = "A carried paragraph", .foreground = 0xffff, .ink = 0xafe0, .dim = 0x7777, .roomy_reading = true};
    ht_scene_clear(&a, ht_rgb(0x181818)); redraw(NULL, &a);
    for (int id = 0; id < HT_CHARACTER_ILLUSTRATED_TIM; id++) {
        ht_character_select(&c, id);
        for (int size = HT_CHARACTER_FULL; size <= HT_CHARACTER_QUICK; size++) {
            for (int mood = HT_CHARACTER_IDLE; mood < HT_CHARACTER_MOODS; mood++) {
                f.mood = mood;
                for (unsigned frame = 0; frame < 8; frame++) {
                    c.motion.frame = frame;
                    c.delivery.lift = (frame >> 1) & 1;
                    f.pose = (ht_character_pose_t){.blink = frame == 0, .look = (int)(frame % 5) - 2,
                        .pressed = frame == 3, .level = frame % 5};
                    ht_scene_clear(&b, a.background);
                    ht_character_portrait(&b, &c, &f, ht_rgb(0xc8a9f0), size, 98);
                    assert(b.count && b.count <= HT_RUNS - 9);
                    redraw(&a, &b); a = b;
                    uint16_t bg = (b.background << 8) | (b.background >> 8);
                    unsigned pixels = 0;
                    for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++) {
                        if (full[y * HT_WIDTH + x] == bg) continue;
                        assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
                        pixels++;
                    }
                    assert(pixels > 100);
                    f.focus = size == HT_CHARACTER_COMPACT;
                    f.straight_title = frame & 1; f.unread = frame & 2;
                    const char *recap = size == HT_CHARACTER_BRIEF ? "Fixed the parser. All tests pass." :
                        size == HT_CHARACTER_READING ? "Fixed the parser. All tests pass. Voice input now sends to the selected agent, including after switching characters or reading another pane." : NULL;
                    ht_scene_clear(&b, a.background);
                    ht_character_face(&b, &c, &f, ht_rgb(0xc8a9f0), recap);
                    assert(b.count <= HT_RUNS - 1); // Reading fits; voice puts the letter away for Discard.
                    redraw(&a, &b); a = b;
                }
            }
        }
    }
    // Changing only a cell's colour must repaint it. Compare against separate
    // uniform text runs so this also checks the palette and clipped raster path.
    const uint16_t red_blue[] = {0xf800, 0x001f}, green_blue[] = {0x07e0, 0x001f};
    ht_scene_clear(&a, 0);
    int w = ht_mono_20.width;
    assert(ht_ascii_text(&a, 200, 210, w * 2, &ht_mono_20, 0xffff, 0, "##", 2));
    a.runs[0].colors = red_blue; redraw(NULL, &a);
    b = a; b.runs[0].colors = green_blue; redraw(&a, &b);
    ht_scene_t reference; ht_scene_clear(&reference, 0);
    assert(ht_text(&reference, 200, 210, w, &ht_mono_20, 0x07e0, 0, "#"));
    assert(ht_text(&reference, 200 + w, 210, w, &ht_mono_20, 0x001f, 0, "#"));
    ht_raster(&reference, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, scratch);
    assert(!memcmp(full, scratch, sizeof full));
}

static void delivery_and_caption(void)
{
    for (int id = 0; id < HT_CHARACTER_ILLUSTRATED_TIM; id++) {
        ht_character_t c = {0}; ht_character_select(&c, id);
        c.motion.next_ms = 1000;
        assert(!ht_character_delivery_tick(&c, 100, true, 0, true)); // Restored mail only holds.
        assert(!c.delivery.moving);
        ht_character_delivery_tick(&c, 200, true, 1, true);
        assert(c.delivery.moving && c.motion.next_ms == 160);
        ht_character_delivery_tick(&c, 360, true, 1, true); assert(c.delivery.lift == 1);
        ht_character_delivery_tick(&c, 400, true, 2, true); // Burst coalesces.
        ht_character_delivery_tick(&c, 1480, true, 2, true); assert(!c.delivery.moving && !c.delivery.lift);
        ht_character_delivery_tick(&c, 1600, true, 3, false);
        ht_character_delivery_tick(&c, 1760, true, 3, true); assert(!c.delivery.moving); // No replay on wake.
        ht_character_delivery_tick(&c, UINT32_MAX - 79, true, UINT32_MAX, true);
        ht_character_delivery_tick(&c, 80, true, UINT32_MAX, true); assert(c.delivery.lift == 1);
        ht_character_delivery_tick(&c, 81, false, 0, true); assert(!c.delivery.moving && !c.delivery.lift);
    }
    ht_character_caption_t c = {0};
    ht_character_caption_tick(&c, 100, "a", false); assert(!c.activity && c.opacity == 255);
    ht_character_caption_tick(&c, 200, "a", true); assert(!c.activity && c.opacity == 255);
    ht_character_caption_tick(&c, 3080, "a", true); assert(!c.activity && c.opacity < 255);
    ht_character_caption_tick(&c, 3200, "a", true); assert(c.activity && !c.opacity);
    ht_character_caption_tick(&c, 3500, "a", true); assert(c.activity && c.opacity == 255);
    ht_character_caption_tick(&c, 6500, "a", true); assert(!c.activity && c.opacity == 255);
    ht_character_caption_tick(&c, 9600, "a", true); assert(c.activity);
    ht_character_caption_tick(&c, 9601, "a", false); assert(!c.activity && c.opacity == 255);
    ht_character_caption_tick(&c, UINT32_MAX - 1499, "a", true);
    ht_character_caption_tick(&c, 1700, "a", true); assert(c.activity);
    ht_character_caption_tick(&c, 1701, "b", true); assert(!c.activity && c.opacity == 255);
    assert(ht_character_caption_ink(0xffff, 0x18c3, 0) == 0x18c3);
    assert(ht_character_caption_ink(0xffff, 0x18c3, 255) == 0xffff);
}

/*
 * ht_character_layout()'s recap contract: four roomy rows, ninety characters, an ellipsis past that.
 *
 * Only the skins that GO THROUGH that layout are measured here. Focus owns its whole face and has
 * its own grid — three recap rows, because the fourth slot is its status line — so measuring it
 * against these numbers would be testing one layout with another layout's ruler. focus_face() below
 * is its ruler.
 */
static void recap_budget(void)
{
    for (int id = 0; id < HT_CHARACTER_ILLUSTRATED_TIM; id++) for (int unicode = 0; unicode < 2; unicode++)
        for (int length = 89; length <= 91; length++) {
            if (id == HT_CHARACTER_FOCUS) continue;
            ht_character_t c = {0}; ht_character_select(&c, id);
            ht_character_face_t f = {.roomy_reading=true, .single_label=true, .foreground=0xffff};
            char input[400] = "", visible[400] = "";
            for (int i = 0; i < length; i++) strcat(input, unicode ? "\xc3\xa9" : "x");
            ht_scene_t scene; ht_scene_clear(&scene, 0);
            ht_character_face(&scene, &c, &f, 0xffff, input);
            int rows = 0, chars = 0;
            for (int i = 0; i < scene.count; i++) if (scene.runs[i].font == &ht_mono_28) {
                if (scene.runs[i].text[0]) rows++;
                strcat(visible, scene.runs[i].text);
            }
            for (const char *p = visible; *p; chars++) {
                uint32_t cp = ht_utf8_next(&p);
                assert(cp == (unicode ? 0xe9u : 'x') || cp == '.');
            }
            assert(rows <= 4 && chars <= 90);
            if (length <= 90) assert(!strcmp(input, visible));
            else assert(!strcmp(visible + strlen(visible) - 3, "..."));
            ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
            for (int y=0;y<HT_HEIGHT;y++) for (int x=0;x<HT_WIDTH;x++)
                if (full[y*HT_WIDTH+x])
                    assert((x-233)*(x-233)+(y-233)*(y-233)<230*230);
        }
}

/*
 * THE FOCUS FACE.
 *
 * Two properties, and both are invisible until they are wrong on glass:
 *
 *  1. The run count and their order never change with the state. ht_damage() diffs run index against
 *     run index and repaints the whole 466x466 the moment either moves, so a face that drops a row
 *     when it has nothing to say costs a full frame every time it changes its mind. An earlier draft
 *     did exactly that — and worse, ht_text() refuses a zero-width run, so the empty row silently
 *     overwrote the run BEFORE it and the engine mark disappeared.
 *  2. Nothing lands outside the bezel. Every width on that face is the chord at its row's BOTTOM
 *     edge, which is the measurement that is easy to take from the wrong edge.
 */
static void focus_face(void)
{
    ht_character_t c = {0};
    assert(ht_character_select(&c, HT_CHARACTER_FOCUS));
    assert(!strcmp(ht_character_name(HT_CHARACTER_FOCUS), "Focus"));
    const char *long_name = "A pane with a name far wider than the glass can hold";
    const char *long_tab = "A workspace whose name also overruns the pill";
    const char *recap = "Shipped the retry queue and the webhook tests pass on the first run, "
                        "then tidied the parser.";
    struct { const char *tab, *name, *engine, *activity, *recap; ht_character_mood_t mood;
             uint16_t elapsed; uint8_t level; } cases[] = {
        {"", "", "", "", "", HT_CHARACTER_IDLE, 0, 0},
        {"Harness repo", "Payments refactor", "claude", "", recap, HT_CHARACTER_IDLE, 0, 0},
        {"Harness repo", "Payments refactor", "claude", "Coalescing", "", HT_CHARACTER_WORKING, 34, 0},
        {"Harness repo", "Payments refactor", "codex", "", "", HT_CHARACTER_LISTENING, 0, 4},
        {long_tab, long_name, "opencode", "Simmering", recap, HT_CHARACTER_WORKING, 65535, 2},
        {"Ti\u1ebfng Vi\u1ec7t", "\u0110\u00e3 s\u1eeda xong ph\u1ea7n flush", "claude", "",
         "L\u01b0\u1ee3ng b\u1ed9 nh\u1edb \u0111\u00e3 gi\u1ea3m v\u00e0 ki\u1ec3m tra l\u1ea1i.", HT_CHARACTER_IDLE, 0, 0},
    };
    int expected = -1;
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        ht_character_face_t f = {.recipient = cases[i].name, .tab = cases[i].tab,
            .engine = cases[i].engine, .activity = cases[i].activity, .elapsed = cases[i].elapsed,
            .status = "", .hint = "", .detail = "", .mood = cases[i].mood,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        f.pose.level = cases[i].level;
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, cases[i].recap);
        if (expected < 0) expected = scene.count;
        assert(scene.count == expected);   // property 1
        ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
        for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
            if (full[y * HT_WIDTH + x])
                assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);   // property 2
    }
    /*
     * A NAME TOO LONG FOR ITS ROW ends in "...", as LVGL's LONG_DOT cut it, within its budget in
     * PIXELS: the tab pill's name gets 314 (the widest a round pill this high can be inside r 230),
     * the agent's name what the 384 px row leaves beside its mark. Cut by the raster instead, it
     * reads as a typo.
     */
    {
        ht_character_face_t f = {.recipient = long_name, .tab = long_tab, .engine = "claude",
            .activity = "", .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "");
        int found = 0;
        for (int i = 0; i < scene.count; i++) {
            const ht_run_t *r = &scene.runs[i];
            size_t n = strlen(r->text);
            if (n < 3 || strcmp(r->text + n - 3, "...")) continue;
            int w = ht_measure(r->font, r->text);
            assert(w <= r->w);   // the raster never cuts it
            if (r->font == &ht_lv_montserrat_24.base) { assert(w <= 314); found |= 1; }
            if (r->font == &ht_lv_geist_med_38.base) { assert(w <= 384 - 28 - 10); found |= 2; }
        }
        assert(found == 3);
    }

    /*
     * THE VOICE FACE, both halves of it, every frame.
     *
     * It is the same skin through the same entry point — ui_habitat.c sets `voice` and Focus owns
     * the whole glass — so the constant-run rule applies across the two states as well as within
     * them: recording and sending must emit the same runs in the same order, or a person watching a
     * clip go out gets a full 466x466 repaint at the moment the meter stops. The bars reach 121 px
     * and the sparkles sit on a 66 px pitch, both of which are wider and taller than anything the
     * home face draws, so the bezel is checked here again rather than assumed from above.
     */
    {
        int voice_runs = -1;
        for (int sending = 0; sending < 2; sending++)
            for (int frame = 0; frame < 15; frame++) {
                ht_character_face_t f = {.recipient = "", .tab = "", .engine = "", .activity = "",
                    .status = "", .hint = "", .detail = "", .voice = true,
                    .mood = sending ? HT_CHARACTER_WORKING : HT_CHARACTER_LISTENING,
                    .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
                ht_scene_t scene; ht_scene_clear(&scene, 0);
                c.motion.frame = (uint8_t)frame;
                ht_character_face(&scene, &c, &f, 0xffff, recap);
                if (voice_runs < 0) voice_runs = scene.count;
                assert(scene.count == voice_runs);
                ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                int ink = 0;
                for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
                    if (full[y * HT_WIDTH + x]) {
                        ink++;
                        assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
                    }
                assert(ink > 0);   // a voice screen that drew nothing would pass every rule above
            }
        c.motion.frame = 0;
    }

    /*
     * WHERE THE LIVE FIRMWARE PUTS THEM (0.0.86, assets/lvgl/SPEC.md): the pill's box at y 68, 41
     * tall; the name's line from 119; the recap card at 41,191, 384 x 119. Without a card the block
     * is centred: a working name at 176, its pill at 125 and its status at 248; a resting one at 172.
     * A drift here is a drift from the dial the owner compares this with.
     */
    {
        ht_character_face_t f = {.recipient = "Payments refactor", .tab = "Harness repo",
            .engine = "claude", .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "Shipped the retry queue and the webhook tests.");
        const ht_run_t *pill = &scene.runs[0], *name = &scene.runs[3], *card = &scene.runs[5];
        assert(pill->box.h == 41 && pill->y == 68);
        assert(name->font == &ht_lv_geist_med_38.base && name->y == 119 && !strcmp(name->text, "Payments refactor"));
        assert(card->box.h == 119 && card->x == 41 && card->y == 191 && card->w == 384 && card->box.radius == 28);
        // The mark: the 28 px box centred on the name's 51 px line, 10 px before the name.
        assert(scene.runs[2].sprite.pixels == ht_icon_engine28[0].px && scene.runs[2].y == 119 + 11);
        assert(name->x == scene.runs[2].x + 38);

        f.activity = "Working"; f.elapsed = 34;
        ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "");
        assert(scene.runs[0].y == 125 && scene.runs[3].y == 176);
        assert(scene.runs[8].y == 248 && scene.runs[8].font == &ht_lv_geist_med_32.base &&
               !strcmp(scene.runs[8].text, "Simmering\xe2\x80\xa6 34s"));   // the gerund for 30..35 s

        f.activity = ""; f.elapsed = 0;
        ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "");
        assert(scene.runs[3].y == 172 && scene.runs[9].y == 172 + 51 + 21 &&
               !strcmp(scene.runs[9].text, "No activity yet"));
    }

    // Stated as its parts rather than as a number: the tab pill (its box and its name), the header
    // (mark, two name lines), the recap card (its box and two lines), the live status and
    // "No activity yet" (two lines). Each is emitted empty when it has nothing to say.
    assert(expected == 2 + 3 + 3 + 1 + 2);
}

static void footer_layout(void)
{
    const unsigned counts[] = {0, 1, 9, 10, 32, 1, 0};
    ht_scene_t before, after;
    ht_scene_clear(&before, 0); redraw(NULL, &before);
    for (unsigned i = 0; i < sizeof counts / sizeof counts[0]; i++) {
        ht_scene_clear(&after, 0);
        ht_notification_bell(&after, counts[i], counts[i] ? 0xffff : ht_rgb(0x888888));
        redraw(&before, &after); before = after;
        int left = HT_WIDTH, right = 0, top = HT_HEIGHT, bottom = 0;
        for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
            if (full[y * HT_WIDTH + x]) {
                assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
                if (x < left) left = x;
                if (x > right) right = x;
                if (y < top) top = y;
                if (y > bottom) bottom = y;
            }
        assert(left + right >= 460 && left + right <= 470);
        assert(top >= 418 && bottom <= 451); // Matches the upper curve's rim inset.
    }
    ht_scene_clear(&after, 0); redraw(&before, &after);
}

static void inbox_layout(void)
{
    const char *names[] = {"Build", "Investigate firmware and notifications"};
    const char *messages[] = {"Yes. The fix is installed.",
        "Fixed and merged into main: PR #436. All 62 relevant tests and static analysis passed.",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"};
    const char *marks[] = {HT_DONE, "?", HT_FAILED};
    const unsigned colors[] = {0x0dbc79, 0xe5e510, 0xcd3131};
    ht_scene_t before, after;
    ht_scene_clear(&before, 0); redraw(NULL, &before);
    for (unsigned n = 0; n < 2; n++) for (unsigned m = 0; m < 3; m++)
        for (unsigned k = 0; k < 3; k++) {
            ht_scene_clear(&after, 0);
            ht_inbox_card(&after, marks[k], names[n], messages[m], 0xffff, ht_rgb(colors[k]));
            int titles = n ? 2 : 1, bodies = after.count - titles - 1;
            assert(bodies >= 1 && bodies <= 4);
            const ht_run_t *icon = &after.runs[after.count - 1];
            assert(!strcmp(icon->text, marks[k]) && icon->fg == ht_rgb(colors[k]));
            assert(icon->x == after.runs[0].x && icon->y == after.runs[0].y);
            assert(after.runs[titles].y - after.runs[titles - 1].y - 38 == 28);
            int bottom = after.runs[after.count - 2].y + 38;
            assert(after.runs[0].y + bottom >= 453 && after.runs[0].y + bottom <= 454);
            for (int i = 0; i < after.count - 1; i++)
                assert(after.runs[i].font == &ht_mono_28 && after.runs[i].fg == 0xffff);
            redraw(&before, &after); before = after;
            for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
                if (full[y * HT_WIDTH + x])
                    assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
        }
    puts("Inbox layout: desktop status colors, neutral prose, balanced short/long blocks, fixed gap, circle bounds and exact incremental redraws PASS");
}

int main(void)
{
    assert(!strcmp(ht_character_name(HT_CHARACTER_TIM), "Tim"));
    assert(!strcmp(ht_character_name(HT_CHARACTER_TUX), "Tux"));
    clocks(); portraits(); delivery_and_caption(); recap_budget(); focus_face();
    footer_layout(); inbox_layout();
    printf("Characters: both adapters, eight moods, five sizes, pause/mic/wrap/swap and %u exact incremental redraws PASS\n", redraws);
}
