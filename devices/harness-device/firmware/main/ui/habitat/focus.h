#pragma once
#include "character_layout.h"
#include "character_types.h"

/*
 * The Focus skin: the work, not a companion.
 *
 * Tim and Tux are portraits with words arranged around them, so ht_character_layout() owns the seats
 * and hands the artwork one rectangle. Focus has no artwork — the arrangement IS the skin — so it
 * takes the whole face through the `face` pointer in character.c's registry.
 */
void ht_focus_face(ht_scene_t *s, const ht_character_face_t *f, uint8_t frame, uint16_t ink,
                   const char *recap);

/*
 * The painter half of the registry row. Focus never draws a portrait, but ht_character_portrait()
 * calls `paint` directly and every registry entry must answer it; this draws the name alone, which is
 * the only sensible thing a portrait of "no companion" can be.
 */
void ht_focus_portrait(ht_scene_t *s, const ht_character_face_t *f, uint8_t frame, uint16_t ink,
                       ht_character_size_t size, int y);

/* One frame, no motion. The only thing that animates on this face is the compositor's own shimmer. */
bool ht_focus_motion_tick(ht_character_motion_t *m, uint32_t now, ht_character_mood_t mood,
                          bool quiet, bool visible, bool down, int x, unsigned level,
                          uint32_t activity);

/*
 * The engine's badge: `out` gets its ht_engine glyph as UTF-8, `ink` its own colour as 0xRRGGBB, or 0
 * for "no colour of its own — draw it in the row's ink". False, and nothing written, for an engine
 * this build has no mark for; an unknown engine gets no badge rather than a wrong one.
 */
bool ht_focus_engine_mark(const char *engine, char out[4], uint32_t *ink);
// Where the last home face drew its tab pill (w 0: none) and its name, for ui_habitat.c's targets.
extern ht_rect_t ht_focus_pill_target, ht_focus_name_target;
// The engine's index into ht_icon_engine20 / ht_icon_engine28 (the LVGL firmware's own marks), or -1.
int ht_focus_engine_index(const char *engine);
