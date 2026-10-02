// The public character contract: reaction state, every mood/size, swapping, and
// DMA damage replay. Uses the same immutable assets and renderer as the board.
#include "../main/ui/habitat/character.h"
#include "../main/ui/habitat/pets.h"
#include "../main/ui/habitat/focus.h"
#include "../main/ui/habitat/focus_faces.h"
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
static void squeeze(char *text)
{
    char *out = text;
    for (const char *p = text; *p; p++) if (*p != ' ') *out++ = *p;
    *out = 0;
}
// The pet registered for an engine, or NULL.
static const ht_pet_t *pet_of(const char *engine)
{
    for (unsigned i = 0; i < ht_pet_count; i++) if (!strcmp(ht_pets[i].engine, engine)) return &ht_pets[i];
    return NULL;
}
// The index of the pet's frame whose pixels these are (every frame is in some loop), or -1.
static int pet_frame(const ht_pet_t *pet, const uint16_t *px)
{
    for (int s = 0; s < HT_PET_STATES; s++)
        for (int k = 0; k < HT_PET_STEPS; k++)
            if (pet->frames[pet->loops[s][k].frame].px == px) return pet->loops[s][k].frame;
    return -1;
}
// The index of the scene's frame whose cells these are, or -1.
static int scene_frame(const ht_pet_scene_t *sc, const uint8_t *cells)
{
    unsigned n = 0;
    for (unsigned i = 0; i < sc->steps * HT_PET_SCENE_LEVELS; i++) if (sc->loop[i] >= n) n = sc->loop[i] + 1u;
    for (unsigned k = 0; k < n; k++) if (sc->frames[k].cells == cells) return (int)k;
    return -1;
}
// Focus draws in Geist (owner, 2026-10-02): no run of the scene is one of the trial's Roboto faces.
static void no_roboto(const ht_scene_t *scene)
{
    const ht_pfont_t *roboto[] = {&ht_lv_roboto_med_38, &ht_lv_roboto_med_32, &ht_lv_roboto_med_30,
        &ht_lv_roboto_med_28, &ht_lv_roboto_med_24, &ht_lv_roboto_med_22, &ht_lv_roboto_reg_38,
        &ht_lv_roboto_reg_25, &ht_lv_roboto_reg_20};
    for (int i = 0; i < scene->count; i++) {
        for (unsigned g = 0; g < sizeof roboto / sizeof roboto[0]; g++) assert(scene->runs[i].font != &roboto[g]->base);
        assert(scene->runs[i].font != &ht_rmono_24);
        // ...and neither the curved name's old GeistMono: any curved run is Geist Medium 26.
        assert(scene->runs[i].font != &ht_mono_24 && scene->runs[i].font != &ht_viet_24);
        if (scene->runs[i].arc) assert(scene->runs[i].font == &ht_lv_geist_med_26.base);
    }
}
static void focus_face(void)
{
    ht_character_t c = {0};
    assert(ht_character_select(&c, HT_CHARACTER_FOCUS));
    assert(!strcmp(ht_character_name(HT_CHARACTER_FOCUS), "Focus"));
    const char *long_name = "A pane with a name far wider than the glass can hold";
    const char *long_tab = "A workspace whose name is no longer drawn on this face";
    const char *recap = "Shipped the retry queue and the webhook tests pass on the first run, "
                        "then tidied the parser.";
    struct { const char *tab, *name, *engine, *activity, *recap; ht_character_mood_t mood;
             uint16_t elapsed; uint8_t level; } cases[] = {
        {"", "", "", "", "", HT_CHARACTER_IDLE, 0, 0},
        {"Harness repo", "Payments refactor", "claude", "", recap, HT_CHARACTER_IDLE, 0, 0},
        {"Harness repo", "Payments refactor", "claude", "Coalescing", "", HT_CHARACTER_WORKING, 34, 0},
        {"Harness repo", "Payments refactor", "codex", "", "", HT_CHARACTER_LISTENING, 0, 4},
        {long_tab, long_name, "opencode", "Simmering", recap, HT_CHARACTER_WORKING, 65535, 2},
        // The widest four lines the recap can hold: its fourth line sits lowest on the glass, where
        // the circle is narrowest, and must still keep its ink inside it.
        {"", "Wide", "codex", "", "MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW MW "
         "MW MW MW MW MW MW MW", HT_CHARACTER_IDLE, 0, 0},
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
        no_roboto(&scene);
        ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
        for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
            if (full[y * HT_WIDTH + x])
                assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);   // property 2
    }
    /*
     * THE OCTOPUS'S LAYOUT (owner, 2026-10-01): the name on the top curve, the engine's 56 px mark,
     * and a recap of up to four lines that ends in "…" once it is cut — at the octopus's ninety
     * codepoints or at four lines, whichever comes first — every line within the card's 346 px, so the
     * raster never cuts it.
     */
    {
        const char *lengthy = "Flashed 0.0.91 to both dials and verified the image on each. All 44 host checks "
                              "pass, including the new reader tests. Nothing is committed yet; say commit.";
        ht_character_face_t f = {.recipient = long_name, .tab = long_tab, .engine = "claude",
            .activity = "", .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, lengthy);
        int arc = 0, mark = 0, lines = 0;
        const ht_run_t *last = NULL;
        for (int i = 0; i < scene.count; i++) {
            const ht_run_t *r = &scene.runs[i];
            if (r->arc == 1) { arc++; assert(r->font == &ht_lv_geist_med_26.base); }
            if (r->sprite.width == 56 || r->sprite.width == pet_of("claude")->w) mark++;
            if (r->font == &ht_lv_geist_med_30.base && r->text[0]) {
                lines++; last = r;
                // LVGL lets a wrapped line's trailing space run past the width; its ink may not.
                char ink[HT_TEXT_BYTES];
                snprintf(ink, sizeof ink, "%s", r->text);
                for (size_t n = strlen(ink); n && ink[n - 1] == ' '; ) ink[--n] = 0;
                assert(ht_measure(r->font, r->text) <= r->w && ht_measure(r->font, ink) <= 346);
            }
        }
        assert(arc == 1 && mark == 1 && lines >= 3 && lines <= 4);
        size_t n = strlen(last->text);
        assert(n >= 3 && !strcmp(last->text + n - 3, "\xe2\x80\xa6"));
        no_roboto(&scene);
        // No tab pill and no name row: nothing in Montserrat or the 38 px name face is drawn.
        for (int i = 0; i < scene.count; i++)
            assert(scene.runs[i].font != &ht_lv_montserrat_24.base && scene.runs[i].font != &ht_lv_geist_med_38.base);
    }

    // The check and cross marks (U+2713 / U+2717) reach the glass: every Focus face holds them (the LVGL
    // Geist faces, and geist_med_30 through gen_focus_faces.py's second --font); a missing glyph is "?".
    {
        const char *marks = "Tests \xe2\x9c\x93 pushed \xe2\x9c\x97";
        ht_character_face_t f = {.recipient = "pane", .tab = "", .engine = "claude", .activity = "",
            .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, marks);
        int found = 0;
        for (int i = 0; i < scene.count; i++)
            if (scene.runs[i].font == &ht_lv_geist_med_30.base && strstr(scene.runs[i].text, "\xe2\x9c\x93")) found++;
        assert(found == 1);
        const ht_pfont_t *faces[] = {&ht_lv_geist_med_38, &ht_lv_geist_med_32, &ht_lv_geist_med_30,
            &ht_lv_geist_med_28, &ht_lv_geist_reg_38, &ht_lv_geist_reg_25, &ht_lv_geist_reg_20};
        for (unsigned k = 0; k < sizeof faces / sizeof faces[0]; k++) {
            int has[2] = {0, 0};   // the face itself holds both marks, not its "?" or a fallback
            for (unsigned g = 0; g < faces[k]->count; g++) {
                has[0] |= faces[k]->codes[g] == 0x2713;
                has[1] |= faces[k]->codes[g] == 0x2717;
            }
            assert(has[0] && has[1]);
        }
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
     * WHERE THEY STAND: the name on the arc. A recap sits in the fixed card at (41, 179), 384 x 192,
     * centred in it whatever its length — the card and the mark stay put (owner, 2026-10-02); working or resting there is
     * no card and the line is centred on the glass. The 56 px mark sits halfway between the foot of the
     * arc's cells (y 44) and the card's top or the line: the gap above it equals the gap below.
     */
    {
        enum { TITLE_BOTTOM = HT_ARC_Y + HT_ARC_CELL_HEIGHT };
        ht_character_face_t f = {.recipient = "Payments refactor", .tab = "Harness repo",
            .engine = "claude", .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        const char *recaps[] = {"Done.", "Shipped the retry queue and the webhook tests.",
            ("Flashed 0.0.91 to both dials and verified the image on each. All 44 host checks pass, "
             "including the new reader tests. Nothing is committed yet.")};
        for (unsigned k = 0; k < 3; k++) {
            ht_scene_t scene; ht_scene_clear(&scene, 0);
            ht_character_face(&scene, &c, &f, 0xffff, recaps[k]);
            const ht_run_t *name = &scene.runs[0], *mark = &scene.runs[1];
            assert(name->arc == 1 && !strcmp(name->text, "Payments refactor") && name->font == &ht_lv_geist_med_26.base);
            no_roboto(&scene);
            // The Claude pet, still (clock 0), centred in the 56 px mark's box: 60 x 45 at its step 0.
            const ht_pet_t *cp = pet_of("claude");
            assert(cp && cp->w == 60 && cp->h == 45);
            assert(pet_frame(cp, mark->sprite.pixels) == cp->loops[HT_PET_IDLE][0].frame &&
                   mark->x == (466 - cp->w) / 2);
            int mark_top = mark->y - (56 - cp->h) / 2;
            const ht_run_t *card = &scene.runs[2];
            assert(card->box.h == 192 && card->x == 41 && card->y == 179 && card->w == 384 && card->box.radius == 28);
            int lines = 0;
            for (int i = 3; i < 7; i++) if (scene.runs[i].text[0]) lines++;
            assert(lines >= 1 && lines <= 4 && (k != 0 || lines == 1));
            int h = lines * (ht_lv_geist_med_30.base.height + 1) - 1;
            assert(scene.runs[3].y == 179 + (192 - h) / 2);   // centred in the card
            for (int i = 0; i < lines; i++) assert(scene.runs[3 + i].y == scene.runs[3].y + i * (ht_lv_geist_med_30.base.height + 1));   // the line + 1 px
            assert(scene.runs[3 + lines - 1].y + ht_lv_geist_med_30.base.height <= 179 + 192);   // inside the card
            int above = mark_top - TITLE_BOTTOM, below = card->y - (mark_top + 56);
            assert(above >= 0 && (below - above == 0 || below - above == 1));
        }

        f.activity = "Working"; f.elapsed = 34;
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "");
        no_roboto(&scene);
        assert(scene.runs[7].y == 233 - ht_lv_geist_med_32.base.height / 2 && scene.runs[7].font == &ht_lv_geist_med_32.base &&
               !strcmp(scene.runs[7].text, "Simmering\xe2\x80\xa6 34s"));   // the gerund for 30..35 s
        {
            int top = scene.runs[1].y - (56 - pet_of("claude")->h) / 2;
            int above = top - TITLE_BOTTOM, below = scene.runs[7].y - (top + 56);
            assert(above > 0 && (below - above == 0 || below - above == 1));
        }

        // Resting: one of the invitations, centred, holding still while the face stays up (both draws
        // of an agent say the same), and picked afresh when the face comes back.
        f.activity = ""; f.elapsed = 0;
        static const char *const resting[] = {"Let's build it", "Do anything", "What's next?",
            "Ready when you are", "Tap to talk", "Say the word", "Make it happen", "Start something"};
        char first[64] = "";
        const char *names[] = {"Payments refactor", "Landing page", "Deploy firmware", "Docs sweep",
                               "Bug triage", "Release notes"};
        for (unsigned k = 0; k < sizeof names / sizeof names[0]; k++) {
            f.recipient = names[k];
            for (int again = 0; again < 2; again++) {
                ht_scene_clear(&scene, 0);
                ht_character_face(&scene, &c, &f, 0xffff, "");
                no_roboto(&scene);
                const ht_run_t *l1 = &scene.runs[8], *l2 = &scene.runs[9];
                // Compared without spaces: a wrapped line keeps the space LVGL broke it at.
                char said[64], want[64];
                snprintf(said, sizeof said, "%s%s", l1->text, l2->text);
                squeeze(said);
                bool known = false;
                for (unsigned r = 0; r < sizeof resting / sizeof resting[0]; r++) {
                    snprintf(want, sizeof want, "%s", resting[r]); squeeze(want);
                    known |= !strcmp(said, want);
                }
                assert(known);
                assert(l1->y == 233 - ht_lv_geist_med_32.base.height / 2);
                int top = scene.runs[1].y - (56 - pet_of("claude")->h) / 2;
                int above = top - TITLE_BOTTOM, below = l1->y - (top + 56);
                assert(above > 0 && (below - above == 0 || below - above == 1));
                if (!again) snprintf(first, sizeof first, "%s", said);
                else assert(!strcmp(said, first));   // a redraw never swaps it
            }
        }
        /*
         * RANDOM WHEREVER IT SHOWS (owner, 2026-10-02): the same name every time — "Choose a pane",
         * the face with no agent — still gets a new line each time the resting face returns, never
         * the one it just showed, and over a few returns most of the list.
         */
        {
            f.recipient = "Choose a pane";
            char last[64] = "", seen[8][64];
            int kinds = 0;
            for (int visit = 0; visit < 24; visit++) {
                f.activity = "Working"; f.elapsed = 3; f.clock_ms = 1000u + (uint32_t)visit * 977u;
                ht_scene_clear(&scene, 0);
                ht_character_face(&scene, &c, &f, 0xffff, "");   // away: the working line
                f.activity = ""; f.elapsed = 0;
                ht_scene_clear(&scene, 0);
                ht_character_face(&scene, &c, &f, 0xffff, "");   // back to resting
                char said[64];
                snprintf(said, sizeof said, "%s%s", scene.runs[8].text, scene.runs[9].text);
                squeeze(said);
                assert(strcmp(said, last));
                snprintf(last, sizeof last, "%s", said);
                bool known = false;
                for (int k = 0; k < kinds; k++) known |= !strcmp(seen[k], said);
                if (!known && kinds < 8) snprintf(seen[kinds++], sizeof seen[0], "%s", said);
            }
            assert(kinds >= 5);
            f.clock_ms = 0;
        }
        f.recipient = "Payments refactor";

        // An engine this build has no mark for leaves the mark's place empty, not a wrong mark.
        f.engine = "something-new";
        ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &f, 0xffff, "");
        assert(!scene.runs[1].sprite.width && !scene.runs[1].text[0]);
    }

    /*
     * THE PETS (claude, codex): every state, every step. The pet takes the mark's run (the count never moves),
     * its frame and hop follow the face's own state and clock_ms, it stays on the glass, and only an engine with a
     * pet gets one.
     */
    assert(ht_pet_count > 0);
    for (unsigned pe = 0; pe < ht_pet_count; pe++) {
        const ht_pet_t *pet = &ht_pets[pe];
        const char *eng = pet->engine;
        assert(pet_of(eng) == pet && ht_focus_engine_index(eng) >= 0);   // a known engine, listed once
        for (unsigned q = 0; q < pe; q++) assert(strcmp(ht_pets[q].engine, eng));
        // Clear of the curved title: no layout, state or step puts ink above the foot of its cells.
        for (int layout = 0; layout < 3; layout++)       // recap card, working line, resting line
            for (int state = 0; state < HT_PET_STATES; state++)
                for (int step = 0; step < HT_PET_STEPS; step++) {
                    ht_character_face_t f = {.recipient = "Payments refactor", .engine = eng,
                        .activity = layout == 1 ? "Working" : "", .elapsed = 5, .status = "", .hint = "",
                        .detail = "", .mood = state == HT_PET_DONE ? HT_CHARACTER_DONE : HT_CHARACTER_IDLE,
                        .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff, .asking = state == HT_PET_ASKING,
                        .clock_ms = (uint32_t)step * pet->step_ms[state] + 1};
                    if (state == HT_PET_WORKING && layout != 2) f.activity = "Working";
                    ht_scene_t scene; ht_scene_clear(&scene, 0);
                    ht_character_face(&scene, &c, &f, 0xffff, layout == 0 ? "Shipped the retry queue." : "");
                    const ht_run_t *mark = &scene.runs[1];
                    if (pet->working_scene && layout == 1 && state != HT_PET_ASKING) continue;   // the scene: below
                    int fr = pet_frame(pet, mark->sprite.pixels);
                    assert(fr >= 0);
                    const ht_icon_t *ic = &pet->frames[fr];
                    int row = 0;
                    while (row < ic->h) {
                        bool inked = false;
                        for (int x = 0; x < ic->w; x++) inked |= ic->a[row * ic->w + x] != 0;
                        if (inked) break;
                        row++;
                    }
                    assert(row < ic->h && mark->y + row >= HT_ARC_Y + HT_ARC_CELL_HEIGHT);
                }
        int frame_at[HT_PET_STATES][HT_PET_STEPS];
        for (int state = 0; state < HT_PET_STATES; state++)
            for (int step = 0; step < HT_PET_STEPS; step++) {
                ht_character_face_t f = {.recipient = "Payments refactor", .engine = eng,
                    .activity = "", .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_IDLE,
                    .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff,
                    .clock_ms = (uint32_t)step * pet->step_ms[state] + 1};
                if (state == HT_PET_WORKING) { f.activity = "Working"; f.elapsed = 5; }
                if (state == HT_PET_DONE) f.mood = HT_CHARACTER_DONE;
                if (state == HT_PET_ASKING) f.asking = true;
                ht_scene_t scene; ht_scene_clear(&scene, 0);
                ht_character_face(&scene, &c, &f, 0xffff, state == HT_PET_DONE ? "Done." : "");
                assert(scene.count == 1 + 1 + 1 + 4 + 1 + 2 + 1);
                const ht_run_t *mark = &scene.runs[1];
                const ht_pet_scene_t *ws = state == HT_PET_WORKING ? pet->working_scene : NULL;
                if (ws) {
                    // THE WORKING SCENE: in the mark's run, centred, the status on the lower arc.
                    int frame = scene_frame(ws, mark->sprite.cells);
                    assert(frame == ws->loop[(step * pet->step_ms[state] + 1) / ws->step_ms % ws->steps]);
                    assert(mark->sprite.width == ws->w && mark->sprite.height == ws->h && mark->x == (466 - ws->w) / 2 + ws->dx);
                    assert(mark->y == 233 + 4 - ws->h / 2 + ws->dy);
                    assert(!scene.runs[7].text[0]);                 // the centred status is empty
                    const ht_run_t *lower = &scene.runs[10];
                    assert(lower->arc == 2 && !strcmp(lower->text, "Working\xe2\x80\xa6 5s"));   // Geist has the real ellipsis
                    assert(lower->fg == ht_rgb(0x00ff2f));
                    frame_at[state][step] = frame;
                } else {
                int frame = pet_frame(pet, mark->sprite.pixels);
                const ht_pet_step_t *want = &pet->loops[state][step];
                assert(frame == want->frame && mark->sprite.width == pet->w && mark->sprite.height == pet->h);
                assert(mark->x == (466 - pet->w) / 2);
                assert(!scene.runs[10].text[0] && !scene.runs[10].arc);   // no lower arc outside the scene
                // The 56 px box's top is where the same face with step 0 puts it: only dy moves the pet.
                ht_character_face_t g = f; g.clock_ms = 1;
                ht_scene_t rest; ht_scene_clear(&rest, 0);
                ht_character_face(&rest, &c, &g, 0xffff, state == HT_PET_DONE ? "Done." : "");
                assert(mark->y - rest.runs[1].y == want->dy - pet->loops[state][0].dy);
                frame_at[state][step] = frame;
                }
                ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                int ink = 0;
                for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
                    if (full[y * HT_WIDTH + x]) {
                        ink++;
                        assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
                    }
                assert(ink > 0);
            }
        // Each state moves: more than one frame (or a hop) over its loop, and one step_ms changes it.
        for (int state = 0; state < HT_PET_STATES; state++) {
            bool moves = false;
            for (int step = 0; step < HT_PET_STEPS; step++)
                moves |= frame_at[state][step] != frame_at[state][0] ||
                         pet->loops[state][step].dy != pet->loops[state][0].dy;
            assert(moves);
        }
        // The working legs change on the next step: 90 ms later is a different frame.
        assert(frame_at[HT_PET_WORKING][0] != frame_at[HT_PET_WORKING][3]);
        assert(frame_at[HT_PET_IDLE][0] != frame_at[HT_PET_IDLE][20]);   // the blink

        // clock_ms 0, and a sleeping or offline mood, hold idle step 0 whatever the state says.
        ht_character_face_t held[3] = {
            {.recipient = "x", .engine = eng, .activity = "Working", .elapsed = 5, .asking = true,
             .mood = HT_CHARACTER_WORKING, .clock_ms = 0},
            {.recipient = "x", .engine = eng, .activity = "", .mood = HT_CHARACTER_ASLEEP, .clock_ms = 5000},
            {.recipient = "x", .engine = eng, .activity = "", .mood = HT_CHARACTER_OFFLINE, .clock_ms = 5000},
        };
        for (int k = 0; k < 3; k++) {
            held[k].status = ""; held[k].hint = ""; held[k].detail = "";
            ht_scene_t scene; ht_scene_clear(&scene, 0);
            ht_character_face(&scene, &c, &held[k], 0xffff, "");
            assert(scene.count == 1 + 1 + 1 + 4 + 1 + 2 + 1);
            assert(pet_frame(pet, scene.runs[1].sprite.pixels) == pet->loops[HT_PET_IDLE][0].frame);
            assert(!ht_focus_pet_next_ms(&held[k], ""));
        }

        // An engine without a pet keeps its own mark, in any state, and has no pet clock.
        ht_character_face_t other = {.recipient = "x", .engine = "cursor", .activity = "Working",
            .elapsed = 5, .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_WORKING,
            .clock_ms = 4321};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &other, 0xffff, "");
        assert(scene.runs[1].sprite.pixels == ht_icon_engine56[2].px && scene.runs[1].sprite.width == 56);
        assert(!ht_focus_pet_next_ms(&other, ""));

        // The time the face next changes: a later clock, where the drawn frame or hop really differs,
        // and nothing differs one ms before it.
        ht_character_face_t w = {.recipient = "x", .engine = eng, .activity = "Working",
            .status = "", .hint = "", .detail = "", .elapsed = 5, .mood = HT_CHARACTER_WORKING};
        for (unsigned k = 0; k < 40; k++) {
            w.clock_ms = k * 90 + 1;
            uint32_t next = ht_focus_pet_next_ms(&w, "");
            assert(next > w.clock_ms);
            ht_character_face_t at = w, before = w;
            at.clock_ms = next; before.clock_ms = next - 1;
            ht_scene_t sa, sb, sw; ht_scene_clear(&sa, 0); ht_scene_clear(&sb, 0); ht_scene_clear(&sw, 0);
            ht_character_face(&sa, &c, &at, 0xffff, "");
            ht_character_face(&sb, &c, &before, 0xffff, "");
            ht_character_face(&sw, &c, &w, 0xffff, "");
            assert(sa.runs[1].sprite.pixels != sb.runs[1].sprite.pixels || sa.runs[1].sprite.cells != sb.runs[1].sprite.cells ||
                   sa.runs[1].y != sb.runs[1].y);
            assert(sb.runs[1].sprite.pixels == sw.runs[1].sprite.pixels && sb.runs[1].sprite.cells == sw.runs[1].sprite.cells &&
                   sb.runs[1].y == sw.runs[1].y);
        }
        w.clock_ms = 1; w.mood = HT_CHARACTER_IDLE; w.activity = "";
        assert(ht_focus_pet_next_ms(&w, "") > 1);
        // On the voice screen it is the sending scene's schedule (Claude's) or nothing, not the pet's.
        w.voice = true;
        {   // the next frame change from step 0 (equal frames are skipped), or nothing without a scene
            const ht_pet_scene_t *sn = pet_of(eng)->sending_scene;
            uint32_t want = 0;
            for (unsigned i = 1; sn && i <= sn->steps && !want; i++)
                if (sn->loop[i % sn->steps] != sn->loop[0]) want = i * sn->step_ms;
            assert(ht_focus_pet_next_ms(&w, "") == want);
        }
        w.voice = false;
        w.clock_ms = 0; assert(!ht_focus_pet_next_ms(&w, ""));
    }

    /*
     * THE SCENES (Claude and Codex; Codex's own checks follow). Working: the cooking Clawd is the one large run, centred, the status
     * goes to the lower arc in green and the centred status is empty; the other states keep the run
     * count. An engine without scenes (Cursor) still draws its mark and the centred green line.
     */
    {
        const ht_pet_t *cp = pet_of("claude");
        assert(cp && cp->working_scene && cp->listening_scene && cp->sending_scene);
        const ht_pet_t *xp = pet_of("codex");
        assert(xp && xp->working_scene && xp->listening_scene && xp->sending_scene && !pet_of("cursor"));
        const ht_pet_scene_t *ws = cp->working_scene;
        assert(ws->w == 208 && ws->h == 176 && ws->steps == 12 && ws->step_ms == 110);
        int frames_seen[12], distinct = 0;
        for (unsigned step = 0; step < ws->steps; step++) {
            ht_character_face_t f = {.recipient = "Payments refactor", .engine = "claude",
                .activity = "Coalescing", .elapsed = 34, .status = "", .hint = "", .detail = "",
                .mood = HT_CHARACTER_WORKING, .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff,
                .clock_ms = step * ws->step_ms + 1};
            ht_scene_t scene; ht_scene_clear(&scene, 0);
            ht_character_face(&scene, &c, &f, 0xffff, "");
            assert(scene.count == 11);
            int big = 0, small = 0;
            for (int i = 0; i < scene.count; i++) {
                if (scene.runs[i].sprite.width == ws->w) { big++; assert(scene.runs[i].x == (466 - ws->w) / 2); }
                if (scene.runs[i].sprite.width == cp->w || scene.runs[i].sprite.width == 56) small++;
            }
            assert(big == 1 && !small);
            assert(scene_frame(ws, scene.runs[1].sprite.cells) == ws->loop[step]);
            assert(!scene.runs[7].text[0]);
            assert(scene.runs[10].arc == 2 && scene.runs[10].fg == ht_rgb(0x00ff2f) &&
                   !strcmp(scene.runs[10].text, "Coalescing\xe2\x80\xa6 34s") &&
                   scene.runs[10].font == &ht_lv_geist_med_26.base);
            bool fresh = true;
            for (int k = 0; k < distinct; k++) fresh &= frames_seen[k] != ws->loop[step];
            if (fresh) frames_seen[distinct++] = ws->loop[step];
            ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
            for (int y = 0; y < HT_HEIGHT; y++) for (int x = 0; x < HT_WIDTH; x++)
                if (full[y * HT_WIDTH + x])
                    assert((x - 233) * (x - 233) + (y - 233) * (y - 233) < 230 * 230);
            // It is scheduled: the next change is the next step's boundary.
            assert(ht_focus_pet_next_ms(&f, "") == (step + 1) * ws->step_ms);
        }
        assert(distinct == 12);
        // The other states and the recap keep the small pet, the centred line and no lower arc.
        ht_character_face_t g = {.recipient = "x", .engine = "claude", .activity = "Coalescing", .elapsed = 34,
            .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_WORKING, .clock_ms = 500};
        ht_scene_t scene; ht_scene_clear(&scene, 0);
        ht_character_face(&scene, &c, &g, 0xffff, "Done.");
        assert(scene.count == 11 && scene.runs[1].sprite.width == cp->w && !scene.runs[10].text[0]);
        g.asking = true; ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &g, 0xffff, "");
        assert(scene.count == 11 && scene.runs[1].sprite.width == cp->w && scene.runs[7].text[0] && !scene.runs[10].text[0]);

        // An engine without scenes working: its mark, the centred geist_med_32 green line, nothing on the lower arc.
        ht_character_face_t x = {.recipient = "x", .engine = "cursor", .activity = "Coalescing", .elapsed = 34,
            .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_WORKING, .clock_ms = 500,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &x, 0xffff, "");
        assert(scene.count == 11 && scene.runs[1].sprite.width == 56);
        assert(scene.runs[7].font == &ht_lv_geist_med_32.base && scene.runs[7].fg == ht_rgb(0x00ff2f) &&
               scene.runs[7].y == 233 - ht_lv_geist_med_32.base.height / 2 &&
               !strcmp(scene.runs[7].text, "Coalescing\xe2\x80\xa6 34s"));
        assert(!scene.runs[10].text[0] && !scene.runs[10].arc);

        // Listening: Claude draws a scene frame, no bars; an engine without one draws its seven bars.
        const ht_pet_scene_t *ls = cp->listening_scene;
        assert(ls->w == 192 && ls->h == 192 && ls->steps == 8 && ls->step_ms == 140);
        const uint8_t *shown[HT_PET_SCENE_LEVELS][8];
        for (unsigned level = 0; level < HT_PET_SCENE_LEVELS; level++)
            for (unsigned step = 0; step < 8; step++) {
                ht_character_face_t v = {.recipient = "", .tab = "", .engine = "claude", .activity = "",
                    .status = "", .hint = "", .detail = "", .voice = true, .mood = HT_CHARACTER_LISTENING,
                    .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff, .clock_ms = step * ls->step_ms + 1};
                v.pose.level = level;
                ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &v, 0xffff, "");
                assert(scene.count == 11);
                int icons = 0, bars = 0;
                for (int i = 0; i < scene.count; i++) {
                    if (scene.runs[i].sprite.width == ls->w) {
                        icons++; shown[level][step] = scene.runs[i].sprite.cells;
                        assert(scene.runs[i].x == (466 - ls->w) / 2 && scene.runs[i].y == 233 - ls->h / 2 - 6);
                    }
                    if (scene.runs[i].font == &ht_wave && scene.runs[i].text[0]) bars++;
                }
                assert(icons == 1 && !bars);
                assert(scene_frame(ls, shown[level][step]) == ls->loop[level * ls->steps + step]);
                ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                for (int y = 0; y < HT_HEIGHT; y++) for (int xx = 0; xx < HT_WIDTH; xx++)
                    if (full[y * HT_WIDTH + xx])
                        assert((xx - 233) * (xx - 233) + (y - 233) * (y - 233) < 230 * 230);
            }
        assert(shown[0][1] != shown[4][1] && shown[4][0] != shown[4][1] && shown[0][0] != shown[0][1]);
        // Level 0 does not nod, so it matches level 1 on the steps where level 1 is level.
        ht_character_face_t sending = {.recipient = "", .tab = "", .engine = "claude", .activity = "", .status = "",
            .hint = "", .detail = "", .voice = true, .mood = HT_CHARACTER_WORKING, .clock_ms = 1,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &sending, 0xffff, "");
        assert(scene.count == 11);
        for (int i = 0; i < scene.count; i++) assert(scene.runs[i].sprite.width != ls->w);   // the sending scene, not this one
        // Sending: Claude draws the rocket scene, centred, with no sparkle runs; the frame follows the clock.
        {
            const ht_pet_scene_t *ss = cp->sending_scene;
            assert(ss && ss->w == 208 && ss->h == 208 && ss->steps == 12 && ss->step_ms == 120);
            const uint8_t *seen[12];
            for (unsigned step = 0; step < ss->steps; step++) {
                ht_character_face_t v = sending; v.clock_ms = step * ss->step_ms + 1;
                ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &v, 0xffff, "");
                assert(scene.count == 11);
                int icons = 0, sparks = 0;
                for (int i = 0; i < scene.count; i++) {
                    if (scene.runs[i].sprite.width == ss->w && scene.runs[i].sprite.cells) {
                        icons++; seen[step] = scene.runs[i].sprite.cells;
                        assert(scene.runs[i].x == (466 - ss->w) / 2 && scene.runs[i].y == 233 - ss->h / 2);
                        assert(scene.runs[i].sprite.cells == ss->frames[ss->loop[step]].cells);
                    }
                    sparks += scene.runs[i].font == &ht_spark && scene.runs[i].text[0];
                }
                assert(icons == 1 && !sparks);
                ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                int ink = 0;
                for (int y = 0; y < HT_HEIGHT; y++) for (int xx = 0; xx < HT_WIDTH; xx++)
                    if (full[y * HT_WIDTH + xx]) {
                        ink++;
                        assert((xx - 233) * (xx - 233) + (y - 233) * (y - 233) < 230 * 230);
                    }
                assert(ink > 0);
            }
            assert(seen[0] != seen[1] && seen[3] != seen[8]);
            // A held clock (quiet, asleep) draws no scene: the sparkles.
            ht_character_face_t h = sending; h.clock_ms = 0;
            ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &h, 0xffff, "");
            int sparks = 0;
            for (int i = 0; i < scene.count; i++) {
                assert(scene.runs[i].sprite.width != ss->w);
                sparks += scene.runs[i].font == &ht_spark && scene.runs[i].text[0];
            }
            assert(scene.count == 11 && sparks == 3);
        }
        // An engine without scenes and an empty engine, sending: still the three sparkles.
        for (int e = 0; e < 2; e++) {
            ht_character_face_t v = sending; v.engine = e ? "" : "cursor";
            ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &v, 0xffff, "");
            int sparks = 0;
            for (int i = 0; i < scene.count; i++) sparks += scene.runs[i].font == &ht_spark && scene.runs[i].text[0];
            assert(scene.count == 11 && sparks == 3);
        }
        ht_character_face_t cx = sending; cx.engine = "cursor"; cx.mood = HT_CHARACTER_LISTENING; cx.pose.level = 3;
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &cx, 0xffff, "");
        int bars = 0;
        for (int i = 0; i < scene.count; i++) bars += scene.runs[i].font == &ht_wave && scene.runs[i].text[0];
        assert(scene.count == 11 && bars == 7);
        cx.engine = "";
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &cx, 0xffff, "");
        bars = 0;
        for (int i = 0; i < scene.count; i++) bars += scene.runs[i].font == &ht_wave && scene.runs[i].text[0];
        assert(bars == 7);

        // Codex (the owner's robot pack): the same three scenes, each with an overlay sprite after its own run
        // (working: the first recap line's slot; voice: the first sparkle's), ink inside r 230, the run count constant.
        {
            ht_character_face_t base = {.recipient = "Payments refactor", .tab = "", .engine = "codex", .activity = "Coalescing",
                .elapsed = 34, .status = "", .hint = "", .detail = "", .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
            ht_scene_t cs_;
            static const int bias_[3] = {4, -6, 0};
            static const unsigned steps_[3] = {28, 15, 15}, ms_[3] = {120, 80, 140};
            static const int w_[3] = {166, 151, 137};
            for (int kind = 0; kind < 3; kind++) {          // 0 working, 1 listening, 2 sending
                const ht_pet_scene_t *sc = kind == 0 ? xp->working_scene : kind == 1 ? xp->listening_scene : xp->sending_scene;
                const ht_pet_overlay_t *ov = sc->overlay;
                unsigned levels = kind == 1 ? HT_PET_SCENE_LEVELS : 1;
                assert(ov && !cp->working_scene->overlay && !cp->listening_scene->overlay && !cp->sending_scene->overlay);
                assert(sc->steps == steps_[kind] && sc->step_ms == ms_[kind] && sc->w == w_[kind] && sc->h == 170);
                assert(sc->frames[0].cell == 1 && ov->frames[0].cell == 1 && !sc->frames[0].palette[0] && !ov->frames[0].palette[0]);
                const int scene_run = kind == 0 ? 1 : 7, overlay_run = kind == 0 ? 3 : 8;
                for (unsigned level = 0; level < levels; level++)
                    for (unsigned step = 0; step < sc->steps; step++) {
                        ht_character_face_t v = base;
                        v.clock_ms = step * sc->step_ms + 1; v.pose.level = level;
                        if (kind == 0) v.mood = HT_CHARACTER_WORKING;
                        else { v.voice = true; v.mood = kind == 1 ? HT_CHARACTER_LISTENING : HT_CHARACTER_WORKING; }
                        ht_scene_clear(&cs_, 0); ht_character_face(&cs_, &c, &v, 0xffff, "");
                        assert(cs_.count == 11);
                        unsigned i = level * sc->steps + step;
                        int ox = (466 - sc->w) / 2 + sc->dx, oy = 233 - sc->h / 2 + bias_[kind] + sc->dy;
                        const ht_run_t *sr = &cs_.runs[scene_run], *orun = &cs_.runs[overlay_run];
                        assert(sr->sprite.cells == sc->frames[sc->loop[i]].cells && sr->sprite.width == sc->w && sr->sprite.height == sc->h);
                        assert(sr->x == ox && sr->y == oy);
                        assert(orun->sprite.cells == ov->frames[ov->loop[i]].cells);
                        assert(orun->x == ox + ov->at[i][0] && orun->y == oy + ov->at[i][1]);
                        for (int k = 0; k < cs_.count; k++) {
                            if (k != scene_run && k != overlay_run) assert(!cs_.runs[k].sprite.width);   // no pet, no mark
                            assert(!(cs_.runs[k].font == &ht_spark && cs_.runs[k].text[0]) && !(cs_.runs[k].font == &ht_wave && cs_.runs[k].text[0]));
                        }
                        if (kind == 0) {        // status on the lower arc, nothing centred
                            assert(!cs_.runs[7].text[0] && cs_.runs[10].arc == 2 &&
                                   !strcmp(cs_.runs[10].text, "Coalescing\xe2\x80\xa6 34s") && !cs_.runs[10].gained);
                            assert(!cs_.runs[4].text[0] && !cs_.runs[5].text[0] && !cs_.runs[6].text[0]);   // the other recap lines stay empty
                        }
                        if (kind == 1) assert(cs_.runs[0].arc == 2 && !strcmp(cs_.runs[0].text, "Listening") && cs_.runs[0].gained);
                        ht_raster(&cs_, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                        int ink = 0;
                        for (int y = 0; y < HT_HEIGHT; y++) for (int xx = 0; xx < HT_WIDTH; xx++)
                            if (full[y * HT_WIDTH + xx]) {
                                ink++;
                                assert((xx - 233) * (xx - 233) + (y - 233) * (y - 233) < 230 * 230);
                            }
                        assert(ink > 0);
                        // next_ms: the boundary of the next step that draws a different frame or overlay (equal ones are skipped).
                        uint32_t want = 0;
                        for (unsigned q = 1; q <= sc->steps && !want; q++) {
                            unsigned j = level * sc->steps + (step + q) % sc->steps;
                            if (sc->loop[j] != sc->loop[i] || ov->loop[j] != ov->loop[i] || ov->at[j][0] != ov->at[i][0] || ov->at[j][1] != ov->at[i][1])
                                want = (step + q) * sc->step_ms;
                        }
                        uint32_t got = ht_focus_pet_next_ms(&v, "");
                        if (kind == 1) assert(got > v.clock_ms && got <= want);   // or the word's sweep step, if that comes first
                        else assert(want && got == want);
                    }
            }
            // The overlays move: the sandboxes blink and tick over, the bars follow the level, the plane flies off.
            {
                const ht_pet_overlay_t *wo = xp->working_scene->overlay, *lo = xp->listening_scene->overlay, *so = xp->sending_scene->overlay;
                assert(wo->loop[0] != wo->loop[1] && wo->loop[0] != wo->loop[7] && wo->loop[7] != wo->loop[14] && wo->loop[14] != wo->loop[21]);
                bool flat = true, moving = false, quiet = false;
                for (unsigned step = 0; step < 15; step++) {
                    flat &= lo->loop[step] == lo->loop[0];
                    moving |= lo->loop[4 * 15 + step] != lo->loop[4 * 15];
                    quiet |= lo->loop[15 + step] != lo->loop[0];
                }
                assert(flat && moving && quiet);   // level 0 is flat, level 1 already swings, level 4 swings most
                assert(so->frames[so->loop[14]].cols == 1 && so->frames[so->loop[14]].rows == 1 && so->frames[so->loop[0]].cols > 1);
                assert(so->at[12][0] > so->at[8][0] && so->at[12][1] < so->at[8][1] && so->loop[3] != so->loop[4]);
            }
            // Sending on the voice screen redraws at the pet's next frame change, a held clock draws sparkles.
            ht_character_face_t h = base; h.voice = true; h.mood = HT_CHARACTER_WORKING; h.clock_ms = 0;
            assert(!ht_focus_pet_next_ms(&h, ""));
            ht_scene_clear(&cs_, 0); ht_character_face(&cs_, &c, &h, 0xffff, "");
            int sparks = 0;
            for (int i = 0; i < cs_.count; i++) {
                assert(!cs_.runs[i].sprite.width);
                sparks += cs_.runs[i].font == &ht_spark && cs_.runs[i].text[0];
            }
            assert(cs_.count == 11 && sparks == 3);
        }
        // THE LISTENING WORD (Claude and Codex): "Listening", Geist Medium 26, green, on the lower arc in the first bar's
        // slot, brightness per letter by rhythm B; 11 runs listening, sending, held and plain.
        for (int e = 0; e < 2; e++) {
            const char *eng = e ? "codex" : "claude";
            ht_character_face_t v = {.recipient = "", .tab = "", .engine = eng, .activity = "", .status = "", .hint = "",
                .detail = "", .voice = true, .mood = HT_CHARACTER_LISTENING, .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
            for (uint32_t clock = 1; clock < 2700; clock += 13) {
                v.clock_ms = clock;
                ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &v, 0xffff, "");
                assert(scene.count == 11);
                int words = 0;
                for (int i = 0; i < scene.count; i++) if (scene.runs[i].arc == 2) {
                    words++;
                    const ht_run_t *r = &scene.runs[i];
                    assert(i == 0 && !strcmp(r->text, "Listening") && r->font == &ht_lv_geist_med_26.base && r->fg == ht_rgb(0x00ff2f) && r->gained);
                    // rhythm B at the 65 ms step the clock is in: dim 30 %, a band two letters wide, sweeping 900 ms, resting 400 ms.
                    unsigned t = clock % 1300 / 65 * 65;
                    for (int g = 0; g < 9; g++) {
                        double head = t < 900 ? -2 + 13.0 * t / 900 : -99, d = g - head < 0 ? head - g : g - head;
                        double want = 255 * (0.3 + 0.7 * (1 - d / 2 > 0 ? 1 - d / 2 : 0));
                        assert(r->gain[g] + 1.0 >= want && r->gain[g] - 1.0 <= want);
                    }
                    if (t == 130) assert(r->gain[0] > 230 && r->gain[8] < 90);        // the band has reached the first letter
                    if (t >= 910) for (int g = 0; g < 9; g++) assert(r->gain[g] == 76);   // at rest
                }
                assert(words == 1);
            }
            // The word moves on its own clock: every 65 ms while sweeping, then once for the rest (or the scene's own frame).
            v.clock_ms = 100; assert(ht_focus_pet_next_ms(&v, "") == 130);
            v.clock_ms = 1000; assert(ht_focus_pet_next_ms(&v, "") > 1000 && ht_focus_pet_next_ms(&v, "") <= 1365);   // the rest ends at 1365 at the latest
            v.clock_ms = 1; assert(ht_focus_pet_next_ms(&v, "") == 65);
            v.clock_ms = 0; assert(!ht_focus_pet_next_ms(&v, ""));
            // Eleven runs whichever voice state: sending, a held clock, an engine without scenes, none; no word outside listening.
            for (int mode = 0; mode < 4; mode++) {
                ht_character_face_t w = v;
                w.clock_ms = 700;
                if (mode == 0) w.mood = HT_CHARACTER_WORKING;
                if (mode == 1) w.clock_ms = 0;
                if (mode == 2) w.engine = "cursor";
                if (mode == 3) w.engine = "";
                ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &w, 0xffff, "");
                assert(scene.count == 11);
                for (int i = 0; i < scene.count; i++) assert(mode == 1 ? scene.runs[i].arc == (i == 0 ? 2 : 0) : !scene.runs[i].arc);
            }
        }
    }

    /*
     * THE CELL SPRITES on glass. Every frame of both scenes, rasterised through ht_cell_sprite, is the
     * independent per-pixel expansion of its cells (a transparent cell leaves the background), whole
     * and clipped to rects that cut through cells; and changing frame damages only the sprite's rect.
     */
    {
        const ht_pet_t *cp = pet_of("claude");
        const ht_pet_scene_t *scs[2] = {cp->working_scene, cp->listening_scene};
        for (int w = 0; w < 2; w++) {
            const ht_pet_scene_t *sc = scs[w];
            unsigned nf = 0;
            for (unsigned i = 0; i < sc->steps * (w ? HT_PET_SCENE_LEVELS : 1u); i++)
                if (sc->loop[i] >= nf) nf = sc->loop[i] + 1u;
            int x0 = (HT_WIDTH - sc->w) / 2, y0 = (HT_HEIGHT - sc->h) / 2;
            const ht_rect_t cuts[] = {{(int16_t)(x0 + 3), (int16_t)(y0 + 5), 61, 47},
                {(int16_t)(x0 - 10), (int16_t)(y0 + 100), 50, 200}, {(int16_t)(x0 + sc->w - 5), (int16_t)(y0 + 1), 20, 9},
                {(int16_t)(x0 + 7), (int16_t)(y0 + 7), 1, 1}};
            for (unsigned k = 0; k < nf; k++) {
                const ht_cell_frame_t *fr = &sc->frames[k];
                assert(fr->cell == 8 && fr->cols * fr->cell == sc->w && fr->rows * fr->cell == sc->h);
                assert(!fr->palette[0]);
                ht_scene_t scene; ht_scene_clear(&scene, 0x1234);
                assert(ht_cell_sprite(&scene, x0, y0, fr) && scene.count == 1);
                assert(scene.runs[0].sprite.width == sc->w && scene.runs[0].sprite.height == sc->h);
                ht_raster(&scene, (ht_rect_t){0, 0, HT_WIDTH, HT_HEIGHT}, full);
                int inked = 0;
                for (int y = y0; y < y0 + sc->h; y++) for (int x = x0; x < x0 + sc->w; x++) {
                    unsigned idx = fr->cells[((y - y0) / 8) * fr->cols + (x - x0) / 8];
                    uint16_t want = idx ? fr->palette[idx] : 0x3412;   // the background, in panel order
                    if (full[y * HT_WIDTH + x] != want) { fprintf(stderr, "px %d,%d idx %u got %04x want %04x\n", x, y, idx, full[y * HT_WIDTH + x], want); assert(0); }
                    inked += idx != 0;
                }
                assert(inked);
                for (unsigned q = 0; q < sizeof cuts / sizeof cuts[0]; q++) {
                    ht_rect_t r = cuts[q];
                    ht_raster(&scene, r, partial);
                    for (int y = 0; y < r.h; y++) for (int x = 0; x < r.w; x++)
                        assert(partial[y * r.w + x] == full[(r.y + y) * HT_WIDTH + r.x + x]);
                }
                // The next frame repaints inside the sprite's rect and nowhere else.
                const ht_cell_frame_t *nx = &sc->frames[(k + 1) % nf];
                ht_scene_t after; ht_scene_clear(&after, 0x1234);
                ht_cell_sprite(&after, x0, y0, nx);
                ht_damage_t dmg;
                ht_damage(&scene, &after, &dmg);
                if (nx == fr) assert(!dmg.count);
                else {
                    // Banded on 2 px rows and columns: the sprite's rect plus at most 1 px of rounding.
                    assert(dmg.count >= 1 && dmg.pixels <= (uint32_t)(sc->w + 2) * (sc->h + 2));
                    for (int i = 0; i < dmg.count; i++)
                        assert(dmg.rect[i].x >= x0 - 1 && dmg.rect[i].y >= y0 - 1 &&
                               dmg.rect[i].x + dmg.rect[i].w <= x0 + sc->w + 1 && dmg.rect[i].y + dmg.rect[i].h <= y0 + sc->h + 1);
                }
            }
        }
    }

    /*
     * THE BOTTOM EDGE IS TAKEN (a footer control; the bell steps up instead): the working scene stays, its status is a
     * straight centred geist_med_28 line at y 334 in the same slot (the run count never moves) and the
     * lower arc is the empty placeholder. Long verbs keep their seconds, on the arc and on the line.
     */
    {
        const ht_pet_t *cp = pet_of("claude");
        ht_character_face_t f = {.recipient = "x", .engine = "claude", .activity = "Coalescing", .elapsed = 34,
            .status = "", .hint = "", .detail = "", .mood = HT_CHARACTER_WORKING, .clock_ms = 500,
            .foreground = 0xffff, .dim = 0x8410, .ink = 0xffff};
        ht_scene_t scene;
        {
            f.footer_action = true;
            ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &f, 0xffff, "");
            assert(scene.count == 11 && scene.runs[1].sprite.width == cp->working_scene->w);
            const ht_run_t *line = &scene.runs[7];
            assert(!line->arc && line->font == &ht_lv_geist_med_28.base && line->y == 334 &&
                   line->fg == ht_rgb(0x00ff2f) && !strcmp(line->text, "Coalescing\xe2\x80\xa6 34s"));
            assert(line->x + line->w / 2 >= 232 && line->x + line->w / 2 <= 234);
            assert(!scene.runs[10].text[0] && !scene.runs[10].arc);
            for (int i = 0; i < scene.count; i++) assert(scene.runs[i].arc != 2);
        }
        // Not taken: the arc, no straight line. Both fit a long verb with its seconds.
        f.footer_action = false; f.activity = "Running firmware checks";
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &f, 0xffff, "");
        size_t n = strlen(scene.runs[10].text);
        assert(scene.runs[10].arc == 2 && n >= 3 && !strcmp(scene.runs[10].text + n - 3, "34s") && ht_arc_measure(&ht_arc_geist_prop, scene.runs[10].text) <= HT_ARC_SPAN);
        assert(strstr(scene.runs[10].text, "Running firmw") && !scene.runs[7].text[0]);
        f.elapsed = 65;
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &f, 0xffff, "");
        n = strlen(scene.runs[10].text);
        assert(!strcmp(scene.runs[10].text + n - 6, "1m 05s") && ht_arc_measure(&ht_arc_geist_prop, scene.runs[10].text) <= HT_ARC_SPAN);
        f.elapsed = 34; f.activity = "Reconciling the payment ledger migration plan"; f.footer_action = true;
        ht_scene_clear(&scene, 0); ht_character_face(&scene, &c, &f, 0xffff, "");
        n = strlen(scene.runs[7].text);
        assert(!strcmp(scene.runs[7].text + n - 3, "34s") && scene.runs[7].w <= 384 && scene.runs[7].w > 300);
        assert(scene.runs[7].x >= 41 && scene.runs[7].x + scene.runs[7].w <= 41 + 384);
    }

    // The listening scene is scheduled like the working one: the next step boundary (or sweep step) while recording
    // (level 0..4 read at the moment), nothing held, or on an engine without one; sending has its own below.
    {
        const ht_pet_scene_t *ls = pet_of("claude")->listening_scene;
        for (unsigned level = 0; level < HT_PET_SCENE_LEVELS + 2; level++)
            for (unsigned step = 0; step < ls->steps; step++) {
                ht_character_face_t v = {.recipient = "", .tab = "", .engine = "claude", .activity = "", .status = "",
                    .hint = "", .detail = "", .voice = true, .mood = HT_CHARACTER_LISTENING,
                    .clock_ms = step * ls->step_ms + 1};
                v.pose.level = level;
                // The scene's next step, or the word's next sweep step (a multiple of 65 ms) if that comes first.
                uint32_t next = ht_focus_pet_next_ms(&v, "");
                assert(next > v.clock_ms && next <= (step + 1) * ls->step_ms &&
                       (next == (step + 1) * ls->step_ms || next % 65 == 0));
            }
        ht_character_face_t v = {.recipient = "", .tab = "", .engine = "claude", .activity = "", .status = "",
            .hint = "", .detail = "", .voice = true, .mood = HT_CHARACTER_LISTENING, .clock_ms = 1};
        v.clock_ms = 0; assert(!ht_focus_pet_next_ms(&v, ""));
        // Sending: the next frame change of the rocket scene; held or without a scene, nothing.
        const ht_pet_scene_t *ss = pet_of("claude")->sending_scene;
        v.mood = HT_CHARACTER_WORKING;
        for (unsigned step = 0; step < ss->steps; step++) {
            v.clock_ms = step * ss->step_ms + 1;
            uint32_t want = 0;
            for (unsigned i = 1; i <= ss->steps && !want; i++)
                if (ss->loop[(step + i) % ss->steps] != ss->loop[step]) want = (step + i) * ss->step_ms;
            assert(want && ht_focus_pet_next_ms(&v, "") == want);
        }
        v.clock_ms = 0; assert(!ht_focus_pet_next_ms(&v, ""));
        v.clock_ms = 1; v.engine = "cursor"; assert(!ht_focus_pet_next_ms(&v, ""));
        v.engine = ""; assert(!ht_focus_pet_next_ms(&v, ""));
        v.engine = "claude";
        v.mood = HT_CHARACTER_LISTENING; v.engine = "cursor"; assert(!ht_focus_pet_next_ms(&v, ""));
        v.engine = ""; assert(!ht_focus_pet_next_ms(&v, ""));
        // Frames and levels come from one count.
        assert(HT_PET_SCENE_LEVELS == 5);
    }

    // Stated as its parts rather than as a number: the curved name, the mark, the card, the recap
    // (four lines), the live status, the resting line (two lines) and the lower-arc status (the
    // working scene's). Each is emitted empty when it has nothing to say.
    assert(expected == 1 + 1 + 1 + 4 + 1 + 2 + 1);
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
