#pragma once
// Allocation-free text compositor. No ESP-IDF, LVGL or floating point.
// Rasterization owns two bounded curved-text caches; call it from one renderer.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
// THE FACE. One device, one size: the 466 round dial.
//
// This was a -D from the build for as long as there were two boards; it is a literal again now that the
// Pro has its own firmware. Kept as a named pair rather than 466 sprinkled through the compositor,
// because the arithmetic that reads it — chords, the rim annulus, the damage bands — is about a face
// and not about a number.
#define HT_WIDTH 466
#define HT_HEIGHT 466
// 56, not 40 (nixfred graphics slice 2): a creature face uses up to 39 runs, and the fleet rim adds one
// arc per agent (Fred runs nine) plus the plan arcs. Each run is its own damage sector, which is what
// keeps an animated rim from repainting the face. Two static scenes, so this is ~6 KB of internal RAM.
#define HT_RUNS 56
#define HT_TEXT_BYTES 128
#define HT_DAMAGE_MAX 24
typedef struct {
    uint16_t first, last;
    uint8_t width, height;
    const uint8_t *pixels;
} ht_font_t;
// One glyph of a PROPORTIONAL face, exactly as lv_font_conv stored it: the ink box as a continuous
// 4-bit stream (high nibble first, no row padding), its advance in 1/16 px, where the box sits.
typedef struct {
    uint32_t offset;   // into the face's pixels, in bytes
    uint16_t adv;      // 1/16 px, before kerning
    uint8_t w, h;      // ink box
    int8_t ox, oy;     // ink box from the pen's x, and from the top of the line
} ht_glyph_t;
/*
 * A PROPORTIONAL FACE — the Focus skin's Geist and Montserrat, the LVGL firmware's own fonts copied
 * glyph for glyph (scripts/gen_lvgl_assets.py). It IS an ht_font_t, as its first member, so a run
 * carries it like any other font; `first > last` is what marks it, a range no fixed-cell atlas can
 * have. A separate type rather than fields appended to ht_font_t so every fixed-cell atlas keeps its
 * positional initializer. `base.width` is the space's advance and `base.height` the line; pass
 * `&face.base` wherever a font is wanted.
 */
typedef struct ht_pfont {
    ht_font_t base;
    const ht_glyph_t *glyphs;
    const uint16_t *codes;        // sorted; glyphs[i] draws codes[i]
    uint16_t count;
    uint8_t ascent;               // the baseline, from the top of the line (line - LVGL base_line)
    const uint8_t *kern_left, *kern_right;   // each glyph's kern class, 0 for none
    const int8_t *kern_values;    // [(left - 1) * kern_right_count + right - 1], 1/16 px
    uint8_t kern_right_count;
    const struct ht_pfont *fallback;   // for a codepoint this face does not have, or NULL
} ht_pfont_t;
static inline const ht_pfont_t *ht_pfont(const ht_font_t *f)
{
    return f && f->first > f->last ? (const ht_pfont_t *)f : NULL;
}
extern const ht_font_t ht_mono_16, ht_mono_20, ht_mono_24, ht_mono_28, ht_pixel_40;
// The Focus skin's faces: the LVGL firmware's own (lvgl_fonts.c; see assets/lvgl/SPEC.md).
extern const ht_pfont_t ht_lv_geist_med_38, ht_lv_geist_med_32, ht_lv_geist_med_28, ht_lv_geist_reg_38,
    ht_lv_geist_reg_25, ht_lv_geist_reg_20, ht_lv_montserrat_24, ht_lv_montserrat_22, ht_lv_montserrat_14;
// FontAwesome in LVGL's Montserrat: the bell and the close cross.
#define HT_LV_BELL  "\xef\x83\xb3"
#define HT_LV_CROSS "\xef\x80\x8d"
// A full-colour icon from the LVGL firmware (lvgl_icons.c): RGB565 in panel order plus alpha.
typedef struct { uint16_t w, h; const uint16_t *px; const uint8_t *a; } ht_icon_t;
// The engines' marks in focus.c's ENGINES order: 20 px as the inbox drew them, and 27 px — LVGL's
// own 28/20 scaling of the same 20 px art, as the header drew it. And the microphone.
extern const ht_icon_t ht_icon_engine20[14], ht_icon_engine28[14], ht_icon_mic;
// Precomputed curved-label and larger inbox navigation glyphs.
extern const ht_font_t ht_open_20, ht_nav_32;
extern const ht_font_t ht_open_24, ht_right_24, ht_bell_24;
extern const uint8_t ht_mono_24_ink[224][4], ht_open_24_ink[1][4], ht_right_24_ink[1][4], ht_bell_24_ink[1][4];
extern const uint8_t ht_mono_20_ink[224][4], ht_open_20_ink[1][4];
extern const ht_font_t ht_right_20, ht_right_28, ht_open_28;
extern const uint8_t ht_right_20_ink[1][4];
// One authored outline bell in a normal terminal cell, not an emoji font.
#define HT_BELL "\xee\x80\x80"
#define HT_SPARK "\xee\x80\x82"
// One bar of the recording waveform, in sixteen heights — ht_wave's cell is ONE bar, not the whole
// meter, so the seven bars are seven runs placed at the old firmware's own 22.4 px pitch and each
// picks its own height. HT_WAVE_LEVELS - 1 is the tallest, 121 px, which is what bar four rested at.
#define HT_WAVE_FIRST  0xe010u
#define HT_WAVE_LEVELS 16
extern const ht_font_t ht_bell_20, ht_bell_28;
extern const ht_font_t ht_bell_footer, ht_done_28, ht_failed_28;
// The voice screen: one sparkle, and six bar heights that a row of nine draws a waveform with.
extern const ht_font_t ht_spark, ht_wave;
// One badge per engine, from U+E020 in the order focus.c lists them. 24 px in a 38 px cell, so a
// mark sits beside a name in ht_mono_28 without being squeezed into a letter's width.
extern const ht_font_t ht_engine;
#define HT_ENGINE_FIRST 0xe020u
#define HT_DONE "\xe2\x9c\x93"
#define HT_FAILED "\xe2\x9c\x97"
extern const uint8_t ht_bell_20_ink[1][4];
// The lock's dot is the only 40 px glyph used by the daily UI. Keep its exact
// pixels without retaining the other 94 glyphs of the gallery font in flash.
extern const ht_font_t ht_lock_dot;
// Vietnamese, one atlas per mono size. ht_font_t carries a single contiguous range and a dense
// 32..0x1EF9 would be 7,898 cells, so these cover 0x1EA0..0x1EF9 plus an eight-cell tail holding
// the letters that live outside it (A-breve, D-stroke, O-horn, U-horn and their lowercase).
// Same fixed cell as the mono face they stand in for; terminal.c routes them in glyph_font().
extern const ht_font_t ht_viet_16, ht_viet_20, ht_viet_24, ht_viet_28;
typedef struct {
    int16_t x, y, w, h;
} ht_rect_t;
typedef struct {
    const uint16_t *pixels;
    const uint8_t *alpha;
    const void *asset;
    uint32_t revision;
    uint16_t width, height;
    uint8_t species, colour, mark;
    // Blend as LVGL's lv_color_24_16_mix does — (src * a + dst * (255 - a)) >> 8 per 565 channel —
    // for the icons taken from the LVGL firmware, so they come out as that dial drew them.
    bool lvgl;
} ht_sprite_t;
typedef struct {
    int16_t x, y, w;
    uint8_t arc; // 0 = straight, 1 = upper arc, 2 = lower arc
    uint8_t shimmer; // 0 = steady ink, 1..21 = cached-mask highlight sweep
    uint16_t fg, bg;
    const ht_font_t *font;
    char text[HT_TEXT_BYTES];
    // Optional immutable RGB565 foreground per text cell (straight runs only).
    // At least as many entries as text cells; storage outlives both scenes.
    const uint16_t *colors;
    ht_sprite_t sprite;
    // A ROUNDED BOX rather than text when `box.h` is set: w x h at x, y, corner radius, fill and an
    // optional 1 px border (border == fill for none), antialiased at the corners. ht_box() makes one.
    struct { uint16_t h, fill, border; uint8_t radius; } box;
    // A RING (nixfred): an antialiased annulus, or an arc of one, centred on x, y, drawn in `fg` when
    // `ring.outer` is set. Angles are in 1/4096 of a turn, 0 at 12 o'clock, clockwise; a sweep of 4096
    // (or more) is the whole ring. ht_ring() makes one. Integer only, no tables beyond one quarter sine.
    struct { uint16_t inner, outer, start, sweep; } ring;
} ht_run_t;
typedef struct {
    uint16_t background;
    uint8_t count;
    ht_run_t runs[HT_RUNS];
} ht_scene_t;
enum { HT_ARC_COLS = 26, HT_ARC_CELL_WIDTH = 15, HT_ARC_CELL_HEIGHT = 32, HT_ARC_X = 25, HT_ARC_Y = 12,
       HT_ARC_WIDTH = 416, HT_ARC_HEIGHT = 128 };
typedef struct {
    uint8_t count;
    ht_rect_t rect[HT_DAMAGE_MAX];
    uint32_t pixels;
} ht_damage_t;
uint16_t ht_rgb(unsigned rgb);
void ht_scene_clear(ht_scene_t *scene, uint16_t background);
bool ht_text(ht_scene_t *scene, int x, int y, int width, const ht_font_t *font, uint16_t fg,
             uint16_t bg, const char *text);
// Prevalidated printable ASCII assets: exactly `cells` readable bytes, one cell
// each. Copies into the scene; no UTF-8 scan, allocation, or retained pointer.
bool ht_ascii_text(ht_scene_t *scene, int x, int y, int width, const ht_font_t *font,
                   uint16_t fg, uint16_t bg, const char *text, size_t cells);
void ht_center(ht_scene_t *scene, int y, const ht_font_t *font, uint16_t fg, const char *text);
// One icon, as a sprite run at x, y.
bool ht_icon(ht_scene_t *scene, int x, int y, const ht_icon_t *icon);
// A rounded box — the Focus skin's pills and cards. Colours are already mixed over what they sit on.
bool ht_box(ht_scene_t *scene, int x, int y, int w, int h, int radius, uint16_t fill, uint16_t border);
// A ring or arc (nixfred graphics): see ht_run_t.ring. `sweep` >= HT_TURN draws the whole annulus.
enum { HT_TURN = 4096 };
bool ht_ring(ht_scene_t *scene, int cx, int cy, int inner, int outer, int start, int sweep, uint16_t color);
// A one-colour ALPHA MASK drawn in `color`: the sprite path with no pixel array (nixfred logo).
bool ht_mask(ht_scene_t *scene, int x, int y, int w, int h, const uint8_t *alpha, uint16_t color);
// PROPORTIONAL TEXT. The width `text` would take in `font` (mono: glyphs x width). A line of it that
// fits `width` px, breaking after a word where it can (the cursor moves past the spaces it ends on).
// And `text` fitted to `width`: whole if it fits, else as much as does and "…"; returns its width.
int ht_measure(const ht_font_t *font, const char *text);
/*
 * An LVGL label, laid out the way LVGL 9.5 lays one out: its word wrap, centre alignment and
 * LV_LABEL_LONG_DOT. `width` is the label's, `lines` how many it shows; with `dots` a text that needs
 * more ends in "..." on the last of them. Returns how many lines the text needed before any cut.
 * Line n is text + line[n].at for line[n].len bytes, drawn at x + line[n].x.
 */
enum { HT_LV_LINES = 5 };
typedef struct { uint16_t at, len; int16_t x, w; } ht_lv_line_t;
typedef struct { char text[320]; ht_lv_line_t line[HT_LV_LINES]; int lines, w; } ht_lv_label_t;
int ht_lv_label(ht_lv_label_t *label, const ht_font_t *font, const char *text, int width, int lines,
                bool dots);
int ht_fit_width(char *dst, size_t cap, const char *text, int width, const ht_font_t *font);
// Fixed 24 px upper/lower arcs. Text stays in the scene; each mask is cached on
// first rasterization and reused across strips, animation and color changes.
void ht_arc_title(ht_scene_t *scene, uint16_t fg, const char *text);
void ht_arc_status(ht_scene_t *scene, uint16_t fg, const char *text);
// Same conservative bounds used for damage; useful for matching curved hit areas.
ht_rect_t ht_run_bounds(const ht_run_t *run);
uint32_t ht_arc_cache_builds(void);
// A 1.28-second sweep and 0.768-second rest. Pure, wrap-safe integer clock.
uint8_t ht_shimmer_phase(uint32_t now);
uint32_t ht_shimmer_wake_ms(uint32_t now);
#ifdef DEVICE_LAYOUT_BENCH
void ht_arc_fast_sampling(bool enabled);
void ht_arc_tight_bounds(bool enabled);
void ht_damage_fast_ascii(bool enabled);
void ht_damage_banded(bool enabled);
void ht_raster_fast_ascii(bool enabled);
#endif
// Bounded small-ASCII cache. Toggle only from the renderer, for A/B profiling.
void ht_glyph_cache_enable(bool enabled);
uint32_t ht_glyph_cache_builds(void);
size_t ht_glyph_cache_bytes(void);
// Consume one word-wrapped UTF-8 line; shared by rectangular and round reading areas.
const char *ht_take_line(const char **cursor, int cells);
// Display-only normalization, before measuring/wrapping. Bounded, no allocation;
// false means the destination was truncated. Source and destination must differ.
bool ht_display_text(char *dst, size_t capacity, const char *src, const ht_font_t *font);
const char *ht_take_display_line(const char **cursor, int cells, const ht_font_t *font);
int ht_wrap(ht_scene_t *scene, int x, int y, int width, int lines, int skip, const ht_font_t *font,
            uint16_t fg, const char *text);
void ht_damage(const ht_scene_t *before, const ht_scene_t *after, ht_damage_t *out);
// Output is RGB565 in THIS BOARD'S panel order — byte-swapped for the dial's CO5300 over QSPI, native
// for the Pro's ST7703 DPI framebuffer. See panel16() in terminal.c. Buffer holds region.w * region.h.
void ht_raster(const ht_scene_t *scene, ht_rect_t region, uint16_t *out);
uint32_t ht_utf8_next(const char **cursor);
// Question/answer text must fit in full and contain glyphs available on this device.
bool ht_can_display(const char *text, const ht_font_t *font, int width, int lines);
int ht_text_rows(const char *text, const ht_font_t *font, int width);
