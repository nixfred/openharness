#pragma once
// nixfred graphics (nixfred/DESIGN.md, "Device"): the faces built from rings, arcs and the logo mask.
// Pure scene composition on terminal.h: no ESP-IDF, no allocation, host-testable (test_nixfred_ring.c).
#include "terminal.h"

// The Harness mark as a one-colour alpha mask (nixfred_logo.c, generated from
// docs/branding/app-logo/harness-logo-4.svg). A host-supplied logo would replace this pointer: the cable
// protocol carries no logo today, so this is the hook, not a feature.
enum { NIXFRED_LOGO_W = 150, NIXFRED_LOGO_H = 150 };
extern const uint8_t nixfred_logo_alpha[NIXFRED_LOGO_W * NIXFRED_LOGO_H];

// Rim geometry shared by every face: the state ring sits just inside the glass.
enum { NIXFRED_RIM_IN = 223, NIXFRED_RIM_OUT = 231, NIXFRED_SCAN_STEPS = 8 };

// Boot / loading / firmware-transfer face: glow logo in the centre, wordmark under it. `pct` 0..100 fills
// the rim clockwise (a transfer); `pct` < 0 draws a scanner segment at `scan_step` (one lap a second),
// so a stuck boot reads as a stopped line.
void nixfred_boot_face(ht_scene_t *f, uint16_t accent, uint16_t ink, int pct, int scan_step);

// Question / permission chrome: the state ring on the rim with a soft glow inside it, and a badge at
// 12 o'clock: the person the agent is waiting on (initials when the host supplies them, else a neutral
// figure), plus a lock glyph beside it for a permission prompt. Yellow waits, red is permission.
void nixfred_attention(ht_scene_t *f, bool permission, const char *initials, uint16_t yellow, uint16_t red,
                       uint16_t ink);

// ---- slice 2: the fleet, done, failed, voice, panic and plan faces --------------------------------------

// One agent's state on the rim, in ascending priority (the busiest sort nearest 12 o'clock).
typedef enum {
    NIXFRED_IDLE, NIXFRED_OFFLINE, NIXFRED_DONE, NIXFRED_WORKING, NIXFRED_WAITING, NIXFRED_FAILED,
    NIXFRED_PERMISSION, NIXFRED_STATES
} nixfred_state_t;
typedef struct { uint16_t accent, yellow, red, green, ink; } nixfred_palette_t;

// Most agents the rim draws one arc each for; a larger fleet shares the last slot's colour with no gap.
enum { NIXFRED_RIM_MAX = 16, NIXFRED_PHASES = 16 };
// The fleet on the rim: one arc per agent in its state colour, busiest centred at 12 o'clock and the rest
// alternating right, left, right. `span` is how much of the turn the fleet takes (HT_TURN for all of
// it; less leaves a gap centred at 6 o'clock). `phase` 0..15 moves a working arc's sweep and a waiting
// arc's breath. Run count depends only on the states, never the phase, so an animation step repaints
// the rim sectors that moved and nothing else. Offline arcs are dotted (three runs each) while the
// scene has room; otherwise every agent is one run.
// `fail_ms` is how long ago the newest failure landed (UINT32_MAX for none): within
// NIXFRED_FAIL_FLASH_MS every failed arc flashes twice, then holds as a thin red arc.
void nixfred_fleet_rim(ht_scene_t *f, const uint8_t *state, int n, int span, unsigned phase,
                       uint32_t fail_ms, const nixfred_palette_t *p);
// The fleet in a few characters: the most urgent state's glyph and how many agents share it, over the
// fleet size, for example "? 2/9" (two waiting of nine). `color` is that state's colour. Empty when n==0.
void nixfred_fleet_summary(char *out, int size, uint16_t *color, const uint8_t *state, int n,
                           const nixfred_palette_t *p);

// Done: the ring closes in from the rim to a solid dot at `cx, cy` (`permille` 0..1000 of the motion).
void nixfred_done_collapse(ht_scene_t *f, int cx, int cy, int permille, uint16_t green);

// Failed: two quick flashes of the whole rim (120 ms on, 120 ms off, twice), then a steady thin ring.
// Always two runs; an "off" frame draws them in the canvas colour.
enum { NIXFRED_FAIL_FLASH_MS = 480 };
void nixfred_failed_rim(ht_scene_t *f, uint32_t since_ms, uint16_t red);

// Voice: recording is a level ring on the rim whose thickness follows the microphone (`level` 0..4);
// sending is an arc sweeping clockwise (`step` 0..23, one lap a second). Always two runs.
enum { NIXFRED_VOICE_STEPS = 24 };
void nixfred_voice_rim(ht_scene_t *f, bool listening, unsigned level, unsigned step, uint16_t green,
                       uint16_t accent);

// Panic stop: every ring collapses together to one red dot (`since_ms` < 600), then the dot holds.
enum { NIXFRED_PANIC_MS = 600 };
void nixfred_panic(ht_scene_t *f, uint32_t since_ms, int stopped, uint16_t red, uint16_t ink,
                   uint16_t dim);

// Subscription plans: one small arc per plan inside `start`..`start+span` (a sector of the rim), the dim
// track and a fill of `used` permille in the plan's tone colour. At most 4 plans.
enum { NIXFRED_PLANS_MAX = 4 };
void nixfred_plans_rim(ht_scene_t *f, int start, int span, const uint16_t *used_permille,
                       const uint16_t *tone, int n);

// ---- slice 3: ambient, connecting, pairing, machines, swarms, cards, transitions, plans -----------------

// Idle face when nothing needs anyone: one particle per agent orbiting the hub (with a comet tail on its
// orbit) in its state colour, the time of day, a faint scan band and grain rings at 6..8 percent. The
// whole face sits `drift` px off centre (burn-in: the caller moves it 1 px a minute). `orbit` is the
// orbit's angle in 1/4096 turn (the caller advances it faster the more agents work). `scan_y` is the
// band's row. `clock` is "HH:MM" or empty; `line` is a short fleet line under it. One run count per
// agent count, so a frame step is a damage diff of the particles and the band only.
enum { NIXFRED_AMBIENT_MAX = 12 };
void nixfred_ambient(ht_scene_t *f, const uint8_t *state, int n, int orbit, int scan_y, int drift_x,
                     int drift_y, const char *clock, const char *line, const nixfred_palette_t *p);

// Connecting: a dotted ring that draws itself clockwise, one dot per retry (24 dots a lap; past that
// every dot is lit and the caller prints the count).
enum { NIXFRED_CONNECT_DOTS = 24 };
void nixfred_connect_dots(ht_scene_t *f, int retries, uint16_t accent, uint16_t dim);

// Hexagon outlines, rasterised once into static masks (PSRAM on the device). Pairing: a large hexagon
// whose six edges pulse in turn (`step` 0..11, two steps an edge) until `answered`, then all solid.
void nixfred_pair_hex(ht_scene_t *f, int cx, int cy, unsigned step, bool answered, uint16_t accent);
// A machine tile: hexagon in `edge` colour, an outer glow hexagon when `glow` (selected), and up to two
// capability arcs around it (permille, -1 for none): `load` (accent, amber from 800, red from 950) and
// `aux` (battery or VRAM, thinner, dim ink). Radius of the tile's hexagon: NIXFRED_TILE_R.
enum { NIXFRED_TILE_R = 42, NIXFRED_PAIR_R = 118 };
void nixfred_machine_tile(ht_scene_t *f, int cx, int cy, uint16_t edge, bool glow, int load, int aux,
                          const nixfred_palette_t *p);

// The colour a state is drawn in (the rim's palette), and its 55..100 percent breath at `phase`.
uint16_t nixfred_state_color(uint8_t state, unsigned phase, uint16_t background, const nixfred_palette_t *p);

// Swarm: a ring of rings. The parent ring at the centre (radius `r_parent`) in the most urgent child's
// colour (glowing when someone waits), the children on an orbit of `r_orbit`, each its own state: a
// working child is an open ring whose gap turns with `phase`, the others solid. At most 12 children.
void nixfred_swarm(ht_scene_t *f, int cx, int cy, int r_parent, int r_orbit, const uint8_t *child, int n,
                   unsigned phase, const nixfred_palette_t *p);

// Notification card sliding up from the rim: top edge at `y`, the state colour on its left edge, the
// agent name and one line of summary. `trail` 0..1000 is the dismiss motion: the card rises and leaves
// a short trail of fading bars under it. Always the same run count.
enum { NIXFRED_CARD_X = 63, NIXFRED_CARD_W = 340, NIXFRED_CARD_H = 76 };
void nixfred_card(ht_scene_t *f, int y, uint16_t edge, const char *name, const char *summary, int trail,
                  uint16_t ink, uint16_t dim);

// Collision: two agents' rings side by side, a warning triangle between them over the top, their names
// under the rings. `phase` breathes the triangle.
void nixfred_collision(ht_scene_t *f, const char *a, uint8_t sa, const char *b, uint8_t sb, unsigned phase,
                       const nixfred_palette_t *p);

// Transition: a rim sweep from 12 o'clock, `permille` 0..1000 of its lap, bright head over a fading tail.
// Two runs, drawn last so it passes over whatever face it introduces.
enum { NIXFRED_SWEEP_MS = 320 };
void nixfred_sweep(ht_scene_t *f, int permille, uint16_t accent);

// Subscription detail: one big gauge arc per plan (concentric, outermost first), track and used fill in
// the tone colour, the next plan glowing with a marker at the end of its arc, and a centre legend
// "NAME  62%  +8" per plan (banked signed, + under pace). At most NIXFRED_PLANS_MAX.
typedef struct { char name[10]; uint16_t used; int16_t banked; uint16_t tone; } nixfred_plan_t;
void nixfred_plans_face(ht_scene_t *f, const nixfred_plan_t *plan, int n, int pick, uint16_t ink,
                        uint16_t dim);

// ---- slice 4: hold anywhere for the session list ---------------------------------------------------------

// Hold feedback: a dim track all the way round the rim and a thick accent arc filling clockwise from 12
// o'clock as the finger stays down (`permille` 0..1000 of the hold). Always two runs, so each step of the
// fill is a damage diff of the rim sector it grew into. Drawn last, over whatever face is showing.
void nixfred_hold_rim(ht_scene_t *f, int permille, uint16_t accent);

// One line centred on `cx`, cut to whole letters with ".." to fit `max_w` px.
void nixfred_label(ht_scene_t *f, int cx, int y, const ht_font_t *font, uint16_t ink, const char *text, int max_w);
