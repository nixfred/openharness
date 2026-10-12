#include "pro_turn.h"

#include <stdatomic.h>

static atomic_bool s_turned = ATOMIC_VAR_INIT(
#if defined(POD_PANEL_TURN) && POD_PANEL_TURN == 180
    true
#else
    false
#endif
);

bool pro_turn_get(void) { return atomic_load(&s_turned); }
void pro_turn_set(bool turned) { atomic_store(&s_turned, turned); }
