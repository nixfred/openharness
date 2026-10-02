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
// Focus draws in Geist (owner, 2026-10-02): no run of the scene is one of the trial's Roboto faces.
static void no_roboto(const ht_scene_t *scene)
{
    const ht_pfont_t *roboto[] = {&ht_lv_roboto_med_38, &ht_lv_roboto_med_32, &ht_lv_roboto_med_30,
        &ht_lv_roboto_med_28, &ht_lv_roboto_med_24, &ht_lv_roboto_med_22, &ht_lv_roboto_reg_38,
        &ht_lv_roboto_reg_25, &ht_lv_roboto_reg_20};
    for (int i = 0; i < scene->count; i++) {
        for (unsigned g = 0; g < sizeof roboto / sizeof roboto[0]; g++) assert(scene->runs[i].font != &roboto[g]->base);
        assert(scene->runs[i].font != &ht_rmono_24);
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
            if (r->arc == 1) { arc++; assert(r->font == &ht_mono_24); }
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
            assert(name->arc == 1 && !strcmp(name->text, "Payments refactor") && name->font == &ht_mono_24);
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
                assert(scene.count == 1 + 1 + 1 + 4 + 1 + 2);
                const ht_run_t *mark = &scene.runs[1];
                int frame = pet_frame(pet, mark->sprite.pixels);
                const ht_pet_step_t *want = &pet->loops[state][step];
                assert(frame == want->frame && mark->sprite.width == pet->w && mark->sprite.height == pet->h);
                assert(mark->x == (466 - pet->w) / 2);
                // The 56 px box's top is where the same face with step 0 puts it: only dy moves the pet.
                ht_character_face_t g = f; g.clock_ms = 1;
                ht_scene_t rest; ht_scene_clear(&rest, 0);
                ht_character_face(&rest, &c, &g, 0xffff, state == HT_PET_DONE ? "Done." : "");
                assert(mark->y - rest.runs[1].y == want->dy - pet->loops[state][0].dy);
                frame_at[state][step] = frame;
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
            assert(scene.count == 1 + 1 + 1 + 4 + 1 + 2);
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
            assert(sa.runs[1].sprite.pixels != sb.runs[1].sprite.pixels || sa.runs[1].y != sb.runs[1].y);
            assert(sb.runs[1].sprite.pixels == sw.runs[1].sprite.pixels && sb.runs[1].y == sw.runs[1].y);
        }
        w.clock_ms = 1; w.mood = HT_CHARACTER_IDLE; w.activity = "";
        assert(ht_focus_pet_next_ms(&w, "") > 1);
        w.voice = true; assert(!ht_focus_pet_next_ms(&w, "")); w.voice = false;
        w.clock_ms = 0; assert(!ht_focus_pet_next_ms(&w, ""));
    }

    // Stated as its parts rather than as a number: the curved name, the mark, the card, the recap
    // (four lines), the live status and the resting line (two lines). Each is emitted empty when it
    // has nothing to say.
    assert(expected == 1 + 1 + 1 + 4 + 1 + 2);
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
