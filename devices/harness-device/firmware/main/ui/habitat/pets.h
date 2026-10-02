#pragma once
#include "terminal.h"

/*
 * The pets on the Focus agent screen (pets.c, scripts/gen_pets.py): per engine, four loops of 24 steps,
 * each step a de-duplicated frame and a vertical offset in px, advanced every step_ms[state].
 */
typedef enum { HT_PET_IDLE, HT_PET_WORKING, HT_PET_DONE, HT_PET_ASKING, HT_PET_STATES } ht_pet_state_t;
typedef struct { uint8_t frame; int8_t dy; } ht_pet_step_t;
enum { HT_PET_STEPS = 24 };

typedef struct {
    const char *engine;                          // focus.c ENGINES name: "claude", "codex"
    uint16_t w, h;                               // frame size
    const ht_icon_t *frames;
    const ht_pet_step_t (*loops)[HT_PET_STEPS];  // [HT_PET_STATES][HT_PET_STEPS]
    const uint16_t *step_ms;                     // [HT_PET_STATES]
} ht_pet_t;
extern const ht_pet_t ht_pets[];
extern const unsigned ht_pet_count;
