// Habitat: bounded state + text runs. Protocol callbacks update data, never create widgets.
#include "runtime.h"
#include "scroll.h"
#include "workspace.h"
#include "selection.h"
#include "carry.h"
#include "visit.h"
#include "form.h"
#include "draft.h"
#include "gestures.h"
#include "character.h"
#include "focus.h"
#include "perf_bench.h"
#include "command_face.h"
#include "theme.h"
#ifdef DEVICE_CREATURE_GALLERY
#include "creature_gallery.h"
static ht_gallery_t gallery;
#endif
#include "ui_screens.h"
#include "display.h"
#include "audio_client.h"
#include "audio_capture.h"
#include "config_store.h"
#include "cable_client.h"
#include "esp_attr.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_app_desc.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "cJSON.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <assert.h>
#include "nixfred_art.h"

#define NOTICES 24
#define QUESTION_MAX 4
#define OPTION_MAX 6
// FOUR ROWS, PITCH 64. Five at 56 put the last line at 112 + 4*56 + 14 + 38 = 388, two pixels into
// the footer at 390. Four at 64 end at 356 and leave it alone.
/*
 * THE LIST GEOMETRY, and it is the face's, not the circle's.
 *
 * Four rows is what a 466 circle holds between its chords. A 720 square holds EIGHT at the same 64 px
 * pitch — 112 + 8*64 = 624, with the pager below it — so on the Pro the controls list stopped needing
 * a scroll to reach most of itself while leaving a third of the glass empty.
 *
 * The widths matter as much. A settings row was 300 px of ht_mono_28, which is 300/17 = 17 CELLS:
 * "Companion / gestures" is twenty characters and arrived cut. 616 px is 36 cells, and nothing in the
 * list is that long.
 */
#define TAB_ROWS 4
#define TAB_ROW_HEIGHT 64
#define TAB_TOP 112
// Focus's pane list: six rows on a 48 px pitch.
#define PANE_PITCH 48
#define PANE_ROWS 6
#define LIST_HIT_X 59
#define LIST_HIT_W 348
#define LIST_TEXT_X 71
#define LIST_TEXT_W 324
#define SET_TEXT_X 83
#define SET_TEXT_W 300
#define PANE_MEMORY_MAX 128
#define PANE_RESULT_BYTES 1024
typedef enum {
    HOME,
    AGENTS,
    AGENT,
    READER,
    QUESTION,
    CHOICE,
    ANSWER_REVIEW,
    INBOX,
    TABS,
    MACHINES,
    VOICE,
    SELECTION,
    FORM,
    DRAFT,
    DRAFT_OPTIONS,
    SETTINGS,
    STOP,
    MODELS,
    MESSAGE,
    OTA,
    NF_PLANS,  // nixfred slice 3: the subscription detail face
    NF_HUB     // nixfred slice 5: the hub a hold anywhere opens
} view_t;
typedef enum {
    A_NONE,
    A_FIND, A_FORM, A_FORM_MAIN, A_FORM_BACK, A_FORM_SEND, A_FORM_SAY,
    A_HOME,
    A_AGENTS,
    A_AGENT,
    A_READER,
    A_QUESTION,
    A_CHOICE,
    A_ANSWER, A_QUESTION_READ, A_QUESTION_CHOICES, A_QUESTION_REVIEW, A_QUESTION_BACK, A_QUESTION_SAY,
    A_TAB_LIST,
    A_INBOX,
    A_NOTICE,
    A_TABS,
    A_TAB, A_TAB_REFRESH,
    A_MACHINES,
    A_MACHINE,
    A_VOICE,
    A_VOICE_STOP,
    A_VOICE_ABORT,
    A_PET,
    A_NAP,
    A_SETTINGS_SAVE,
    A_SETTINGS,
    A_STOP,
    A_STOP_YES,
    A_MODELS,
    A_MODEL,
    A_RECAP_DISMISS,
    A_DESKTOP,
    A_UP,
    A_DOWN,
    A_SCROLL,
    A_SELECT_BEGIN, A_SELECT_FIND, A_SELECT_EXTEND, A_SELECT_SEND, A_RETURN, A_LATEST, A_VISIT_SEND,
    A_CARRY, A_CARRY_DROP, A_CARRY_SEND,
    A_DRAFT_EDIT, A_DRAFT_APPEND, A_DRAFT_UNDO, A_DRAFT_SEND, A_DRAFT_DISCARD,
    A_DRAFT_STATE, A_DRAFT_OPTIONS, A_DRAFT_BACK, A_DRAFT_COMMAND, A_NOTICE_READ,
    A_NF_PLANS, A_NF_CARD,  // nixfred slice 3: open the plans face; open the inbox from the card
    A_NF_HUB_CLOSE          // nixfred slice 5: close the hub, back to where the hold began
} action_kind_t;
typedef struct {
    action_kind_t kind;
    int value;
    char id[ID_MAX];
    char text[192];
    uint32_t revision;
    int dy, velocity;
} action_t;
typedef struct {
    ht_rect_t rect;
    action_kind_t action;
    int value;
    bool enabled;
} hit_t;
typedef struct {
    char id[ID_MAX], session[80], preview[240], full[PANE_RESULT_BYTES], activity[100];
    uint32_t used, busy_ms, last_busy;
    bool busy, live_summary, dismissed, awaiting_result;
} pane_memory_t;
typedef struct {
    char id[ID_MAX], name[CABLE_NAME_MAX], engine[12], machine_id[ID_MAX], machine[CABLE_NAME_MAX], model[192],
        session[80];
    // The row receives the same bounded result stored in pane memory. Keeping
    // an unused 4 KB tail here wasted RAM and enlarged every roster swap.
    char preview[240], full[PANE_RESULT_BYTES], tool[100];
    bool busy, has_event, recap_ready;
    uint32_t busy_ms, last_busy;
    int tokens;
    uint32_t failed_at;   // nixfred: when its last turn ended in turn.error (0: it did not); busy clears it
} agent_t;
typedef struct {
    char key[256], prompt[256], options[OPTION_MAX][256], answer[1600];
    int count;
    bool multi, can_text;
    char draft[48];
    uint8_t selected;
} question_item_t;
typedef struct {
    char agent[ID_MAX], request[80], name[64];
    question_item_t item[QUESTION_MAX];
    int count, index, choice, drag;
    bool valid, pending, supported, loading, uncertain;
    bool permission;   // nixfred: any item carried `permission: true` (the red ring and the lock)
    char token[48], fetch[48], error[120], speech_error[96];
    uint32_t revision, deadline;
} question_t;
typedef struct {
    char agent[ID_MAX], fetch[48], token[48];
    uint8_t choices[QUESTION_MAX];
    char drafts[QUESTION_MAX][48];
    int count;
} question_submit_t;
typedef struct {
    char id[ID_MAX], summary[240];
    char token[CABLE_READ_TOKEN_MAX];
    uint32_t sent_at;
    bool pending;
    bool question, failed;
} notice_receipt_t;
static EXT_RAM_BSS_ATTR struct {
    agent_t agents[MAX_PROJECTS];
    pane_memory_t memory[PANE_MEMORY_MAX];
    uint32_t memory_serial;
    int count, active, total;
    bool connected, window, loading, ready, dirty;
    int bulk, offset;
    view_t view, voice_return;
    bool quiet, nap, focus_face, straight_title;
    ht_rect_t pressed_rect;   // the hit rect this contact went down on
    bool muted;
    int pet_pose;
    uint32_t pet_until, nap_until, last_celebration;
    cable_swarm_t tabs[SWARMS_MAX];
    int tab_count, tab_drag, pane_pos;
    char selected_tab[ID_MAX];
    cable_machine_t machines[CABLE_MAX_MACHINES];
    int machine_count;
    char selected_machine[ID_MAX], pending_machine[ID_MAX];
    uint32_t machine_deadline;
    cable_notif_t notice[NOTICES];
    notice_receipt_t notice_reads[NOTICES];
    uint8_t notice_read_next;
    uint32_t notice_revision, notice_frame;
    int notice_count;
    uint32_t notice_sequence;
    question_t q;
    char message[256], title[80], pending_focus[ID_MAX], opening_notice[ID_MAX];
    char voice_target[CABLE_NAME_MAX];
    uint32_t voice_retry_until;
    model_item_t models[48];
    int model_count;
    bool model_request;
    char model_agent[ID_MAX], model_selected[192];
    char stop_agent[ID_MAX];
    int brightness;
    uint32_t voice_started;
    bool voice_open, voice_start_pending, voice_waiting, voice_carry;
    bool voice_review, voice_review_preview, voice_draft_append, voice_search;
    uint32_t voice_draft_revision;
    int draft_drag;
    uint32_t voice_generation, voice_question_revision;
    int voice_question_index;
    uint32_t voice_wait_until;
    hit_t hits[24];
    ht_rect_t caption_arc;
    int hit_count, pressed;
    bool touch_down, touch_cancelled;
    bool touch_brake, coasting;
    uint32_t coast_until;
    uint32_t character_activity;
    uint8_t status_phase;
    int start_x, start_y, last_x, last_y;
    uint32_t touch_started;
    // nixfred graphics: the boot scanner's step, the firmware transfer's percent (-1 when none), and the
    // initials of the person a question waits on. No cable message carries initials or an avatar yet:
    // this is the hook a host-supplied identity fills, and until then the badge draws a neutral figure.
    uint8_t scan_step;
    int8_t ota_pct;
    char avatar_initials[4];
    // nixfred graphics slice 2. `nf_tick` is the animation clock's last step (0: nothing animating), so
    // an animation that ends still gets its final frame. The done motion belongs to one agent; the
    // failure flash to the newest turn.error; the MESSAGE view is a failure or a panic stop when its
    // kind says so. Plans are the daemon's `nixfred.subs` frame (stock daemons never send it).
    uint32_t nf_tick, nf_done_at, nf_fail_at, nf_msg_at;
    char nf_done_agent[ID_MAX];
    uint8_t nf_msg_kind;   // 0 plain, 1 failed, 2 panic stop
    int nf_stopped;
    int nf_plan_count;
    uint16_t nf_plan_used[NIXFRED_PLANS_MAX];
    unsigned nf_plan_tone[NIXFRED_PLANS_MAX];
    // nixfred graphics slice 3 (see the block above habitat_scene_take).
    char nf_plan_name[NIXFRED_PLANS_MAX][10];
    int16_t nf_plan_banked[NIXFRED_PLANS_MAX];
    int nf_plan_pick;
    int nf_retries;                         // connection attempts since the link was last up
    uint32_t nf_view_at, nf_orbit, nf_orbit_at, nf_scan_at;
    uint8_t nf_hold_step;                   // slice 4: how far the hold ring has filled, 0..19 (0: none)
    uint32_t nf_hub_at;                     // slice 5: when the hub opened (its bloom), 0: never
    uint8_t nf_hub_return;                  // slice 5: the view the hold began on, where closing returns
    uint8_t nf_last_view, nf_was_ambient;
    uint32_t nf_card_at, nf_card_gone;      // card arrival; when its dismiss began (0: not dismissed)
    char nf_card_id[ID_MAX], nf_card_name[CABLE_NAME_MAX], nf_card_text[96];
    int32_t nf_clock_s;                     // -1: the host never said
    uint32_t nf_clock_at;
    ui_nf_fleet_t nf_fleet;                 // lanes, this machine's capabilities, the collision alert
    uint32_t nf_alert_seen;
} s;
static QueueHandle_t actions;
static _Atomic(TaskHandle_t) reload_waiter;
static atomic_bool reload_requested;
static bool scroll_reversed;
static ht_scroll_t scroll;
static ht_selection_t selection;
static ht_workspace_t workspace;
static ht_tab_carousel_t tab_carousel;
static ht_carry_t carry;
static ht_visit_t visit;
static ht_form_t form;
static ht_draft_t draft;
static bool selection_emit(const ht_select_command_t *command, void *ctx);
static ht_gesture_t gesture;
static ht_character_t character;
static ht_character_id_t device_skin, desktop_companion = HT_CHARACTER_COUNT;
static bool follow_companion = true, companion_celebrating;
/*
 * FOCUS ONLY, until the companion skins are finished (owner, 2026-09-30). The device build defines
 * HABITAT_FOCUS_ONLY (main/CMakeLists.txt): whatever skin or companion the flash holds, the glass
 * wears Focus, the app is told so, and a frame asking for another is taken as asking for nothing.
 * The stored choice is left alone, so dropping the define brings it back as it was.
 */

static ui_companion_t desktop_identity, celebration_identity;
static uint32_t celebration_began;
static char celebration_tokens[8][96], celebration_label[64];
static unsigned celebration_next;
static void select_companion(void)
{
    const ui_companion_t *identity=companion_celebrating?&celebration_identity:&desktop_identity;
    ht_character_id_t selected=companion_celebrating?ht_character_companion(identity->id):desktop_companion;
    ht_character_select(&character, follow_companion && selected < HT_CHARACTER_COUNT ? selected : device_skin);
    character.companion_style=(ht_companion_style_t){
        .stage=!strcmp(identity->version,"0.1")?0:!strcmp(identity->version,"1.0")?1:2,
        .colour=identity->colour<0?255:(uint8_t)identity->colour,.mark=identity->mark};
}
static ht_character_caption_t home_caption;
static action_t pressed_action;
static bool queue(action_t a);
static void view(view_t v);
static bool nf_msg_keep;   // nixfred: the MESSAGE being opened is a failure or a panic stop
static const char *voice_status(void);
static uint32_t ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static void copy(char *dst, size_t cap, const char *src)
{
    if (!cap)
        return;
    if (!src)
        src = "";
    size_t n = strnlen(src, cap - 1);
    memmove(dst, src, n);
    dst[n] = 0;
}
#define COPY(dst, src) copy(dst, sizeof(dst), src)
static void recap_preview(char *dst, size_t cap, const char *src)
{
    if (!cap)
        return;
    size_t used = 0;
    bool space = false;
    const unsigned char *p = (const unsigned char *)(src ? src : "");
    while (*p) {
        if (*p == ' ' || (*p >= '\t' && *p <= '\r')) {
            space = used > 0;
            p++;
            continue;
        }
        size_t n = *p < 0x80 ? 1 : *p >= 0xc2 && *p <= 0xdf ? 2 :
                   *p >= 0xe0 && *p <= 0xef ? 3 : *p >= 0xf0 && *p <= 0xf4 ? 4 : 0;
        for (size_t i = 1; i < n; i++) {
            if ((p[i] & 0xc0) != 0x80) {
                n = 0;
                break;
            }
        }
        size_t bytes = n ? n : 1;
        if (used + space + bytes >= cap)
            break; // Keep whole UTF-8 characters, including at the buffer edge.
        if (space)
            dst[used++] = ' ';
        if (n)
            memcpy(dst + used, p, n);
        else
            dst[used] = '?';
        used += bytes;
        p += bytes;
        space = false;
    }
    // Older hosts cached their clipping marker as U+2026. Render that trailing
    // marker with the same printable-ASCII continuation sign as new recaps.
    if (used >= 3 && !memcmp(dst + used - 3, "\xe2\x80\xa6", 3)) {
        dst[used - 3] = '+';
        used -= 2;
    }
    // Give the continuation sign breathing room, including recaps cached by
    // older hosts. Do not change a literal C++ or add a second existing space.
    if (used > 1 && dst[used - 1] == '+' && dst[used - 2] != '+' &&
        dst[used - 2] != ' ' && used + 1 < cap) {
        dst[used - 1] = ' ';
        dst[used++] = '+';
    }
    dst[used] = 0;
}
static void change(void)
{
    s.dirty = true;
    habitat_render_notify();
}
/*
 * What the bell counts: unread notices about any agent EXCEPT the one on the face.
 *
 * That agent's news is already on the glass — its recap, or its question in the recap's place — so
 * counting it too told a person something else had happened, somewhere else (owner, 2026-09-30:
 * people took the +1 for another agent's news). Nothing is marked read by this: look away from that agent
 * and its unanswered question counts again, until it is answered.
 */
static unsigned notice_unread(const char *except)
{
    unsigned count = 0;
    for (int i = 0; i < s.notice_count; i++)
        count += !s.notice[i].read_on_dial && !(except && !strcmp(s.notice[i].agent_id, except));
    return count;
}
static bool notice_was_read(const cable_notif_t *n)
{
    for (int i = 0; i < NOTICES; i++) {
        const notice_receipt_t *r = &s.notice_reads[i];
        if (!strcmp(r->id, n->agent_id) && r->question == n->question &&
            r->failed == n->failed && !strcmp(r->token, n->read_token) &&
            !strcmp(r->summary, n->summary)) return true;
    }
    return false;
}
static void notice_forget_read(const char *id)
{
    for (int i = 0; i < NOTICES; i++)
        if (!strcmp(s.notice_reads[i].id, id)) s.notice_reads[i].id[0] = 0;
}
static void notice_flush_reads(uint32_t now)
{
    if (!s.connected) return;
    for (int i = 0; i < NOTICES; i++) {
        notice_receipt_t *r = &s.notice_reads[i];
        if (!r->pending || !r->id[0] || !r->token[0] ||
            (r->sent_at && now - r->sent_at < 2000)) continue;
        action_t a = {.kind = A_NOTICE_READ}; COPY(a.id, r->id); COPY(a.text, r->token);
        if (queue(a)) r->sent_at = now ? now : 1;
        // At most one tiny receipt per tick; touch/audio retain queue capacity.
        break;
    }
}
static void notice_mark_read(cable_notif_t *n)
{
    if (n->read_on_dial) return;
    int slot = -1;
    for (int i = 0; i < NOTICES; i++)
        if (!strcmp(s.notice_reads[i].id, n->agent_id)) { slot = i; break; }
    if (slot < 0) for (int i = 0; i < NOTICES; i++)
        if (!s.notice_reads[i].id[0]) { slot = i; break; }
    if (slot < 0) { slot = s.notice_read_next; s.notice_read_next = (slot + 1) % NOTICES; }
    notice_receipt_t *r = &s.notice_reads[slot];
    COPY(r->id, n->agent_id); COPY(r->summary, n->summary);
    COPY(r->token, n->read_token); r->sent_at = 0; r->pending = r->token[0] != 0;
    r->question = n->question; r->failed = n->failed;
    n->read_on_dial = true;
    notice_flush_reads(ms());
    // Read is not answered, removed or focused. Keep this exact card in place.
    change();
}
static void notice_open(void)
{
    view(s.notice_count ? INBOX : HOME);
    if (s.view == INBOX) for (int i = 0; i < s.notice_count; i++)
        if (!s.notice[i].read_on_dial) { s.offset = i; break; }
}
uint32_t habitat_scene_receipt(void)
{
    return s.notice_frame;
}
void habitat_scene_presented(uint32_t receipt)
{
    display_lock();
    // A late DMA completion must not mark a replacement message as read, nor
    // acknowledge a card hidden by the lock screen or a sleeping panel.
    if (receipt && receipt == s.notice_frame && s.view == INBOX &&
        !display_is_asleep() && s.offset >= 0 && s.offset < s.notice_count &&
        s.notice[s.offset].display_revision == receipt)
        notice_mark_read(&s.notice[s.offset]);
    display_unlock();
}
static int find(const char *id)
{
    if (!id)
        return -1;
    for (int i = 0; i < s.count; i++)
        if (!strcmp(id, s.agents[i].id))
            return i;
    return -1;
}
static agent_t *active(void)
{
    return s.active >= 0 && s.active < s.count ? &s.agents[s.active] : NULL;
}
static pane_memory_t *pane_memory(const char *id, bool create)
{
    if (!id || !*id || strnlen(id, ID_MAX) >= ID_MAX) return NULL;
    pane_memory_t *slot = NULL;
    for (int i = 0; i < PANE_MEMORY_MAX; i++) {
        pane_memory_t *m = &s.memory[i];
        if (!strcmp(m->id, id)) {
            m->used = ++s.memory_serial;
            return m;
        }
        if (!m->id[0] && !slot) slot = m;
    }
    if (!create) return NULL;
    if (!slot) {
        // Keep every on-screen pane pinned. Evict only the least recently used
        // off-tab record; the normal roster is much smaller than this cache.
        uint32_t age = 0;
        for (int i = 0; i < PANE_MEMORY_MAX; i++) {
            pane_memory_t *m = &s.memory[i];
            uint32_t elapsed = s.memory_serial - m->used;
            if (find(m->id) < 0 && (!slot || elapsed > age)) { slot = m; age = elapsed; }
        }
    }
    if (!slot) return NULL;
    memset(slot, 0, sizeof *slot);
    COPY(slot->id, id);
    slot->used = ++s.memory_serial;
    return slot;
}
static void pane_memory_apply(agent_t *a, pane_memory_t *m)
{
    if (!a || !m) return;
    if (m->busy && ms() - m->last_busy > 25000) m->busy = false;
    COPY(a->session, m->session);
    COPY(a->preview, m->preview);
    COPY(a->full, m->full);
    COPY(a->tool, m->activity);
    a->busy = m->busy;
    a->busy_ms = m->busy_ms;
    a->last_busy = m->last_busy;
    a->has_event = m->preview[0] != 0;
    a->recap_ready = a->has_event && !m->dismissed && !m->awaiting_result && !m->busy;
}
static void dismiss_result(const char *id)
{
    pane_memory_t *m = pane_memory(id, true);
    if (!m) return;
    m->dismissed = true;
    int i = find(id);
    if (i >= 0) s.agents[i].recap_ready = false;
    change();
}
static void activity_text(char *dst, size_t cap, const char *src)
{
    // Keep the engine's word; trailing spinner dots unbalance the curved label.
    // This is presentation only. Do not alter dots inside a phrase or the recap.
    while (src && (*src == ' ' || *src == '\t' || *src == '\r' || *src == '\n')) src++;
    copy(dst, cap, src);
    size_t n = strlen(dst);
    while (n && (dst[n - 1] == ' ' || dst[n - 1] == '\t' || dst[n - 1] == '\r' || dst[n - 1] == '\n')) dst[--n] = 0;
    if (n >= 3 && (!memcmp(dst + n - 3, "...", 3) ||
                   !memcmp(dst + n - 3, "\xe2\x80\xa6", 3))) { n -= 3; dst[n] = 0; }
    while (n && dst[n - 1] == ' ') dst[--n] = 0;
}

static int ensure(const char *id)
{
    if (!id || !*id || strnlen(id, ID_MAX) >= ID_MAX) return -1;
    int i = find(id);
    if (i >= 0)
        return i;
    if (s.count >= MAX_PROJECTS)
        return -1;
    i = s.count++;
    memset(&s.agents[i], 0, sizeof(agent_t));
    COPY(s.agents[i].id, id);
    pane_memory_apply(&s.agents[i], pane_memory(id, false));
    return i;
}
static void input_cancel(void)
{
    ht_gesture_cancel(&gesture);
    ht_workspace_cancel_touch(&workspace);
    ht_scroll_cancel(&scroll);
    s.coasting = false;
    ht_tab_carousel_cancel(&tab_carousel);
    s.voice_review_preview = false;
    s.nf_hold_step = 0;
    if (s.touch_down) s.touch_cancelled = true;
    s.pressed = -1;
}
static void view(view_t v)
{
    // A swipe, desktop refresh or late reply must not hide a live microphone. Only an
    // explicit finish/cancel or the matching voice result releases this screen.
    if (form.id[0] && s.view == FORM && v != FORM &&
        !(v == VOICE && s.voice_open && s.voice_return == FORM)) return;
    if (draft.page.active && v != DRAFT && v != DRAFT_OPTIONS &&
        !(v == VOICE && s.voice_open && s.voice_return == DRAFT)) return;
    if (s.voice_open && v != VOICE)
        return;
    if (v == MESSAGE && !nf_msg_keep) s.nf_msg_kind = 0; // only show_failure and a panic stop mark it
    if (carry.pending && v != SELECTION) ht_carry_close(&carry);
    if (selection.active && v != SELECTION && v != VOICE) ht_selection_close(&selection);
    if (s.view == INBOX && v != INBOX) s.opening_notice[0] = 0;
    input_cancel();
    s.voice_retry_until = 0;
    s.view = v;
    s.offset = 0;
    s.pressed = -1;
    s.pane_pos = 0;
    change();
}
static void voice_close(void)
{
    s.voice_open = s.voice_start_pending = s.voice_waiting = false;
    s.voice_carry = false;
    s.voice_review = s.voice_review_preview = false;
    s.voice_generation++; // invalidate a start still queued behind another cable action
}
static int workspace_index(const char *id)
{
    if (!id || !*id) return -1;
    for (int i=0;i<s.tab_count;i++) if (!strcmp(id,s.tabs[i].id)) return i;
    return -1;
}
static void tabs_open(void)
{
    view(TABS);
    if (s.view != TABS) return;
    ht_tab_carousel_reset(&tab_carousel, s.tab_count, workspace_index(s.selected_tab));
}
static void workspace_failed(const char *message)
{
    ht_workspace_cancel_request(&workspace);
    s.loading=false; s.active=-1;
    COPY(s.title,"Workspaces"); COPY(s.message,message); view(MESSAGE);
}
static int waiting(void)
{
    int n = 0;
    for (int i = 0; i < s.notice_count; i++)
        n += s.notice[i].question;
    return n;
}
static int working(void)
{
    int n = 0;
    for (int i = 0; i < s.count; i++)
        n += s.agents[i].busy;
    return n;
}
// The open question's prompt for this agent, as its notice carries it; NULL when it has none open.
static const char *question_prompt(const char *id)
{
    for (int i = 0; i < s.notice_count; i++)
        if (s.notice[i].question && !strcmp(id, s.notice[i].agent_id))
            return s.notice[i].summary[0] ? s.notice[i].summary : "Needs your answer";
    return NULL;
}
static bool is_question(const char *id)
{
    for (int i = 0; i < s.notice_count; i++)
        if (s.notice[i].question && !strcmp(id, s.notice[i].agent_id))
            return true;
    return false;
}
static uint16_t color(unsigned rgb)
{
    // Hardware brightness dims text and illustrated pixels equally.
    unsigned b = 100;
    if (rgb == HT_THEME_CANVAS) {
        // RGB565 has an extra green bit. Independently truncating a dim gray
        // makes it green; the neutral range has exact steps of 8.
        unsigned gray = (((rgb & 255) * b + 400) / 800) * 8;
        return ht_rgb(gray * 0x010101u);
    }
    return ht_rgb((((rgb >> 16) * b / 100) << 16) | ((((rgb >> 8) & 255) * b / 100) << 8) |
                  ((rgb & 255) * b / 100));
}
// Which ground this skin stands on. One answer for the whole glass, not per screen: the inbox, lists
// and settings under Focus are on the same black as its home face, as they are in its design.
#define BG color(character.id == HT_CHARACTER_FOCUS ? HT_THEME_FOCUS_CANVAS : HT_THEME_CANVAS)
#define FG color(HT_THEME_TEXT)
#define DIM color(HT_THEME_SECONDARY)
#define ACCENT color(HT_THEME_ACCENT)
#define ERROR color(HT_THEME_ERROR)
#define SEL color(HT_THEME_SELECTION)
/*
 * THE INTERFACE FONT LIVES IN THESE THREE HELPERS AND NOWHERE ELSE.
 *
 * ht_mono_28 is a 17 x 38 cell against mono_20's 12 x 28 — 42% wider and 36% taller, the nearest step
 * fonts.c holds; there is no mono_30, and a true +50% would mean generating one.
 *
 * Everything downstream is arithmetic on the cell, so the bump is neither free nor local: a run holds
 * width / 17 characters instead of width / 12 — a THIRD fewer on every line — and a row is 38 tall.
 * The screens below are re-seated for that, not merely re-fonted.
 *
 * The two ARCS keep mono_20 deliberately: their cell pitch is baked into arc_trig[32][2] on a 205 px
 * radius and their bounds come from ht_mono_20_ink[], so a different cell there is a different table.
 */
/*
 * Centre a block of width `w` on the face. One face now, so this is arithmetic rather than a seam —
 * kept because a centred block written as a literal x is a number nobody can check.
 */
#define FACE_CX(w) ((HT_WIDTH - (w)) / 2)
#define UI_FONT (&ht_mono_28)
static void text(ht_scene_t *f, int x, int y, int w, const char *t, uint16_t c)
{
    ht_text(f, x, y, w, UI_FONT, c, BG, t);
}
static void center(ht_scene_t *f, int y, const char *t, uint16_t c)
{
    ht_center(f, y, UI_FONT, c, t);
}
// The boot / loading / transfer face (nixfred/DESIGN.md): the glowing Harness mark, and the rim either
// filling with the transfer's percent or carrying a scanner that moves once a second, so a stuck boot is
// a stopped line rather than a static wordmark that looks the same alive or hung.
static void render_brand(ht_scene_t *f)
{
    nixfred_boot_face(f, ACCENT, FG, s.view == OTA ? s.ota_pct : -1, s.scan_step);
    if (s.view != OTA && !s.connected && s.nf_retries > 0) {
        // nixfred: one dot per connection attempt; past a lap, the count.
        nixfred_connect_dots(f, s.nf_retries, ACCENT, color(0x262626));
        if (s.nf_retries > 1) {
            char line[16];
            snprintf(line, sizeof line, "retry %d", s.nf_retries - 1);
            ht_center(f, 352, &ht_mono_20, DIM, line);
        }
    }
}
static bool brand_visible(void)
{
    return !display_is_asleep() && (s.view == OTA || (s.view == HOME && (!s.connected || s.loading)));
}
// Waiting (yellow) or permission (red, with the lock) around every question screen.
static void question_chrome(ht_scene_t *f)
{
    nixfred_attention(f, s.q.permission, s.avatar_initials, color(HT_THEME_QUESTION), color(HT_THEME_FAILED), FG);
}
/*
 * nixfred graphics slice 2 (nixfred/DESIGN.md, "Device"): the fleet on the rim, the done motion, the
 * failure flash, the voice ring and the panic stop. Everything is drawn from state the dial already
 * holds; the animation clock below is the only thing that schedules frames, and only while something
 * on the glass moves.
 */
enum { NF_DONE_CLOSE_MS = 600, NF_DONE_SLIDE_MS = 500, NF_DONE_SLIDE_PX = 48, NF_FAILED_HOLD_MS = 30 * 60 * 1000,
       NF_FLEET_SPAN = HT_TURN * 3 / 4, NF_PHASE_MS = 125 };
static nixfred_palette_t nf_palette(void)
{
    return (nixfred_palette_t){.accent = ACCENT, .yellow = color(HT_THEME_QUESTION), .red = color(HT_THEME_FAILED),
                               .green = color(HT_THEME_DONE), .ink = FG};
}
static uint8_t nf_state(agent_t *a, uint32_t now)
{
    if (is_question(a->id))
        return s.q.permission && !strcmp(s.q.agent, a->id) ? NIXFRED_PERMISSION : NIXFRED_WAITING;
    if (a->busy) { a->failed_at = 0; return NIXFRED_WORKING; }
    if (a->failed_at && now - a->failed_at < NF_FAILED_HOLD_MS) return NIXFRED_FAILED;
    for (int i = 0; i < s.notice_count; i++)
        if (!s.notice[i].question && !s.notice[i].read_on_dial && !strcmp(s.notice[i].agent_id, a->id))
            return s.notice[i].failed ? NIXFRED_FAILED : NIXFRED_DONE;
    if (a->recap_ready) return NIXFRED_DONE;
    for (int i = 0; i < s.machine_count; i++)
        if (a->machine_id[0] && !strcmp(s.machines[i].id, a->machine_id))
            return !strcmp(s.machines[i].state, "offline") ? NIXFRED_OFFLINE : NIXFRED_IDLE;
    return NIXFRED_IDLE;
}
static int nf_states(uint8_t *out, int max, uint32_t now)
{
    int n = s.count < max ? s.count : max;
    for (int i = 0; i < n; i++) out[i] = nf_state(&s.agents[i], now);
    return n;
}
static bool nf_home_live(void)
{
    return s.view == HOME && s.connected && !s.loading && !display_is_asleep();
}
static bool nf_done_running(uint32_t now)
{
    agent_t *a = active();
    return s.nf_done_at && nf_home_live() && a && !strcmp(a->id, s.nf_done_agent) &&
        now - s.nf_done_at < NF_DONE_CLOSE_MS + NF_DONE_SLIDE_MS;
}
// How often the glass needs a new frame right now, in ms; 0 when nothing nixfred draws is moving.
static uint32_t nf3_period(uint32_t now);
static uint32_t nf2_period(uint32_t now);
// Slice 2's clock and slice 3's, whichever needs the glass sooner.
static uint32_t nf_period(uint32_t now)
{
    if (display_is_asleep()) return 0;
    uint32_t a = nf2_period(now), b = nf3_period(now);
    return !a ? b : !b ? a : a < b ? a : b;
}
static uint32_t nf2_period(uint32_t now)
{
    if (s.view == MESSAGE && s.nf_msg_kind && now - s.nf_msg_at < NIXFRED_PANIC_MS + 40) return 30;
    if (s.view == VOICE) return 42;
    if (!nf_home_live()) return 0;
    if (nf_done_running(now)) return 30;
    if (s.nf_fail_at && now - s.nf_fail_at < NIXFRED_FAIL_FLASH_MS + 40) return 40;
    if (s.quiet || s.nap) return 0;
    for (int i = 0; i < s.count && i < NIXFRED_RIM_MAX; i++) {
        uint8_t st = nf_state(&s.agents[i], now);
        if (st == NIXFRED_WORKING || st == NIXFRED_WAITING) return NF_PHASE_MS;
    }
    return 0;
}
static unsigned nf_plan_color(unsigned tone)
{
    static const unsigned tones[] = {HT_THEME_SECONDARY, HT_THEME_DONE, HT_THEME_ACCENT, 0xffb000u, HT_THEME_FAILED};
    return tones[tone < sizeof tones / sizeof *tones ? tone : 0];
}
// The fleet rim, the plans under it and the one-line summary; drawn last on the home face.
static void nf_home_rim(ht_scene_t *f, uint32_t now, bool summary, int summary_y)
{
    uint8_t st[NIXFRED_RIM_MAX];
    int n = nf_states(st, NIXFRED_RIM_MAX, now);
    nixfred_palette_t p = nf_palette();
    unsigned phase = s.quiet || s.nap ? 0 : (now / NF_PHASE_MS) % NIXFRED_PHASES;
    uint32_t fail = s.nf_fail_at ? now - s.nf_fail_at : UINT32_MAX;
    nixfred_fleet_rim(f, st, n, NF_FLEET_SPAN, phase, fail, &p);
    if (s.nf_plan_count > 0) {
        uint16_t tone[NIXFRED_PLANS_MAX];
        for (int i = 0; i < s.nf_plan_count; i++) tone[i] = color(nf_plan_color(s.nf_plan_tone[i]));
        nixfred_plans_rim(f, NF_FLEET_SPAN / 2 + 60, HT_TURN - NF_FLEET_SPAN - 120, s.nf_plan_used, tone,
                          s.nf_plan_count);
    }
    if (summary && n > 1) {
        char line[16]; uint16_t ink = FG;
        nixfred_fleet_summary(line, sizeof line, &ink, st, n, &p);
        ht_center(f, summary_y, &ht_mono_20, ink, line);
    }
}
static void nf_message_chrome(ht_scene_t *f, uint32_t now)
{
    if (s.nf_msg_kind == 1) nixfred_failed_rim(f, now - s.nf_msg_at, color(HT_THEME_FAILED));
}
// A failure the person should see as one (the red flashes), rather than a plain message.
static void show_failure(const char *title, const char *detail)
{
    COPY(s.title, title);
    COPY(s.message, detail);
    s.nf_msg_kind = 1;
    s.nf_msg_at = ms() | 1;
    nf_msg_keep = true; view(MESSAGE); nf_msg_keep = false;
}
static void control(ht_scene_t *f, int x, int y, int w, const char *label, action_kind_t a,
                    int value, bool enabled)
{
    if (s.hit_count >= 24)
        return;
    int n = s.hit_count++;
    // 66, not 60: the target is the line plus a thumb's margin, and the line is ten pixels taller now.
    // Keeping 60 would have made the control smaller than its own text.
    s.hits[n] = (hit_t){{x, y - 14, w, 66}, a, value, enabled};
    ht_text(f, x, y, w, UI_FONT, enabled ? (a == A_STOP_YES ? ERROR : n == s.pressed ? ACCENT : FG) : DIM,
            n == s.pressed ? SEL : BG, label);
}
static bool home_footer(action_kind_t action)
{
    // A_VOICE is the Focus face's [ say ]. It belongs here rather than on the A_PET path because a
    // bracket control is pressed and released like every other one, while A_PET reads a TAP as a boop
    // and only starts speech on a 650 ms hold — which is the creature's gesture, not a button's.
    return action == A_TABS || action == A_INBOX || action == A_AGENTS || action == A_RETURN ||
           action == A_CARRY_DROP || action == A_VOICE || action == A_TAB_LIST;
}
static bool hit_contains(const hit_t *hit, int x, int y, bool surface)
{
    ht_rect_t r = hit->rect;
    if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return true;
    if (!surface || hit->action != A_AGENTS || s.straight_title) return false;
    r = s.caption_arc;
    if (x < r.x || x >= r.x + r.w || y < r.y || y >= r.y + r.h) return false;
    int dx = x - 233, dy = y - 233, radius = dx * dx + dy * dy;
    // Follow the top label's visible extent without stealing the central
    // companion. Long labels descend beyond the broad target at the top.
    return y < 233 && radius >= 180 * 180 && radius <= 233 * 233;
}
static void footer_control(ht_scene_t *f, int x, int w, const char *label,
                           action_kind_t action, bool enabled)
{
    if (s.hit_count >= 24) return;
    int n = s.hit_count++;
    bool inbox = action == A_INBOX;
    s.hits[n] = (hit_t){{x, (inbox ? 359 : 389), w, inbox ? 80 : 50}, action, 0, enabled};
    // These short footer labels are ASCII. The two targets stay separate and
    // retain a full finger-height hit area even at the bottom of the circle.
    int width = (int)strlen(label) * ht_mono_20.width;
    if (inbox && width > 276) width = 276;
    ht_text(f, x + (w - width) / 2, (inbox ? 385 : 399), width, &ht_mono_20,
            enabled ? (inbox || n == s.pressed ? ACCENT : FG) : DIM,
            inbox && n == s.pressed ? SEL : BG, label);
}
static void heading(ht_scene_t *f, const char *title)
{
    control(f, 87, 67, 48, "<", A_HOME, 0, true);
    text(f, 147, 67, 252, title, FG);
}
/*
 * THE COMPANION SCREEN IS GONE, and so are Brightness and Sound from the list.
 *
 * Four rows is what a 466 circle holds between its chords, and every preference the device kept was
 * spending one of them. They live in the desktop app now (Settings > Autonomous robots), which is the
 * one surface with room to state a setting properly - see ui_settings_apply. What the glass keeps is
 * ACTIONS: things you do here because here is where your hand is. Nap is one, which is why it moved
 * into the list rather than leaving with the screen it was on.
 *
 * The settings themselves are unchanged in NVS and still applied. Only their screens went.
 */
static ht_character_mood_t character_mood(void)
{
    if (!s.connected)
        return HT_CHARACTER_OFFLINE;
    if (waiting())
        return HT_CHARACTER_ATTENTION;
    if (s.nap)
        return HT_CHARACTER_ASLEEP;
    if (!s.quiet && (s.pet_pose == 1 || s.pet_pose == 2))
        return HT_CHARACTER_BOOPED;
    if (!s.quiet && s.pet_pose == 3)
        return HT_CHARACTER_DONE;
    if (working() > 0)
        return HT_CHARACTER_WORKING;
    return HT_CHARACTER_IDLE;
}
static bool home_caption_rotates(void)
{
    const agent_t *a = active();
    return (s.view == HOME || s.view == AGENT) && a && a->busy && s.connected &&
        !s.loading && !s.nap && !s.quiet && !display_is_asleep() &&
        !s.voice_retry_until && !carry.active && !carry.error[0] && !visit.available;
}
static bool home_caption_tick(uint32_t now)
{
    // A caption's long end letters are part of its touch target. Do not
    // replace them with a shorter activity label while a finger is down.
    if (s.touch_down && !s.touch_cancelled && home_caption.initialized) return false;
    const agent_t *a = active();
    return ht_character_caption_tick(&home_caption, now, a ? a->id : "", home_caption_rotates());
}
static bool status_animated(void)
{
    if (s.nap || s.quiet || display_is_asleep() || s.touch_down)
        return false;
    if (s.view == VOICE) return !s.voice_review_preview && voice_status()[0];
    return home_caption_rotates() && home_caption.activity && !s.straight_title;
}
static unsigned status_speed(void)
{
    return s.view == VOICE && !s.voice_start_pending && !s.voice_waiting &&
        audio_client_recording() ? 2 : 1;
}
static uint32_t status_wake_ms(uint32_t now)
{
    unsigned speed = status_speed();
    return (ht_shimmer_wake_ms(now * speed) + speed - 1) / speed;
}
static void dispatch(action_t a);   // the hold below acts at once; defined with the other actions
// The session list: Focus's pane list (the AGENTS view), scrolled so the active agent is in sight.
static void agents_open(void)
{
    view(AGENTS);
    if (s.view != AGENTS) return;
    int last = s.count > TAB_ROWS ? s.count - TAB_ROWS : 0;
    s.offset = s.active - TAB_ROWS / 2;
    if (s.offset > last) s.offset = last;
    if (s.offset < 0) s.offset = 0;
}
/*
 * nixfred slice 4: HOLD ANYWHERE (slice 5: for the hub; slice 4 opened the session list).
 *
 * A still finger held NF_HOLD_MS opens the hub (nf_hub_open) while it is still down; the rest of that contact
 * is consumed, so lifting or sliding afterwards selects nothing. From NF_HOLD_SHOW_MS a ring fills on the
 * rim so the hold is visibly registering; a tap (350 ms at most) shows at most a sliver of it.
 *
 * The existing long presses win where they live, so the hold is not armed:
 *   - in VOICE (hold = stop into a draft review), DRAFT / DRAFT_OPTIONS (hold on Edit = options), FORM,
 *     SELECTION and ANSWER_REVIEW (an answer or text being composed), OTA, and NF_HUB (already there);
 *   - on the home or agent face's footer controls (microphone, bell, tab pill, return, drop, the
 *     workspace slider): they are pressed and released, and a slow press must still be a press. The
 *     agent's name is the exception: holding it opens the hub like the rest of the face;
 *   - on a creature skin's middle (A_PET), which keeps its own hold-for-tabs. On Focus, the only skin the
 *     device build draws, the middle of the face is where this hold lives.
 * A hold never dispatches what is under the finger: on a question or permission screen it leaves the
 * question open and answered by nothing.
 */
enum { NF_HOLD_SHOW_MS = 200, NF_HOLD_MS = 650, NF_HOLD_STEPS = 20, NF_HOLD_FRAME_MS = 30 };
static bool nf_hold_armed(void)
{
    if (!s.touch_down || s.touch_cancelled || !gesture.live || gesture.moved || gesture.guarded || s.touch_brake)
        return false;
    if (display_is_asleep() || brand_visible() || s.voice_open || form.id[0] || draft.page.active) return false;
    switch (s.view) {
    case NF_HUB: case VOICE: case FORM: case DRAFT: case DRAFT_OPTIONS: case SELECTION: case ANSWER_REVIEW: case OTA:
        return false;
    default:
        break;
    }
    bool surface = s.view == HOME || s.view == AGENT;
    // The title (A_AGENTS) is a footer too, but a hold on it is a hold on the face: it opens the hub.
    if (surface && home_footer(pressed_action.kind) && pressed_action.kind != A_AGENTS) return false;
    if (surface && pressed_action.kind == A_PET && character.id != HT_CHARACTER_FOCUS) return false;
    return true;
}
// How far the hold has got, 0..1000; 0 until the ring shows, and whenever the hold is not armed.
static int nf_hold_permille(uint32_t now)
{
    if (!nf_hold_armed()) return 0;
    uint32_t t = now - s.touch_started;
    if (t < NF_HOLD_SHOW_MS) return 0;
    if (t >= NF_HOLD_MS) return 1000;
    return (int)((t - NF_HOLD_SHOW_MS) * 1000 / (NF_HOLD_MS - NF_HOLD_SHOW_MS));
}
// Milliseconds until the hold needs the glass again (the ring's next frame or its end); 0: no hold.
static uint32_t nf_hold_wait(uint32_t now)
{
    if (!nf_hold_armed()) return 0;
    uint32_t t = now - s.touch_started;
    if (t >= NF_HOLD_MS) return 1;
    if (t < NF_HOLD_SHOW_MS) return NF_HOLD_SHOW_MS - t;
    uint32_t left = NF_HOLD_MS - t;
    return left < NF_HOLD_FRAME_MS ? left : NF_HOLD_FRAME_MS;
}
static void nf_hub_open(void);
// Advance the ring; at the end of the hold open the hub. True when it opened.
static bool nf_hold_tick(uint32_t now)
{
    int pm = nf_hold_permille(now);
    if (pm >= 1000) {
        ESP_LOGI("habitat", "hold: hub");
        s.nf_hold_step = 0;
        nf_hub_open();
        // view() consumed the contact; if it refused to move, consume it anyway so this fires once.
        if (s.touch_down) s.touch_cancelled = true;
        s.pressed = -1;
        change();
        return true;
    }
    uint8_t step = (uint8_t)(pm * NF_HOLD_STEPS / 1000);
    if (step != s.nf_hold_step) { s.nf_hold_step = step; change(); }
    return false;
}
static void surface_tick(uint32_t now)
{
    notice_flush_reads(now);
    if (nf_hold_tick(now)) return;
    if (companion_celebrating && (now-celebration_began>=2400 || s.view!=HOME || s.quiet || !follow_companion || display_is_asleep() || character_mood()==HT_CHARACTER_ATTENTION)) {
        companion_celebrating=false; select_companion(); change();
    }
    if (s.view == TABS && !display_is_asleep() && ht_tab_carousel_tick(&tab_carousel, now)) change();
    if (home_caption_tick(now)) change();
    if (brand_visible() && !(s.view == OTA && s.ota_pct >= 0)) {
        uint8_t step = (uint8_t)((now / (1000 / NIXFRED_SCAN_STEPS)) % NIXFRED_SCAN_STEPS);
        if (step != s.scan_step) { s.scan_step = step; change(); }
    }
    {
        uint32_t period = nf_period(now), tick = period ? now / period + 1 : 0;
        if (tick != s.nf_tick) { s.nf_tick = tick; change(); }
    }
    uint8_t phase = status_animated() ? ht_shimmer_phase(now * status_speed()) : 0;
    if (phase != s.status_phase) { s.status_phase = phase; change(); }
    bool main = s.view == HOME || s.view == AGENT;
    bool visible = !display_is_asleep() &&
        ((main && s.connected && !s.loading) || s.view == VOICE);
    uint32_t held = now - s.touch_started;
    bool review_preview = cable_client_supports(CABLE_FEATURE_DRAFT) &&
        visible && s.view == VOICE && s.voice_open && !s.voice_search &&
        !s.voice_waiting && !s.voice_start_pending && audio_client_recording() &&
        (s.voice_return == HOME || s.voice_return == AGENT || s.voice_return == SELECTION) &&
        s.touch_down && !s.touch_cancelled && gesture.live && !gesture.moved && !gesture.guarded &&
        pressed_action.kind == A_PET && held >= 650 && held <= 1800;
    if (review_preview != s.voice_review_preview) { s.voice_review_preview = review_preview; change(); }
    if (visible && main && s.touch_down && !s.touch_cancelled && gesture.live && !gesture.guarded &&
        pressed_action.kind == A_PET && !gesture.moved && held >= 650 && held < 5000) {
        // Enter directly. The opening contact is consumed until a real release,
        // so lifting or sliding after the hold cannot also select a tab.
        tabs_open();
        return;
    }
    ht_character_mood_t mood = s.view == VOICE ?
        (!s.voice_start_pending && !s.voice_waiting && audio_client_recording() ? HT_CHARACTER_LISTENING : HT_CHARACTER_WORKING) :
        companion_celebrating ? HT_CHARACTER_DONE : character_mood();
    if (ht_character_tick(&character, now, mood, s.quiet, visible,
                           s.touch_down && !s.touch_cancelled, s.last_x,
                           mood == HT_CHARACTER_LISTENING ? audio_client_input_level() : 0, s.character_activity))
        change();
}
static void page_controls(ht_scene_t *f, int count)
{
    // TAB_ROWS - 1, not a literal 3: the pager has to know how many rows the page actually shows, and
    // on the square that is eight.
    control(f, 111, 390, 60, "<", A_UP, 0, s.offset > 0);
    control(f, 183, 390, 108, "[home]", A_HOME, 0, true);
    control(f, 321, 390, 36, ">", A_DOWN, count, s.offset + TAB_ROWS - 1 < count);
}
// Secondary screens retain explicit choices. The main face is the touch surface itself.
static void command_face(ht_scene_t *f, const char *heading_, const char *subject,
                         const char *context, const char *primary, const char *secondary,
                         bool attention, hit_t links[4])
{
    ht_command_face_t face_ = {.heading = heading_, .subject = subject, .context = context,
                              .primary = primary, .secondary = secondary,
                              .foreground = FG, .dim = DIM, .accent = attention ? ERROR : ACCENT,
                              .selection = SEL, .pressed = s.pressed, .enabled = links[2].enabled};
    ht_command_face(f, &face_);
    for (int i = 0; i < 4; i++) {
        links[i].rect = ht_command_targets[i];
        s.hits[s.hit_count++] = links[i];
    }
}
static void render_workspace_preview(ht_scene_t *f)
{
    int i=workspace.choice;
    if (i<0 || i>=s.tab_count) return;
    hit_t links[4]={0};
    command_face(f,"workspaces",s.tabs[i].name,"",
        i==workspace.origin ? "release to stay" : "release to open","slide back to cancel",false,links);
}
/*
 * THE BLUE BELL — the Focus skin's notification pill, as the LVGL firmware drew it: #006fff, fully
 * round, padded 13 x 4, at y 22: the bell in montserrat_14 and, 6 px on, the count in montserrat_22,
 * centred on each other in a 32 px row. Three runs: box, bell, count.
 */
static void focus_bell(ht_scene_t *f, unsigned count)
{
    enum { BELL_Y = 22, BELL_PAD_H = 13, BELL_PAD_V = 4, BELL_GAP = 6 };
    const ht_font_t *bf = &ht_lv_montserrat_14.base, *cf = &ht_lv_montserrat_22.base;
    char text[16];
    snprintf(text, sizeof text, "%u", count);
    int bw = ht_measure(bf, HT_LV_BELL), cw = ht_measure(cf, text);
    int h = cf->height + 2 * BELL_PAD_V, box_w = 2 * BELL_PAD_H + bw + BELL_GAP + cw;
    int x = (HT_WIDTH - box_w) / 2;
    uint16_t blue = color(0x006fff), ink = color(0xeaeaf0);
    ht_box(f, x, BELL_Y, box_w, h, h / 2, blue, blue);
    ht_text(f, x + BELL_PAD_H, BELL_Y + BELL_PAD_V + (cf->height - bf->height) / 2, bw, bf, ink, blue,
            HT_LV_BELL);
    ht_text(f, x + BELL_PAD_H + bw + BELL_GAP, BELL_Y + BELL_PAD_V, cw, cf, ink, blue, text);
}
static void render_home(ht_scene_t *f)
{
    // Where the Focus face's microphone target begins: a little above the mark's ink at 397, so the
    // top of the mark is not its edge. A_PET ends here on Focus.
    enum { FOCUS_MIC_TOP = 353 };
    s.caption_arc = (ht_rect_t){0};
    if (!s.connected || s.loading) { render_brand(f); return; }
    if (workspace.touching && workspace.moved && !workspace.cancelled) { render_workspace_preview(f); return; }
    uint32_t nf_now = ms();
    if (nf_done_running(nf_now) && nf_now - s.nf_done_at < NF_DONE_CLOSE_MS) {
        // Done, first beat: the ring closes from the rim onto a solid dot; the recap follows it up.
        nixfred_done_collapse(f, HT_WIDTH / 2, HT_HEIGHT / 2, (int)((nf_now - s.nf_done_at) * 1000 / NF_DONE_CLOSE_MS),
                              color(HT_THEME_DONE));
        s.hits[s.hit_count++] = (hit_t){{33, 66, 400, 316}, A_PET, 0, true};
        return;
    }
    agent_t *a = active();
    // The top caption belongs to the current pane; only completed work gets
    // a recap. The bell has its own lower target, outside the voice surface.
    const char *recap = a && !a->busy && a->recap_ready && s.connected && !s.loading &&
        !s.nap && !s.voice_retry_until && !carry.active && !carry.error[0] ? a->preview : NULL;
    /*
     * An open question takes the recap's place, on this face, where the person already is. It is
     * shown to be READ: the answer is given in the app, so the face grows no buttons and no other
     * screen opens for it. A turn's recap would be last turn's news; the question is what the agent
     * is waiting on now.
     */
    const char *asked = a && s.connected && !s.loading && !carry.active && !carry.error[0] ?
        question_prompt(a->id) : NULL;
    if (asked) recap = asked;
    // A live turn can outlast its terminal footer (or have no readable footer).
    // Keep its busy state visible while more specific activity is unavailable.
    // An agent with a question open is not working, whatever its turn says: it is waiting on this
    // person. The face says so instead of a "Working" that sends them nowhere.
    const char *activity = a && s.connected && !s.loading && !s.nap && is_question(a->id) ?
        "Needs your answer" : a && a->busy && s.connected && !s.loading && !s.nap ?
        (a->tool[0] ? a->tool : "Working") : "";
    home_caption_tick(ms());
    /*
     * The caption rotation exists because a creature has ONE text seat and two things to say. A skin
     * that owns the whole face has a row for each, so it reads `activity` directly and keeps its
     * name still — see ht_character_face_t.
     */
    bool rotating = home_caption_rotates() && character.id != HT_CHARACTER_FOCUS;
    const char *caption = rotating && home_caption.activity ? activity : a ? a->name : "Choose a pane";
    bool bell = !s.voice_retry_until && !carry.active && !carry.error[0] && !visit.available;
    unsigned unread = notice_unread(a ? a->id : NULL);
    bell = bell && unread > 0;
    char status[100];
    if (s.voice_retry_until) COPY(status, "Try again");
    else status[0] = 0;
    // Seconds since THIS DIAL heard about the turn, not since it began: turn.started carries no
    // timestamp. The 25 s staleness fuse (ui_prune_stale_busy) is what keeps this from counting a
    // turn nobody is running any more.
    uint32_t since = a && a->busy && a->busy_ms && !is_question(a->id) ? (ms() - a->busy_ms) / 1000 : 0;
    int tab_index = workspace_index(s.selected_tab);
    ht_character_face_t f_ = {.recipient = caption, .status = bell ? "" : status,
        // The lower text seat belongs to notifications and useful status.
        // A companion's name lives in the desktop Zoo, not a permanent footer.
        .hint = companion_celebrating && !bell && !status[0] ? celebration_label : "",
        .tab = tab_index >= 0 ? s.tabs[tab_index].name : "",
        .engine = a ? a->engine : "",
        .activity = activity,
        .elapsed = since > 65535 ? 65535 : (uint16_t)since,
        .detail = "",
        .mood = companion_celebrating ? HT_CHARACTER_DONE : character_mood(), .pose = character.motion.reaction.pose,
        .straight_title = s.straight_title,
        .footer_action = carry.active || carry.error[0] || visit.available,
        .ink = FG, .foreground = FG, .dim = DIM,
        .primary_title = true, .roomy_reading = true};
    char carried[128];
    if (carry.active) {
        snprintf(carried,sizeof(carried),"%d line%s from %.70s",carry.rows,carry.rows==1?"":"s",carry.source);
        f_.detail=carried; f_.carrying=true; f_.hint="";
    } else if (carry.error[0]) {
        f_.status="Text expired"; f_.detail="Select it again or drop text"; f_.hint=""; f_.focus=true;
    }
    if (visit.available) f_.hint = "";
    bool focus_face = character.id == HT_CHARACTER_FOCUS;
    int nf_face = f->count;
    ht_character_face(f, &character, &f_, ACCENT, recap);
    if (nf_done_running(nf_now)) {
        // Done, second beat: the recap slides up into place (the face's text and art, not the caption arc).
        int left = (int)(NF_DONE_CLOSE_MS + NF_DONE_SLIDE_MS - (nf_now - s.nf_done_at));
        int dy = NF_DONE_SLIDE_PX * left * left / (NF_DONE_SLIDE_MS * NF_DONE_SLIDE_MS);
        for (int i = nf_face; i < f->count; i++)
            if (!f->runs[i].arc && !f->runs[i].ring.outer && f->runs[i].y + dy < HT_HEIGHT - 40) f->runs[i].y += dy;
    }
    if (bell) {
        if (focus_face) focus_bell(f, unread);   // y 22..57, clear of the tab pill at 67
        else ht_notification_bell(f, unread, f_.ink);
    }
    s.status_phase = status_animated() ? ht_shimmer_phase(ms()) : 0;
    for (int i = 0; i < f->count; i++) {
        ht_run_t *run = &f->runs[i];
        if (run->arc == 1 || (run->font == &ht_mono_20 &&
                             s.straight_title && (run->y == 41 || run->y == 69))) {
            run->fg = rotating ? ht_character_caption_ink(FG, BG, home_caption.opacity) : FG;
            if (run->arc) run->shimmer = s.status_phase;
        }
    }
    if ((carry.active || carry.error[0]) && visit.available) {
        footer_control(f, 95, 156, "[return]", A_RETURN, s.connected && !visit.pending);
        footer_control(f, 263, 108, "[drop]", A_CARRY_DROP, true);
    } else if (carry.active || carry.error[0]) {
        footer_control(f, 113, 240, "[ drop text ]", A_CARRY_DROP, true);
    } else if (visit.available) {
        footer_control(f, 113, 240, "[ return ]", A_RETURN, s.connected && !visit.pending);
    }
    /*
     * A SKIN WITH NO COMPANION NEEDS SOMETHING TO PRESS.
     *
     * The centre rect below has always started voice, on every skin — but on a creature face the
     * creature IS the affordance, and Focus has none. One footer label, and only when nothing else
     * has claimed the footer. Artwork still owns no action: the hit rect is registered here.
     */
    /*
     * THE MICROPHONE, drawn rather than labelled.
     *
     * `[ say ]` was a bracket label because bracket labels are what this firmware has; the device
     * drew a mic here before habitat and a mic is what the thing is. It goes through ht_text with its
     * own 26 px cell instead of footer_control's ht_mono_20, for the same reason the footer bell does
     * — an icon routed into a text run has to match that run's cell exactly or the raster overreads.
     * The hit rect is still registered here: artwork owns no action.
     */
    if (focus_face && !carry.active && !carry.error[0] && !visit.available) {
        bool can_say = s.connected && !s.loading && a != NULL;
        int n = s.hit_count++;
        /*
         * THE TARGET RUNS TO THE BOTTOM OF THE GLASS, and that is the whole point of it.
         *
         * It was {143, 389, 180, 50} — 50 px tall around a 48 px glyph drawn at y 392, so three
         * pixels of slack above the mark and NONE below it. A thumb pressing the lower half of a
         * circle held in the hand rolls downward, and the roll left the rect. That loses the entire
         * contact rather than just the release: the press path records `pressed_action` from the
         * FIRST sample, and both the scroll guard above and the release rule below ask
         * home_footer(pressed_action.kind), so a DOWN one pixel low makes the contact a terminal
         * scroll and nothing can recover it. Pressing the TOP of the mark worked immediately because
         * the row above is A_PET, whose tap opens the microphone too.
         *
         * Nothing else on the Focus face claims this band — A_PET is cut short to end where it
         * starts (see the bottom of this function), the bell sits at the top — so the rect takes it
         * whole, down to the bottom edge. The corners fall outside the round glass, which costs
         * nothing: a touch out there does not exist.
         */
        s.hits[n] = (hit_t){{143, FOCUS_MIC_TOP, 180, HT_HEIGHT - FOCUS_MIC_TOP}, A_VOICE, 0, can_say};
        // The LVGL firmware's own icon_act_voice, 44 px in its #00ff2f, centred on (233, 393) as its
        // 80 px button was. It is a picture, so it has no pressed or disabled ink of its own.
        ht_icon(f, 233 - ht_icon_mic.w / 2, 393 - ht_icon_mic.h / 2, &ht_icon_mic);
    }
    if (!carry.active && !carry.error[0] && !visit.available) {
        /*
         * Both phases of the caption open the pane picker on a creature skin. Focus has two doors
         * where they have one: its tab pill opens the TAB list and its agent's name the PANE list.
         * The pill's is A_TAB_LIST rather
         * than A_TABS, because A_TABS on this surface is the slide-to-switch gesture and answers
         * only a strict tap; a door is pressed and released, like the microphone.
         */
        if (focus_face) {
            // Where ht_focus_face put them this frame: the pill and the name move with the layout.
            ht_rect_t p = ht_focus_pill_target, t = ht_focus_name_target;
            if (p.w) s.hits[s.hit_count++] = (hit_t){{83, p.y - 3, 300, p.h + 6}, A_TAB_LIST, 0, s.connected};
            s.hits[s.hit_count++] = (hit_t){{83, t.y - 3, 300, t.h + 6}, A_AGENTS, 0, true};
        } else s.hits[s.hit_count++] = (hit_t){{83, 0, 300, 66}, A_AGENTS, 0, true};
        for (int i = 0; i < f->count; i++) if (f->runs[i].arc == 1) {
            ht_rect_t r = ht_run_bounds(&f->runs[i]);
            s.caption_arc = (ht_rect_t){r.x - 14, r.y - 14, r.w + 28, r.h + 28};
            break;
        }
    }
    // The badge's own target follows it. On Focus that is the top strip, clear of the tab pill below.
    if (bell)
        s.hits[s.hit_count++] = focus_face ? (hit_t){{83, 10, 300, 55}, A_INBOX, 0, unread > 0}
                                           : (hit_t){{83, 382, 300, 84}, A_INBOX, 0, unread > 0};
    // The bell and the creature never share a target, even when the bell is
    // hidden or its count changes under a finger. Centre always starts voice.
    // On Focus it stops where the microphone's target starts; nothing is drawn between the last recap
    // row (y 335) and the mic, so the band belongs to the button rather than to a tap-anywhere.
    s.hits[s.hit_count++] = (hit_t){{33, 66, 400, focus_face ? FOCUS_MIC_TOP - 66 : 316}, A_PET, 0, true};
    // The fleet on the rim, last so the face keeps every run it needs. The summary sits in the empty
    // band under the face: above the microphone on Focus, above the bell on a creature; not while a
    // recap or a carried text owns that space.
    nf_home_rim(f, nf_now, !recap && !carry.active && !carry.error[0] && !visit.available,
                focus_face ? 318 : 350);
}
/*
 * FOCUS'S LISTS SPEAK THE AGENT SCREEN'S TYPE (owner, 2026-09-30): Geist and Montserrat from the
 * LVGL build, not the terminal skin's mono. The title is a grey Geist Regular 20 straight across the
 * top, a list row Geist Medium, and the one button the tab pill's own shape and face.
 */
static void focus_title(ht_scene_t *f, const char *title)
{
    const ht_font_t *font = &ht_lv_geist_reg_20.base;
    int w = ht_measure(font, title);
    ht_text(f, (HT_WIDTH - w) / 2, 24, w, font, DIM, BG, title);
}
static void focus_centred(ht_scene_t *f, int y, const ht_font_t *font, uint16_t ink, uint16_t bg,
                          const char *text)
{
    // One line of at most 348 px: whole letters, then "..." when the name runs past it.
    char line[HT_TEXT_BYTES];
    snprintf(line, sizeof line, "%s", text);
    int w = ht_measure(font, line);
    if (w > 348) {
        size_t n = strlen(line);
        for (;;) {
            while (n && ((uint8_t)line[n - 1] & 0xc0) == 0x80) n--;   // back over a letter's tail
            if (n) n--;
            while (n && line[n - 1] == ' ') n--;
            if (n + 4 > sizeof line) continue;
            memcpy(line + n, "...", 4);
            w = ht_measure(font, line);
            if (w <= 348 || !n) break;
        }
    }
    if (w <= 0) w = 1;
    ht_text(f, (HT_WIDTH - w) / 2, y, w, font, ink, bg, line);
}
/*
 * One line of a moving name, cut to whole letters between x `left` and `right` so it stays on the
 * round glass. A letter's share is measured with its neighbours, so kerning is kept.
 */
static void focus_clipped(ht_scene_t *f, int x, int y, const ht_font_t *font, uint16_t ink,
                          const char *line, size_t len, int left, int right)
{
    char text[HT_TEXT_BYTES];
    if (len >= sizeof text) len = sizeof text - 1;
    memcpy(text, line, len);
    text[len] = 0;
    char probe[HT_TEXT_BYTES];
    const char *p = text;
    while (*p && x < left) {
        const char *q = p;
        ht_utf8_next(&q);
        snprintf(probe, sizeof probe, "%.*s", (int)(q - text), text);
        int to = ht_measure(font, probe);
        snprintf(probe, sizeof probe, "%.*s", (int)(p - text), text);
        x += to - ht_measure(font, probe);
        p = q;
    }
    const char *end = p;
    for (const char *q = p; *q;) {
        ht_utf8_next(&q);
        snprintf(probe, sizeof probe, "%.*s", (int)(q - p), p);
        if (x + ht_measure(font, probe) > right) break;
        end = q;
    }
    snprintf(probe, sizeof probe, "%.*s", (int)(end - p), p);
    int w = ht_measure(font, probe);
    if (w > 0) ht_text(f, x, y, w, font, ink, BG, probe);
}
/*
 * FOCUS'S PANE LIST (owner, 2026-09-30): every pane at once, still, in full ink, centred as one block
 * about y 233 on a 48 px pitch — six fit between the title and the ←. Only the pane on the face is
 * green; a pressed row lights green on a dark-green band. Past six the list scrolls a row at a time
 * under a vertical drag, and nothing moves otherwise. Each row is its own tap.
 */
static void render_focus_panes(ht_scene_t *f)
{
    focus_title(f, "panes");
    const ht_font_t *font = &ht_lv_geist_med_32.base;   // the tab names' size
    uint16_t green = color(HT_THEME_VOICE), band = color(0x0d3a18);
    if (!s.count) {
        focus_centred(f, 180, font, FG, BG, s.loading ? "Loading..." : "No panes in this tab.");
        // "Choose a tab", in the tab pill's shape and face: the door to the tab list looks like one.
        const ht_font_t *pf = &ht_lv_montserrat_24.base;
        int n = s.hit_count++, w = ht_measure(pf, "Choose a tab"), box = w + 2 * 12 + 2;
        int x = (HT_WIDTH - box) / 2, y = 250;
        s.hits[n] = (hit_t){{x - 20, y - 12, box + 40, 41 + 24}, A_TABS, 0, s.connected};
        bool pressed = n == s.pressed;
        uint16_t fill = pressed ? band : color(0x141519);
        ht_box(f, x, y, box, 41, 20, fill, pressed ? band : color(0x3a3f4b));
        ht_text(f, x + 13, y + 7, w, pf, !s.connected ? DIM : pressed ? green : FG, fill, "Choose a tab");
    } else {
        int last = s.count > PANE_ROWS ? s.count - PANE_ROWS : 0;
        if (s.offset > last) s.offset = last;
        if (s.offset < 0) s.offset = 0;
        int rows = s.count - s.offset < PANE_ROWS ? s.count - s.offset : PANE_ROWS;
        for (int row = 0; row < rows; row++) {
            int i = s.offset + row, y = 233 + ((2 * row - (rows - 1)) * PANE_PITCH) / 2;
            agent_t *a = &s.agents[i];
            int hit = s.hit_count++;
            s.hits[hit] = (hit_t){{59, y - PANE_PITCH / 2, 348, PANE_PITCH}, A_AGENT, i, s.connected};
            bool pressed = hit == s.pressed;
            uint16_t ink = !s.connected ? DIM : i == s.active || pressed ? green : FG;
            if (pressed) ht_box(f, 59, y - PANE_PITCH / 2 + 2, 348, PANE_PITCH - 4, 6, band, band);
            // One line, as wide as the circle holds at the top and bottom rows; longer ends in "...".
            focus_centred(f, y - font->height / 2, font, ink, pressed ? band : BG,
                          a->name[0] ? a->name : "Untitled");
        }
    }
    ht_text(f, 223, 400, 20, &ht_nav_32, DIM, BG, "\xe2\x86\x90");
    s.hits[s.hit_count++] = (hit_t){{83, 392, 300, 74}, A_HOME, 0, true};
}
// A drag on the Focus pane list: a row per pitch travelled, and only when there are more than fit.
static void panes_move(int dy)
{
    int last = s.count > PANE_ROWS ? s.count - PANE_ROWS : 0;
    if (!last) { s.pane_pos = 0; return; }
    s.pane_pos += dy;
    int step = s.pane_pos / PANE_PITCH;
    if (!step) return;
    s.pane_pos %= PANE_PITCH;
    int next = s.offset + step;
    if (next < 0) next = 0;
    if (next > last) next = last;
    if (next != s.offset) { s.offset = next; change(); }
    else s.pane_pos = 0;   // no overscroll to undo on reversal
}
static void panes_settle(void)
{
    s.pane_pos = 0;
}
static void render_agents(ht_scene_t *f)
{
    if (character.id == HT_CHARACTER_FOCUS) { render_focus_panes(f); return; }
    heading(f, "panes");
    int last = s.count > TAB_ROWS ? s.count - TAB_ROWS : 0;
    if (s.offset > last) s.offset = last;
    if (s.offset < 0) s.offset = 0;
    if (!s.count) {
        center(f, 192, s.loading ? "Loading..." : "No panes in this tab.", FG);
        control(f, FACE_CX(204), 283, 204, "Choose a tab", A_TABS, 0, s.connected);
        return;
    }
    for (int row = 0; row < TAB_ROWS && s.offset + row < s.count; row++) {
        int i = s.offset + row, y = TAB_TOP + row * TAB_ROW_HEIGHT;
        agent_t *a = &s.agents[i];
        int hit = s.hit_count++;
        s.hits[hit] = (hit_t){{59, y, 348, TAB_ROW_HEIGHT}, A_AGENT, i, s.connected};
        bool selected = i == s.active || hit == s.pressed;
        char label[HT_TEXT_BYTES]; snprintf(label, sizeof label, " %s", a->name);
        ht_text(f, 71, y + 14, 324, UI_FONT,
            !s.connected ? DIM : is_question(a->id) || selected ? ACCENT : FG,
            selected ? SEL : BG, label);
    }
}
static void render_agent(ht_scene_t *f)
{
    render_home(f); // One companion surface; changing panes only changes its recipient.
}
static bool question_view(view_t v)
{
    return v == QUESTION || v == CHOICE || v == ANSWER_REVIEW;
}
// THREE ROWS, NOT FIVE. Five at 38 px run 146 -> 336, past the position line; three end at 260.
// A page is 348 / 17 = 20 cells x 3 = 60 characters, where it used to be 29 x 5 = 145 — so a long
// question is three pages now, not one. That is the honest cost of the size.
#define Q_ROWS 3
static int question_rows(const char *value)
{
    return ht_text_rows(value, UI_FONT, 348);
}
static void question_text(ht_scene_t *f, const char *value)
{
    int rows = question_rows(value), last = rows > Q_ROWS ? rows - Q_ROWS : 0;
    if (s.offset > last) s.offset = last;
    if (s.offset < 0) s.offset = 0;
    ht_wrap(f, FACE_CX(348), 146, 348, Q_ROWS, s.offset, UI_FONT, FG, value);
    char position[40];
    if (rows > Q_ROWS) snprintf(position,sizeof position,"%d-%d / %d  drag to read",s.offset+1,s.offset+Q_ROWS,rows);
    else if (s.view==CHOICE) COPY(position,"drag for choices");
    else position[0] = 0;
    // mono_20 at 276: this is chrome ABOUT the text, not the text.
    if (!s.q.speech_error[0]) ht_text(f, FACE_CX(296), 276, 296, &ht_mono_20, DIM, BG, position);
}
static void render_question(ht_scene_t *f)
{
    question_chrome(f);
    heading(f, s.q.name[0] ? s.q.name : "Question");
    if (s.q.loading) {
        center(f, 214, "Reading the question...", DIM);
        control(f, 122, 346, 187, "[ later ]", A_HOME, 0, true);
        return;
    }
    if (s.q.error[0] || !s.q.valid || !s.q.supported) {
        ht_wrap(f, FACE_CX(336), 173, 336, 5, 0, UI_FONT, DIM,
            s.q.error[0] ? s.q.error : !s.q.valid ? "Answered elsewhere." : "This question needs the desktop.");
        control(f, 116, 346, 238, "[ on desktop ]", A_DESKTOP, 1, s.connected);
        return;
    }
    question_item_t *q = &s.q.item[s.q.index];
    char label[40]; snprintf(label,sizeof label,"question %d / %d",s.q.index+1,s.q.count);
    text(f, FACE_CX(216), 109, 216, label, DIM);
    question_text(f, q->prompt);
    if (s.q.speech_error[0]) ht_wrap(f,FACE_CX(312),319,312,2,0,&ht_mono_20,ERROR,s.q.speech_error);
    if (q->can_text) {
        /*
     * UP TO y=336, AND THE RIM IS WHY.
     *
     * At 17 px a cell these labels are 119 + 85 + 102 = 306 px of text. The chord at y=417, where the
     * old row ended, is 143 px — the outer two would have been cut in half by the glass. At 336 the
     * chord is 364 and the row fits with margin.
     *
     * "[choices]" (153 px) went with it: three labels at this size do not share a line on a circle.
     * The choices screen is still one drag away, which is what the position line says.
     */
    control(f, 54, 336,119,"[later]",A_HOME,0,true);
        control(f, 184, 336,119,q->draft[0] ? "[draft]" : "[say]",
                q->draft[0] ? A_QUESTION_REVIEW : A_QUESTION_SAY,0,!s.q.pending);
        control(f, 313, 336,102,"[next]",A_QUESTION_CHOICES,0,!s.q.pending);
    } else {
        control(f, 79, 346,153,"[ later ]",A_HOME,0,true);
        control(f, 236, 346,153,"[choices]",A_QUESTION_CHOICES,0,!s.q.pending);
    }
}
static void render_choices(ht_scene_t *f)
{
    question_chrome(f);
    heading(f, s.q.name);
    question_item_t *q = &s.q.item[s.q.index];
    char label[64]; snprintf(label,sizeof label,"%s %d / %d",q->multi ? "choose any" : "choose one",s.q.choice+1,q->count);
    text(f, FACE_CX(252), 109, 252, label, DIM);
    question_text(f, q->options[s.q.choice]);
    bool chosen = (q->selected & (1u << s.q.choice)) != 0;
    control(f, FACE_CX(204), 300, 204, chosen ? "[ selected ]" : "[ select ]", A_CHOICE, s.q.choice, !s.q.pending);
    // 366, where the chord is 380. At the old 387 two labels of 102 + 136 would not have cleared it.
    control(f, 88, 366, 102, "[back]", A_QUESTION_BACK, 0, true);
    control(f, 258, 366, 136, "[review]", A_QUESTION_REVIEW, 0, q->selected && !s.q.pending);
}
static void render_answer_review(ht_scene_t *f)
{
    question_chrome(f);
    heading(f, s.q.name);
    if (s.q.error[0]) {
        ht_wrap(f,FACE_CX(336),166,336,5,0,UI_FONT,DIM,s.q.error);
        control(f, 116, 346,238,"[ on desktop ]",A_DESKTOP,1,s.connected);
        return;
    }
    question_item_t *q = &s.q.item[s.q.index];
    char label[40]; snprintf(label,sizeof label,"answer %d / %d",s.q.index+1,s.q.count);
    text(f,FACE_CX(216),109,216,label,DIM);
    question_text(f,q->answer);
    if (s.q.speech_error[0]) ht_wrap(f,FACE_CX(312),319,312,2,0,&ht_mono_20,ERROR,s.q.speech_error);
    if (s.q.pending) { center(f, 346, "Waiting...", DIM); return; }
    int footer_y = q->draft[0] ? 332 : 366;
    control(f,q->draft[0] ? 54 : 88,footer_y,102,"[back]",A_QUESTION_BACK,0,true);
    if (q->draft[0]) control(f,176,footer_y,119,"[again]",A_QUESTION_SAY,0,true);
    control(f,q->draft[0] ? 313 : 258,footer_y,102,s.q.index+1 < s.q.count ? "[next]" : "[send]",
        A_ANSWER,0,s.connected && !s.q.pending && (q->selected || q->draft[0]));
}
static const char *settings_item(int wanted, action_kind_t *action)
{
    static const struct { const char *label; action_kind_t action; uint32_t feature; } items[] = {
        {"Inbox", A_INBOX, 0}, {"Machines", A_MACHINES, 0},
        {"Model", A_MODELS, 0}, {"Stop current turn", A_STOP, 0},
        {"Nap", A_NAP, 0},
        {"Find Harness", A_FIND, CABLE_FEATURE_FORM},
        {"New Harness", A_FORM, CABLE_FEATURE_FORM},
        {"Latest output", A_LATEST, CABLE_FEATURE_VISIT},
        {"Select text", A_SELECT_BEGIN, CABLE_FEATURE_SELECTION},
    };
    for (unsigned i = 0; i < sizeof items / sizeof items[0]; i++) {
        if (items[i].feature && !cable_client_supports(items[i].feature)) continue;
        if (wanted-- == 0) {
            if (action) *action = items[i].action;
            return items[i].label;
        }
    }
    return NULL;
}
static int settings_count(void)
{
    int count = 0;
    while (settings_item(count, NULL)) count++;
    return count;
}
static void tabs_move(int dy)
{
    // Move by one name while the finger is down, rather than paging by three
    // after release. The existing gesture recognizer owns tap cancellation.
    s.tab_drag += dy;
    int step = s.tab_drag / TAB_ROW_HEIGHT;
    if (!step) return;
    s.tab_drag %= TAB_ROW_HEIGHT;
    int count = s.view == AGENTS ? s.count : s.view == SETTINGS ? settings_count() : s.tab_count;
    int last = count > TAB_ROWS ? count - TAB_ROWS : 0;
    int next = s.offset + step;
    if (next < 0) next = 0;
    if (next > last) next = last;
    if (next != s.offset) { s.offset = next; change(); }
    else s.tab_drag = 0; // Overscroll never builds up travel to undo on reversal.
}
static void tab_name(ht_scene_t *f, const char *name, int center_x, uint16_t ink)
{
    int first = f->count;
    const int width = 12 * UI_FONT->width;
    ht_wrap(f, 0, 0, width, 6, 0, UI_FONT, ink, name[0] ? name : "Untitled");
    while (f->count > first && !f->runs[f->count - 1].text[0]) f->count--;
    int rows = f->count - first;
    for (int i = first; i < f->count; i++) {
        ht_run_t *r = &f->runs[i];
        const char *p = r->text;
        int cells = 0;
        while (*p) { ht_utf8_next(&p); cells++; }
        int dx = center_x - 233;
        if (dx < -HT_TAB_PITCH) dx = -HT_TAB_PITCH;
        if (dx > HT_TAB_PITCH) dx = HT_TAB_PITCH;
        // Center the chosen name. Neighbors align toward the visible edge of
        // their own page so even a short name peeks in. Alignment moves smoothly
        // with the page and never crosses the 24 px gap between names.
        int x = center_x - cells * UI_FONT->width / 2 -
            dx * (width - cells * UI_FONT->width) / (2 * HT_TAB_PITCH);
        p = r->text;
        // The moving names stay inside a central, round-screen-safe viewport.
        // Discard whole cells at its edges; no framebuffer or scissor allocation.
        while (*p && x < 42) { ht_utf8_next(&p); x += UI_FONT->width; cells--; }
        memmove(r->text, p, strlen(p) + 1);
        int room = x >= 424 ? 0 : (424 - x) / UI_FONT->width;
        if (room < cells) cells = room;
        p = r->text;
        for (int n = 0; n < cells; n++) ht_utf8_next(&p);
        r->text[p - r->text] = 0;
        r->x = x; r->y = 233 - rows * UI_FONT->height / 2 + (i - first) * UI_FONT->height;
        r->w = cells * UI_FONT->width;
    }
}
/*
 * FOCUS'S TABS: the same carousel, in Geist Medium 32 — the name on at most two lines of 204 px, as
 * the mono version wrapped at twelve cells, ending in "..." past that; neighbours peek in at the
 * edges, cut to whole letters inside x 42..424. The tab you are in is green.
 */
static void render_focus_tabs(ht_scene_t *f)
{
    focus_title(f, "tabs");
    const ht_font_t *font = &ht_lv_geist_med_32.base;
    enum { SPAN = 204 };
    int current = ht_tab_carousel_index(&tab_carousel);
    if (current < 0) focus_centred(f, 214, &ht_lv_geist_med_28.base, DIM, BG, "No tabs yet.");
    else {
        for (int i = current - 1; i <= current + 1; i++) {
            if (i < 0 || i >= s.tab_count) continue;
            int dx = i * HT_TAB_PITCH - tab_carousel.position;
            uint16_t ink = !s.connected ? DIM : !strcmp(s.tabs[i].id, s.selected_tab) ? color(HT_THEME_VOICE) : FG;
            int fade = abs(dx) * 140 / HT_TAB_PITCH;
            ink = ht_character_caption_ink(ink, BG, fade < 210 ? 255 - fade : 45);
            ht_lv_label_t l;
            ht_lv_label(&l, font, s.tabs[i].name[0] ? s.tabs[i].name : "Untitled", SPAN, 2, true);
            int cdx = dx < -HT_TAB_PITCH ? -HT_TAB_PITCH : dx > HT_TAB_PITCH ? HT_TAB_PITCH : dx;
            // Centre the chosen name; a neighbour aligns toward the edge of its own page, as before.
            int x = 233 + dx - l.w / 2 - cdx * (SPAN - l.w) / (2 * HT_TAB_PITCH);
            int top = 233 - l.lines * font->height / 2;
            for (int n = 0; n < l.lines; n++)
                focus_clipped(f, x + (l.w - l.line[n].w) / 2, top + n * font->height, font, ink,
                              l.text + l.line[n].at, l.line[n].len, 42, 424);
        }
        for (int n = 0; n < 3; n++) {
            int i = current + (n == 1 ? -1 : n == 2 ? 1 : 0);
            if (i < 0 || i >= s.tab_count) continue;
            int cx = 233 + i * HT_TAB_PITCH - tab_carousel.position;
            int left = i ? cx - HT_TAB_PITCH / 2 : 33;
            int right = i + 1 < s.tab_count ? cx + HT_TAB_PITCH / 2 : 433;
            if (left < 33) left = 33;
            if (right > 433) right = 433;
            if (right > left) s.hits[s.hit_count++] = (hit_t){{left, 110, right - left, 252},
                A_TAB, i, s.connected && !s.loading};
        }
    }
    ht_text(f, 223, 400, 20, &ht_nav_32, DIM, BG, "\xe2\x86\x90");
    s.hits[s.hit_count++] = (hit_t){{83, 392, 300, 74}, A_HOME, 0, true};
}
static void render_tabs(ht_scene_t *f)
{
    if (character.id == HT_CHARACTER_FOCUS) { render_focus_tabs(f); return; }
    ht_arc_title(f, DIM, "tabs");
    int current = ht_tab_carousel_index(&tab_carousel);
    if (current < 0) center(f, 214, "No tabs yet.", DIM);
    else {
        for (int i = current - 1; i <= current + 1; i++) {
            if (i < 0 || i >= s.tab_count) continue;
            int dx = i * HT_TAB_PITCH - tab_carousel.position;
            uint16_t ink = !s.connected ? DIM : !strcmp(s.tabs[i].id, s.selected_tab) ? ACCENT : FG;
            int fade = abs(dx) * 140 / HT_TAB_PITCH;
            ink = ht_character_caption_ink(ink, BG, fade < 210 ? 255 - fade : 45);
            tab_name(f, s.tabs[i].name, 233 + dx, ink);
        }
        // Each visible name owns its tap; a swipe from any page only browses.
        // Keep the centered page first for stable accessibility/test ordering.
        for (int n = 0; n < 3; n++) {
            int i = current + (n == 1 ? -1 : n == 2 ? 1 : 0);
            if (i < 0 || i >= s.tab_count) continue;
            int cx = 233 + i * HT_TAB_PITCH - tab_carousel.position;
            int left = i ? cx - HT_TAB_PITCH / 2 : 33;
            int right = i + 1 < s.tab_count ? cx + HT_TAB_PITCH / 2 : 433;
            if (left < 33) left = 33;
            if (right > 433) right = 433;
            if (right > left) s.hits[s.hit_count++] = (hit_t){{left, 110, right - left, 252},
                A_TAB, i, s.connected && !s.loading};
        }
    }
    ht_text(f, 223, 400, 20, &ht_nav_32, DIM, BG, "←");
    s.hits[s.hit_count++] = (hit_t){{83, 392, 300, 74}, A_HOME, 0, true};
}
static void render_notice(ht_scene_t *f)
{
    if (s.offset >= s.notice_count) s.offset = s.notice_count - 1;
    if (s.offset < 0) s.offset = 0;
    const cable_notif_t *n = &s.notice[s.offset];
    // Inbox is a text card, not another companion surface. Browsing never
    // changes desktop focus; a tap on the name/message opens that exact pane.
    int body = s.hit_count++;
    s.hits[body] = (hit_t){{33, 55, 400, 327}, A_NOTICE, s.offset, s.connected};
    uint16_t mark = color(n->question ? HT_THEME_QUESTION : n->failed ? HT_THEME_FAILED : HT_THEME_DONE);
    /*
     * On Focus the card leads with the agent's engine badge, as its design does. The notice carries
     * only the agent's id, so the engine comes from the roster: a notice from an agent this dial is
     * not carrying (another machine's) has none, and gets an empty badge rather than a guessed one.
     */
    char badge[4] = "";
    uint32_t badge_ink = 0;
    if (character.id == HT_CHARACTER_FOCUS) {
        int i = find(n->agent_id);
        if (i >= 0) ht_focus_engine_mark(s.agents[i].engine, badge, &badge_ink);
    }
    ht_inbox_card_badged(f, n->question ? "?" : n->failed ? HT_FAILED : HT_DONE, n->name,
                         n->summary[0] ? n->summary : "No preview available.",
                         s.connected ? FG : DIM, s.connected ? mark : DIM,
                         character.id == HT_CHARACTER_FOCUS ? badge : NULL,
                         !s.connected ? DIM : badge_ink ? color(badge_ink) : FG);
    s.notice_frame = n->read_on_dial ? 0 : n->display_revision;
    s.hits[s.hit_count++] = (hit_t){{83, 392, 300, 74}, A_HOME, 0, true};
    ht_text(f, FACE_CX(20), 400, 20, &ht_nav_32,
        s.pressed == body + 1 ? FG : DIM, BG, "\xe2\x86\x90");
}
/*
 * THE FOCUS INBOX — the LVGL drawer (notif_rebuild), from its own numbers, on the face's black (the owner's call; LVGL's was #16161c): the 60 x 32
 * close pill at the top, then a 360 px column of cards from (53, 107), 12 apart, down to y 427. A
 * card is [machine, muted] over [the engine's 20 px mark, or a green dot, and the agent's name in
 * green] over the message in white, wrapped, cut at 100 characters. Only whole cards show; a vertical
 * swipe moves the column a card at a time (habitat_touch). A tap on a card opens that agent as it
 * always has; a tap on the cross goes back. No age: the cable carries no time for a notice.
 */
static void render_focus_inbox(ht_scene_t *f)
{
    enum { LIST_X = 53, LIST_Y = 107, LIST_W = 360, LIST_BOTTOM = 427, LIST_GAP = 12, CARD_R = 26,
           PAD_H = 16, PAD_V = 14, ROW_GAP = 8, MARK = 20, MARK_GAP = 8, DOT = 8, MSG_GLYPHS = 100,
           CLOSE_X = 203, CLOSE_Y = 16, CLOSE_W = 60, CLOSE_H = 32 };
    if (s.offset >= s.notice_count) s.offset = s.notice_count - 1;
    if (s.offset < 0) s.offset = 0;
    const ht_font_t *small = &ht_lv_geist_reg_20.base, *body = &ht_lv_geist_reg_25.base,
                    *cross = &ht_lv_montserrat_22.base;
    uint16_t fg = color(0xeaeaf0);
    // make_close_pill: COL_FG at 10 % over black, the cross centred in it.
    uint16_t close = color(0x171718);
    int cw = ht_measure(cross, HT_LV_CROSS);
    ht_box(f, CLOSE_X, CLOSE_Y, CLOSE_W, CLOSE_H, CLOSE_H / 2, close, close);
    ht_text(f, CLOSE_X + (CLOSE_W - cw) / 2, CLOSE_Y + (CLOSE_H - cross->height) / 2, cw, cross, fg,
            close, HT_LV_CROSS);
    s.hits[s.hit_count++] = (hit_t){{CLOSE_X - 40, 0, CLOSE_W + 80, CLOSE_Y + CLOSE_H + 20}, A_HOME, 0, true};
    uint16_t card = color(0x23252f), rim = color(0x3d3f47), green = color(0x04fe08),
             muted = color(0x8a8a99), ink = s.connected ? fg : muted;
    // The default theme's button shadow, 50 % #9e9e9e a couple of pixels under the card, over black.
    uint16_t shade = color(0x202020);
    int inner = LIST_W - 2 - 2 * PAD_H, y = LIST_Y;
    for (int i = s.offset; i < s.notice_count && s.hit_count < 24; i++) {
        const cable_notif_t *n = &s.notice[i];
        const char *full = n->summary[0] ? n->summary : n->question ? "Waiting for you" : "done";
        char msg[HT_TEXT_BYTES * 3];
        size_t len = 0, glyphs = 0;
        while (full[len] && glyphs < MSG_GLYPHS && len + 8 < sizeof msg) {
            len++;
            while (full[len] && ((uint8_t)full[len] & 0xc0) == 0x80) len++;
            glyphs++;
        }
        memcpy(msg, full, len);
        msg[len] = 0;
        if (full[len]) strcat(msg, "\xe2\x80\xa6");
        ht_lv_label_t m;
        int lines = ht_lv_label(&m, body, msg, inner, HT_LV_LINES, false);
        if (lines > HT_LV_LINES) lines = HT_LV_LINES;
        bool machine = n->machine[0] != 0;
        int h = 2 + 2 * PAD_V + (machine ? small->height + ROW_GAP : 0) + small->height + ROW_GAP +
                lines * body->height;
        if (y + h > LIST_BOTTOM && i > s.offset) break;
        ht_box(f, LIST_X, y + 2, LIST_W, h, CARD_R, shade, shade);
        ht_box(f, LIST_X, y, LIST_W, h, CARD_R, card, rim);
        s.hits[s.hit_count++] = (hit_t){{LIST_X, y, LIST_W, h}, A_NOTICE, i, s.connected};
        int x = LIST_X + 1 + PAD_H, row = y + 1 + PAD_V;
        ht_lv_label_t l;
        if (machine) {
            ht_lv_label(&l, small, n->machine, inner, 1, true);
            ht_text(f, x, row, l.w ? l.w : 1, small, muted, card, l.text);
            row += small->height + ROW_GAP;
        }
        // The engine's mark when the roster knows the agent, the green dot when it does not.
        int a = find(n->agent_id), engine = a >= 0 ? ht_focus_engine_index(s.agents[a].engine) : -1;
        int lead = engine >= 0 ? MARK : DOT;
        if (engine >= 0) ht_icon(f, x, row + (small->height - MARK) / 2, &ht_icon_engine20[engine]);
        else ht_box(f, x, row + (small->height - DOT) / 2, DOT, DOT, DOT / 2, green, green);
        ht_lv_label(&l, small, n->name[0] ? n->name : n->agent_id, inner - lead - MARK_GAP, 1, true);
        ht_text(f, x + lead + MARK_GAP, row, l.w ? l.w : 1, small, green, card, l.text);
        row += small->height + ROW_GAP;
        for (int k = 0; k < lines; k++) {
            char text[HT_TEXT_BYTES];
            size_t n_ = m.line[k].len < sizeof text ? m.line[k].len : sizeof text - 1;
            memcpy(text, m.text + m.line[k].at, n_);
            text[n_] = 0;
            ht_text(f, x, row + k * body->height, m.line[k].w ? m.line[k].w : 1, body, ink, card, text);
        }
        y += h + LIST_GAP;
    }
    const cable_notif_t *top = &s.notice[s.offset];
    s.notice_frame = top->read_on_dial ? 0 : top->display_revision;
}
static void render_list(ht_scene_t *f)
{
    if (s.view == TABS) { render_tabs(f); return; }
    if (s.view == INBOX && s.notice_count) {
        if (character.id == HT_CHARACTER_FOCUS) render_focus_inbox(f);
        else render_notice(f);
        return;
    }
    const char *title = s.view == MACHINES ? "machines" : "inbox";
    heading(f, title);
    int count = s.view == MACHINES ? s.machine_count : s.notice_count;
    if (!count) {
        center(f, 198, s.view == INBOX ? "All caught up." : "Nothing here yet.", DIM);
    }
    for (int i = s.offset; i < count && i < s.offset + 3; i++) {
        char label[80], detail[80] = "";
        action_kind_t a;
        bool enabled = true;
        int y = 140 + (i - s.offset) * 76;
        if (s.view == MACHINES) {
            snprintf(label, sizeof(label), "@ %s", s.machines[i].name);
            COPY(detail, s.machines[i].state);
            a = A_MACHINE;
            enabled = s.connected && (!strcmp(s.machines[i].state, "ready") || s.machines[i].local);
        } else {
            snprintf(label, sizeof(label), "%s %s", s.notice[i].question ? "?" : "+",
                     s.notice[i].name);
            COPY(detail, s.notice[i].question ? "Needs your answer" : s.notice[i].summary);
            a = A_NOTICE;
        }
        control(f, 59, y, 348, label, a, i, enabled);
        // y + 42, not y + 31: a 38 px line starting at y ends at y + 38, so the old offset put the
        // detail three pixels inside the label above it.
        text(f, 71, y + 42, 324, detail, DIM);
    }
    page_controls(f, count);
}
static const char *voice_status(void)
{
    if (s.voice_start_pending) return "Starting";
    if (!audio_client_recording() || s.voice_waiting)
        return (s.voice_return == FORM || s.voice_search) ? "Finding" :
            question_view(s.voice_return) || s.voice_return == DRAFT || s.voice_review ? "Writing" : "";
    return s.voice_review_preview ? "Release to review" : "Listening";
}
static void render_voice(ht_scene_t *f)
{
    char draft_detail[64];
    snprintf(draft_detail, sizeof draft_detail, s.voice_draft_append ? "Add to your message" : "Replace part %d / %d",
        draft.page.position, draft.page.total);
    ht_character_face_t f_ = {.recipient = s.voice_target, .status = voice_status(),
        .hint = "",
        .mood = !s.voice_start_pending && !s.voice_waiting && audio_client_recording() ? HT_CHARACTER_LISTENING : HT_CHARACTER_WORKING,
        .pose = character.motion.reaction.pose, .ink = FG, .foreground = FG, .dim = DIM, .primary_title = true,
        .detail = s.voice_search ? "Say a phrase from the output" : s.voice_return == DRAFT ? draft_detail :
            question_view(s.voice_return) ? "Your answer" :
            s.voice_carry ? carry.excerpt : selection.active ? selection.excerpt : NULL,
        .carrying = s.voice_carry, .voice = true};
    f_.focus = f_.detail && *f_.detail;
    ht_character_face(f, &character, &f_, ACCENT, NULL);
    s.status_phase = status_animated() ? ht_shimmer_phase(ms() * status_speed()) : 0;
    for (int i = 0; i < f->count; i++)
        if (f->runs[i].arc == 2) f->runs[i].shimmer = s.status_phase;
    // The rim: a level ring whose thickness follows the microphone while it records, and an arc lapping
    // the glass once a second while the words are on their way (around the sparkles on Focus).
    bool nf_listening = !s.voice_start_pending && !s.voice_waiting && audio_client_recording();
    nixfred_voice_rim(f, nf_listening, audio_client_input_level(),
                      (ms() / (1000 / NIXFRED_VOICE_STEPS)) % NIXFRED_VOICE_STEPS, color(HT_THEME_VOICE), ACCENT);
    s.hits[s.hit_count++] = (hit_t){{33, 97, 400, 274}, A_PET, 0, true};
}
static void render_selection(ht_scene_t *f)
{
    heading(f, selection.query[0] ? "find in output" : "select text");
    agent_t *a = active();
    text(f, FACE_CX(324), 116, 324, selection.query[0] ? selection.query : a ? a->name : "Harness", DIM);
    if (carry.pending) {
        center(f, 207, "Picking up the text...", FG);
        center(f, 285, "Then choose who gets it", DIM);
        return;
    }
    if (selection.error[0]) {
        ht_wrap(f, FACE_CX(336), 180, 336, 5, 0, UI_FONT, FG, selection.error);
        control(f, FACE_CX(192), 349, 192, "[try again]", A_SELECT_BEGIN, 0, s.connected);
        return;
    }
    char status[64];
    snprintf(status, sizeof(status), "%s%d line%s", selection.pending ? "choosing / " : "", selection.rows,
             selection.rows == 1 ? "" : "s");
    if (selection.query[0]) {
        if (selection.matches) snprintf(status, sizeof status, "%d / %d matches", selection.match, selection.matches);
        else COPY(status, "No matches");
    }
    center(f, 167, (selection.rows || selection.query[0]) ? status : "Look at your desktop", FG);
    ht_wrap(f, FACE_CX(336), 203, 336, 3, 0, UI_FONT, FG,
            selection.excerpt[0] ? selection.excerpt : selection.pending ? "Finding the text..." : selection.query[0] ? "Try another phrase." : "Blank line");
    if (ht_selection_ready(&selection) && selection.excerpt[0]) {
        s.hits[s.hit_count++] = (hit_t){{53, 151, 360, 184}, A_PET, 0, true};
    }
    if (selection.query[0] && !selection.matches && !selection.pending) {
        control(f, FACE_CX(192), 349, 192, "[ find ]", A_SELECT_FIND, 0, ht_selection_ready(&selection));
        return;
    }
    control(f, 46, 332, 102, "[find]", A_SELECT_FIND, 0, ht_selection_ready(&selection));
    control(f, 165, 332, 119, selection.query[0] ? "[lines]" : selection.extending ? "[range]" : "[line]",
            A_SELECT_EXTEND, 0, ht_selection_ready(&selection) && selection.rows > 0);
    control(f, 301, 332, 119, "[carry]", A_CARRY, 0,
            ht_selection_ready(&selection) && selection.excerpt[0]);
    center(f, 395, selection.pending ? "choosing..." : "drag to read", DIM);
}
static void render_form(ht_scene_t *f)
{
    const ht_form_page_t *p = &form.page;
    bool finding = !strncmp(form.id, "find-", 5);
    center(f, 79, p->title[0] ? p->title : !strncmp(form.id, "find-", 5) ? "Find Harness" : "New Harness", DIM);
    char count[32]; snprintf(count, sizeof count, "%d / %d", p->position, p->total);
    if (p->query[0]) text(f, FACE_CX(276), 113, 276, p->query, DIM);
    else if (p->total) center(f, 113, count, DIM);
    text(f, FACE_CX(312), 158, 312, p->previous, DIM);
    ht_wrap(f, FACE_CX(336), 199, 336, 2, 0, UI_FONT, ACCENT,
            p->label[0] ? p->label : form.failed ? "Could not open" : "Opening...");
    if (!p->error[0]) ht_wrap(f, FACE_CX(336), 275, 336, 2, 0, UI_FONT, FG, p->busy ? p->status : p->detail);
    if (!form.pending && p->active && p->enabled && !p->busy && !form.failed)
        s.hits[s.hit_count++] = (hit_t){{49, 185, 368, 124}, A_FORM_MAIN, 0, true};
    // The current choice and its detail own the center; footer actions keep
    // a full line at the larger interface size. Errors replace the detail.
    if (p->error[0]) ht_wrap(f, FACE_CX(336), 275, 336, 2, 0, UI_FONT, ERROR, p->error);
    control(f, 60, 352, 102, "[back]", A_FORM_BACK, 0, !form.pending || finding);
    control(f, 173, 352, 85, "[say]", A_FORM_SAY, 0,
            !form.pending && !form.failed && p->active && p->can_query && !p->busy);
    char action[44];
    snprintf(action, sizeof action, "[%.23s]", form.failed ? "retry" : p->busy ? "wait" :
             form.pending && form.pending_op != HT_FORM_STATE ? "..." : !strcmp(p->action, "check status") ? "check" : p->action[0] ? p->action : "wait");
    control(f, 267, 352, 136, action, A_FORM_MAIN, 0,
            !form.pending && (form.failed || (p->active && p->enabled && !p->busy)));
}
// Keep the scroll limit and drawn rows identical at the 28 px text size.
#define DRAFT_ROWS 3
static void render_draft(ht_scene_t *f)
{
    const ht_draft_page_t *p = &draft.page;
    control(f, 83, 67, 48, "<", A_DRAFT_OPTIONS, 0, !draft.pending);
    text(f, 137, 67, 264, p->name, FG);
    char position[48];
    snprintf(position, sizeof position, "draft / part %d of %d", p->position, p->total);
    center(f, 111, position, DIM);
    int rows = question_rows(p->text), last = rows > DRAFT_ROWS ? rows - DRAFT_ROWS : 0;
    if (s.offset > last) s.offset = last;
    ht_wrap(f, FACE_CX(348), 153, 348, DRAFT_ROWS, s.offset, UI_FONT, FG, p->text);
    if (rows > DRAFT_ROWS) snprintf(position, sizeof position, "%d-%d / %d  drag to read", s.offset+1, s.offset+DRAFT_ROWS, rows);
    else COPY(position, p->total > 1 ? "drag for other parts" : p->context);
    text(f, FACE_CX(324), 297, 324, position, DIM);
    if (p->error[0]) ht_wrap(f, FACE_CX(336), 326, 336, 2, 0, &ht_mono_20, ERROR, p->error);
    else if (!p->can_send) ht_wrap(f, FACE_CX(336), 326, 336, 2, 0, &ht_mono_20, DIM,
        "Some characters cannot display. Re-speak that part.");
    else center(f, 333, draft.pending ? (draft.op == HT_DRAFT_SEND ? "Sending..." : "One moment...") :
        "tap to re-speak part", DIM);
    bool editable = !draft.pending && !draft.failed && !p->locked;
    s.hits[s.hit_count++] = (hit_t){{49, 139, 368, 151}, A_DRAFT_EDIT, 0, editable};
    control(f, 83, 370, 156, p->locked ? "[close]" : "[discard]", A_DRAFT_DISCARD, 0, !draft.pending);
    bool checking = draft.failed || p->locked;
    control(f, 281, 370, 120, checking ? "[check]" : "[send]",
        checking ? A_DRAFT_STATE : A_DRAFT_SEND, 0, !draft.pending && (checking || p->can_send));
}
static void render_draft_options(ht_scene_t *f)
{
    center(f, 83, "Your draft", FG);
    text(f, FACE_CX(312), 118, 312, draft.page.context, DIM);
    bool editable = !draft.pending && !draft.failed && !draft.page.locked;
    control(f, FACE_CX(336), 167, 336, "Add to message", A_DRAFT_APPEND, 0, editable);
    control(f, FACE_CX(336), 245, 336, "Undo last edit", A_DRAFT_UNDO, 0, editable && draft.page.can_undo);
    control(f, FACE_CX(336), 323, 336, "Back to draft", A_DRAFT_BACK, 0, true);
    center(f, 380, draft.page.locked ? "Check terminal" : "Nothing sent yet", DIM);
}
static void render_settings(ht_scene_t *f)
{
    heading(f, "controls");
    int last = settings_count() - TAB_ROWS;
    if (last < 0) last = 0;
    if (s.offset > last) s.offset = last;
    if (s.offset < 0) s.offset = 0;
    for (int row = 0; row < TAB_ROWS; row++) {
        action_kind_t action;
        const char *label = settings_item(s.offset + row, &action);
        if (!label) break;
        if (action == A_NAP) label = s.nap ? "Wake" : "Nap";
        bool enabled = action == A_INBOX || action == A_NAP ||
            (s.connected && ((action != A_STOP && action != A_MODELS && action != A_SELECT_BEGIN && action != A_LATEST) ||
                (active() && (action != A_STOP || active()->busy) && (action != A_LATEST || !visit.pending))));
        int y = TAB_TOP + row * TAB_ROW_HEIGHT, hit = s.hit_count++;
        s.hits[hit] = (hit_t){{LIST_HIT_X, y, LIST_HIT_W, TAB_ROW_HEIGHT}, action, 0, enabled};
        ht_text(f, SET_TEXT_X, y + 14, SET_TEXT_W, UI_FONT,
            !enabled ? DIM : hit == s.pressed ? ACCENT : FG, hit == s.pressed ? SEL : BG, label);
    }
}
/*
 * WHAT THE APP ASKED FOR, waiting for the worker to write it.
 *
 * NVS is flash and a commit takes milliseconds; the finger path has always queued its writes for
 * exactly that reason, and a change arriving over the cable is no different. The live state moves
 * under the display lock so the glass is right on the next frame, and this is what gets persisted.
 * Guarded by the display lock, like every other piece of `s`.
 */
static struct {
    ui_settings_t values;
    uint32_t fields;
} settings_pending;
/*
 * nixfred graphics slice 3 (nixfred/DESIGN.md, "Device"). Ambient face, connecting dots, pairing hexagon,
 * machine tiles, the swarm's ring of rings, the notification card, the collision card, the lane tag,
 * view transitions and the plans face. Drawn from what the dial holds plus the optional `nixfred.fleet`
 * frame; with no such frame each falls back to what stock shows (no clock, no lanes, no alert, no arcs).
 */
enum { NF_AMBIENT_AFTER_MS = 45000, NF_AMBIENT_MS = 125, NF_CARD_IN_MS = 260, NF_CARD_HOLD_MS = 4500,
       NF_CARD_OUT_MS = 260, NF_CARD_DISMISS_MS = 320, NF_CARD_Y = 268, NF_SWEEP_FRAME_MS = 30 };
static bool nf_quiet_fleet(uint32_t now)
{
    for (int i = 0; i < s.count; i++)
        if (nf_state(&s.agents[i], now) >= NIXFRED_WAITING) return false;
    return true;
}
// Nothing needs anyone and nobody has touched the glass for a while: the home face rests.
static bool nf_ambient_on(uint32_t now)
{
    return s.view == HOME && s.connected && !s.loading && !display_is_asleep() &&
        character.id == HT_CHARACTER_FOCUS && display_idle_ms() >= NF_AMBIENT_AFTER_MS &&
        !s.voice_open && !carry.active && !carry.pending && !notice_unread(NULL) && !nf_done_running(now) &&
        !s.nf_card_at && nf_quiet_fleet(now);
}
static char nf_lane_of(const char *id)
{
    for (int i = 0; i < s.nf_fleet.lane_count; i++)
        if (!strcmp(s.nf_fleet.lanes[i].id, id)) return s.nf_fleet.lanes[i].letter;
    return 0;
}
// The card's place: its top edge, 466 (below the glass) when it is not showing. 0 dismissed-and-gone.
static int nf_card_y(uint32_t now, int *trail)
{
    *trail = 0;
    if (!s.nf_card_at) return HT_HEIGHT;
    uint32_t t = now - s.nf_card_at;
    if (s.nf_card_gone) {
        uint32_t d = now - s.nf_card_gone;
        if (d >= NF_CARD_DISMISS_MS) { s.nf_card_at = 0; return HT_HEIGHT; }
        *trail = (int)(d * 1000 / NF_CARD_DISMISS_MS);
        return NF_CARD_Y;
    }
    int travel = HT_HEIGHT - NF_CARD_Y;
    if (t < NF_CARD_IN_MS) { int l = (int)(NF_CARD_IN_MS - t); return NF_CARD_Y + travel * l * l / (NF_CARD_IN_MS * NF_CARD_IN_MS); }
    if (t < NF_CARD_IN_MS + NF_CARD_HOLD_MS) return NF_CARD_Y;
    t -= NF_CARD_IN_MS + NF_CARD_HOLD_MS;
    if (t < NF_CARD_OUT_MS) return NF_CARD_Y + travel * (int)(t * t) / (NF_CARD_OUT_MS * NF_CARD_OUT_MS);
    s.nf_card_at = 0;
    return HT_HEIGHT;
}
static bool nf_card_up(void)
{
    return s.nf_card_at && !s.nf_card_gone;
}
// Put a hit before every other one: the first hit under a finger wins.
static void nf_hit_first(hit_t h)
{
    if (s.hit_count >= (int)(sizeof s.hits / sizeof *s.hits)) s.hit_count--;
    memmove(&s.hits[1], &s.hits[0], (size_t)s.hit_count * sizeof *s.hits);
    s.hits[0] = h;
    s.hit_count++;
}
static void nf_clock(char *out, size_t size, uint32_t now)
{
    out[0] = 0;
    if (!s.nf_clock_at) return;
    uint32_t t = ((uint32_t)s.nf_clock_s + (now - s.nf_clock_at) / 1000) % 86400;
    snprintf(out, size, "%02u:%02u", (unsigned)(t / 3600), (unsigned)(t / 60 % 60));
}
static void nf_render_ambient(ht_scene_t *f, uint32_t now)
{
    uint8_t st[NIXFRED_AMBIENT_MAX];
    int n = nf_states(st, NIXFRED_AMBIENT_MAX, now), working = 0;
    for (int i = 0; i < n; i++) working += st[i] == NIXFRED_WORKING;
    // The orbit's pace is the amount of work: half a lap a minute at rest, three quarters more per agent
    // working, at most four laps a minute. Accumulated, so a change of pace never jumps the particles.
    uint32_t dt = s.nf_orbit_at ? now - s.nf_orbit_at : 0;
    if (dt > 1000) dt = 1000;
    unsigned quarter_laps = 2 + 3 * (unsigned)working;
    if (quarter_laps > 16) quarter_laps = 16;
    s.nf_orbit += (uint32_t)((uint64_t)dt * HT_TURN * quarter_laps / (4 * 60000));
    s.nf_orbit_at = now;
    // Burn-in: the face walks a 4 x 4 px square, 1 px a minute.
    unsigned k = (now / 60000) % 16;
    int dx = k < 4 ? (int)k : k < 8 ? 4 : k < 12 ? (int)(12 - k) : 0;
    int dy = k < 4 ? 0 : k < 8 ? (int)(k - 4) : k < 12 ? 4 : (int)(16 - k);
    char clock[8], line[32];
    nf_clock(clock, sizeof clock, now);
    if (!n) snprintf(line, sizeof line, "no agents");
    else if (working) snprintf(line, sizeof line, "%d/%d working", working, n);
    else snprintf(line, sizeof line, n == 1 ? "1 agent" : "%d agents", n);
    nixfred_palette_t p = nf_palette();
    nixfred_ambient(f, st, n, (int)(s.nf_orbit % HT_TURN), (int)((now / 40) % (HT_HEIGHT - 12)), dx - 2, dy - 2,
                    clock, line, &p);
    s.hits[s.hit_count++] = (hit_t){{0, 0, HT_WIDTH, HT_HEIGHT}, A_PET, 0, true}; // a touch only wakes it
}
// What slice 3 adds over the home face: the lane tag and the notification card.
static void nf_home_extras(ht_scene_t *f, uint32_t now)
{
    if (!s.connected || s.loading) return;
    agent_t *a = active();
    char lane = a ? nf_lane_of(a->id) : 0;
    if (lane && character.id == HT_CHARACTER_FOCUS && !a->recap_ready && !carry.active) {
        char l[2] = {lane, 0};
        ht_ring(f, HT_WIDTH / 2, 302, 10, 12, 0, HT_TURN, DIM);   // under the status line, above the summary
        ht_text(f, HT_WIDTH / 2 - ht_mono_16.width / 2, 302 - ht_mono_16.height / 2, ht_mono_16.width, &ht_mono_16,
                FG, BG, l);
    }
    // Slice 5: the plan arcs in the bottom corners are display only. Their tap targets collided with the
    // compose control under them; the plans face is a wedge of the hub now.
    int trail, y = nf_card_y(now, &trail);
    if (y < HT_HEIGHT) {
        nixfred_palette_t p = nf_palette();
        nixfred_card(f, y, p.green, s.nf_card_name, s.nf_card_text, trail, FG, DIM);
        if (nf_card_up()) nf_hit_first((hit_t){{NIXFRED_CARD_X, y, NIXFRED_CARD_W, NIXFRED_CARD_H}, A_NF_CARD, 0, true});
    }
}
static void nf_render_machines(ht_scene_t *f)
{
    focus_title(f, "machines");
    int count = s.machine_count - s.offset;
    if (count <= 0) { focus_centred(f, 214, &ht_lv_geist_med_28.base, DIM, BG, "Nothing here yet."); }
    if (count > 4) count = 4;
    static const int at[4][4][2] = {
        {{233, 200}}, {{150, 200}, {316, 200}}, {{150, 130}, {316, 130}, {233, 290}},
        {{150, 130}, {316, 130}, {150, 290}, {316, 290}}};
    nixfred_palette_t p = nf_palette();
    for (int k = 0; k < count; k++) {
        int i = s.offset + k, cx = at[count - 1][k][0], cy = at[count - 1][k][1];
        const cable_machine_t *m = &s.machines[i];
        bool ready = !strcmp(m->state, "ready") || m->local;
        uint16_t edge = !strcmp(m->state, "offline") ? DIM : !strcmp(m->state, "needs-link") ? color(HT_THEME_QUESTION) :
            m->local ? p.green : p.accent;
        bool mine = s.nf_fleet.machine_id[0] ? !strcmp(s.nf_fleet.machine_id, m->id) : m->local;
        int load = mine ? s.nf_fleet.load : -1, aux = mine ? (s.nf_fleet.vram >= 0 ? s.nf_fleet.vram : s.nf_fleet.battery) : -1;
        bool selected = !strcmp(s.selected_machine, m->id);
        nixfred_machine_tile(f, cx, cy, edge, selected, load, aux, &p);
        nixfred_label(f, cx, cy + 68, &ht_lv_geist_reg_20.base, selected ? FG : DIM, m->name, 150);
        if (load >= 0) {
            char line[40];
            if (aux >= 0) snprintf(line, sizeof line, "%d%% %s %d%%", (load + 5) / 10,
                                   s.nf_fleet.vram >= 0 ? "vram" : "bat", (aux + 5) / 10);
            else snprintf(line, sizeof line, "load %d%%", (load + 5) / 10);
            nixfred_label(f, cx, cy - 8, &ht_mono_16, FG, line, 70);
        }
        s.hits[s.hit_count++] = (hit_t){{cx - 64, cy - 64, 128, 128}, A_MACHINE, i, s.connected && ready};
    }
    ht_text(f, 223, 400, 20, &ht_nav_32, DIM, BG, "\xe2\x86\x90");
    s.hits[s.hit_count++] = (hit_t){{83, 392, 300, 74}, A_HOME, 0, true};
}
// The selected tab as a ring of rings around its name: the tab in the centre, its agents orbiting.
static bool nf_swarm_visible(void)
{
    int current = ht_tab_carousel_index(&tab_carousel);
    return character.id == HT_CHARACTER_FOCUS && s.view == TABS && current >= 0 && current < s.tab_count &&
        !tab_carousel.touching && !tab_carousel.animating && !strcmp(s.tabs[current].id, s.selected_tab) && s.count > 0;
}
static void nf_swarm_overlay(ht_scene_t *f, uint32_t now)
{
    if (!nf_swarm_visible()) return;
    uint8_t st[12];
    int n = nf_states(st, 12, now), working = 0;
    for (int i = 0; i < n; i++) working += st[i] == NIXFRED_WORKING;
    nixfred_palette_t p = nf_palette();
    nixfred_swarm(f, HT_WIDTH / 2, HT_HEIGHT / 2, 116, 160, st, n, working ? (now / NF_PHASE_MS) : 0, &p);
}
static void nf_render_plans(ht_scene_t *f)
{
    nixfred_plan_t plan[NIXFRED_PLANS_MAX];
    int n = s.nf_plan_count;
    for (int i = 0; i < n; i++) {
        memcpy(plan[i].name, s.nf_plan_name[i][0] ? s.nf_plan_name[i] : "plan", sizeof plan[i].name);
        plan[i].name[sizeof plan[i].name - 1] = 0;
        plan[i].used = s.nf_plan_used[i];
        plan[i].banked = s.nf_plan_banked[i];
        plan[i].tone = color(nf_plan_color(s.nf_plan_tone[i]));
    }
    nixfred_plans_face(f, plan, n, s.nf_plan_pick - 1, FG, DIM);
    s.hits[s.hit_count++] = (hit_t){{0, 0, HT_WIDTH, HT_HEIGHT}, A_HOME, 0, true}; // a tap anywhere goes back
}
// MESSAGE kinds 3 (pairing) and 4 (collision).
static bool nf_render_message(ht_scene_t *f, uint32_t now)
{
    nixfred_palette_t p = nf_palette();
    if (s.nf_msg_kind == 3) {
        nixfred_pair_hex(f, HT_WIDTH / 2, 226, now / 150, false, ACCENT);
        focus_centred(f, 64, &ht_lv_geist_reg_20.base, DIM, BG, s.title);
        const ht_font_t *code = ht_measure(&ht_pixel_40, s.message) <= 210 ? &ht_pixel_40 : &ht_mono_20;
        int w = ht_measure(code, s.message);
        ht_text(f, (HT_WIDTH - w) / 2, 226 - code->height / 2, w > 0 ? w : 1, code, FG, BG, s.message);
        return true;
    }
    if (s.nf_msg_kind == 4) {
        int ia = find(s.nf_fleet.alert_a), ib = find(s.nf_fleet.alert_b);
        uint8_t sa = ia >= 0 ? nf_state(&s.agents[ia], now) : NIXFRED_IDLE;
        uint8_t sb = ib >= 0 ? nf_state(&s.agents[ib], now) : NIXFRED_IDLE;
        nixfred_collision(f, s.nf_fleet.alert_an, sa, s.nf_fleet.alert_bn, sb, (now / NF_PHASE_MS) % NIXFRED_PHASES, &p);
        ht_wrap(f, FACE_CX(320), 300, 320, 3, 0, UI_FONT, FG, s.nf_fleet.alert_detail);
        control(f, 87, 67, 48, "<", A_HOME, 0, true);
        return true;
    }
    return false;
}
// The rim sweep that introduces a new view (and the ambient face coming or going).
static void nf_transition(ht_scene_t *f, uint32_t now, bool ambient)
{
    if (s.view != s.nf_last_view || ambient != s.nf_was_ambient) {
        // Not on the first frame after boot, and not into the brand face (it has its own scanner).
        if (s.nf_view_at || s.nf_last_view) s.nf_view_at = now | 1;
        s.nf_last_view = (uint8_t)s.view;
        s.nf_was_ambient = ambient;
    }
    if (brand_visible()) return;
    uint32_t t = s.nf_view_at ? now - s.nf_view_at : NIXFRED_SWEEP_MS;
    nixfred_sweep(f, t >= NIXFRED_SWEEP_MS ? 1000 : (int)(t * 1000 / NIXFRED_SWEEP_MS), ambient ? DIM : ACCENT);
}
static uint32_t nf3_period(uint32_t now)
{
    uint32_t best = 0;
#define NF_WANT(ms_) do { uint32_t w_ = (ms_); if (!best || w_ < best) best = w_; } while (0)
    if (s.nf_view_at && now - s.nf_view_at < NIXFRED_SWEEP_MS + 40) NF_WANT(NF_SWEEP_FRAME_MS);
    if (nf_ambient_on(now)) NF_WANT(display_idle_ms() > NIXFRED_DIM_MS ? 250 : NF_AMBIENT_MS);
    else if (s.view == HOME && s.connected && !s.loading && character.id == HT_CHARACTER_FOCUS &&
             display_idle_ms() + 1000 >= NF_AMBIENT_AFTER_MS && nf_quiet_fleet(now)) NF_WANT(500); // to start it
    if (s.view == HOME && s.nf_card_at) {
        uint32_t t = now - s.nf_card_at;
        NF_WANT(s.nf_card_gone || t < NF_CARD_IN_MS || t > NF_CARD_IN_MS + NF_CARD_HOLD_MS - 40 ? 30 : 250);
    }
    if (s.view == NF_HUB && s.nf_hub_at && now - s.nf_hub_at < NIXFRED_HUB_BLOOM_MS + 40) NF_WANT(NF_SWEEP_FRAME_MS);
    else if (s.view == NF_HUB && s.nf_clock_at) NF_WANT(1000);   // the clock in its centre
    if (s.view == MESSAGE && s.nf_msg_kind == 3) NF_WANT(150);
    if (s.view == MESSAGE && s.nf_msg_kind == 4) NF_WANT(NF_PHASE_MS);
    if (nf_swarm_visible() && !s.quiet && !s.nap) {
        for (int i = 0; i < s.count; i++)
            if (nf_state(&s.agents[i], now) == NIXFRED_WORKING) { NF_WANT(NF_PHASE_MS); break; }
    }
#undef NF_WANT
    return best;
}
// A swipe up that began on the card dismisses it with its trail. True when the card took the gesture.
static bool nf_card_swipe(int start_y, int dy)
{
    if (!nf_card_up() || s.view != HOME || dy >= 0 || start_y < NF_CARD_Y - 10 || start_y > NF_CARD_Y + NIXFRED_CARD_H + 20)
        return false;
    s.nf_card_gone = ms() | 1;
    change();
    return true;
}

/*
 * nixfred slice 5: THE HUB. A hold anywhere (slice 4's 650 ms, same ring, same exceptions) opens it.
 *
 * Five wedges clockwise from 12 o'clock, each with a glyph, a label and one live line:
 *   SESSIONS  how many agents and how many need you (red for a permission, yellow for a question) -> AGENTS
 *   PLANS     the next plan's name and banked share, its use as a gauge                            -> NF_PLANS
 *   MACHINES  this machine's load and VRAM (or battery) as two arcs                                -> MACHINES
 *   SWARMS    how many tabs; the ring of rings                                                     -> TABS
 *   INBOX     how many notices are unread (dim, and opens nothing, when there are none)            -> INBOX
 * The centre holds the clock and the fleet summary ("! 1/9"); a tap there, on the glass between the
 * wedges, or a swipe either way, closes it back to the view the hold began on. There is no STOP ALL
 * wedge: the dial has no request that stops every agent (`nixfred.panic` runs host to dial only, and
 * A_STOP_YES stops one agent's turn), so one is not drawn rather than drawn doing something else.
 * Nothing here answers a question: every wedge only changes the view.
 */
static void nf_hub_open(void)
{
    view_t from = s.view;
    view(NF_HUB);
    if (s.view != NF_HUB) return;
    s.nf_hub_return = (uint8_t)from;
    s.nf_hub_at = ms() | 1;
}
static void nf_hub_close(void)
{
    view_t back = (view_t)s.nf_hub_return;
    // Somewhere that cannot be re-entered as it was (a one-off message, a transfer, a question since
    // answered elsewhere) closes to the home face instead.
    if (back == NF_HUB || back == MESSAGE || back == OTA || back == VOICE || back == FORM || back == DRAFT ||
        back == DRAFT_OPTIONS || back == SELECTION || (question_view(back) && !s.q.valid) || (back == AGENT && !active()))
        back = HOME;
    view(back);
}
static void nf_render_hub(ht_scene_t *f, uint32_t now)
{
    nixfred_palette_t p = nf_palette();
    nixfred_hub_wedge_t w[5];
    memset(w, 0, sizeof w);
    static const char *const labels[5] = {"SESSIONS", "PLANS", "MACHINES", "SWARMS", "INBOX"};
    static const action_kind_t opens[5] = {A_AGENTS, A_NF_PLANS, A_MACHINES, A_TABS, A_INBOX};
    for (int i = 0; i < 5; i++) {
        w[i].glyph = (uint8_t)i; w[i].label = labels[i]; w[i].tone = p.accent; w[i].live = true;
        w[i].arc = w[i].arc2 = -1; w[i].arc_tone = p.accent;
    }
    uint8_t st[NIXFRED_RIM_MAX];
    int n = nf_states(st, NIXFRED_RIM_MAX, now), asks = 0, perms = 0;
    for (int i = 0; i < n; i++) { asks += st[i] == NIXFRED_WAITING || st[i] == NIXFRED_PERMISSION; perms += st[i] == NIXFRED_PERMISSION; }
    if (asks) {
        snprintf(w[0].line, sizeof w[0].line, "%d/%d need you", asks, s.count);
        w[0].tone = perms ? p.red : p.yellow; w[0].glow = true;
    } else snprintf(w[0].line, sizeof w[0].line, s.count == 1 ? "1 agent" : s.count ? "%d agents" : "no agents", s.count);
    int pick = s.nf_plan_pick - 1;
    if (pick < 0 || pick >= s.nf_plan_count) pick = s.nf_plan_count > 0 ? 0 : -1;
    if (pick >= 0) {
        char name[10];
        snprintf(name, sizeof name, "%s", s.nf_plan_name[pick][0] ? s.nf_plan_name[pick] : "plan");
        for (char *c = name; *c; c++) if (*c >= 'a' && *c <= 'z') *c = (char)(*c - 32);
        int b = s.nf_plan_banked[pick], bank = b >= 0 ? (b + 5) / 10 : -((-b + 5) / 10);
        snprintf(w[1].line, sizeof w[1].line, "%s %+d%%", name, bank);
        w[1].arc = s.nf_plan_used[pick]; w[1].arc_tone = color(nf_plan_color(s.nf_plan_tone[pick]));
    } else snprintf(w[1].line, sizeof w[1].line, "no data");
    if (s.nf_fleet.machine_id[0] || s.nf_clock_at) {
        w[2].arc = s.nf_fleet.load;
        w[2].arc2 = s.nf_fleet.vram >= 0 ? s.nf_fleet.vram : s.nf_fleet.battery;
        if (s.nf_fleet.load >= 0) snprintf(w[2].line, sizeof w[2].line, "load %d%%", (s.nf_fleet.load + 5) / 10);
    }
    if (!w[2].line[0]) snprintf(w[2].line, sizeof w[2].line, s.machine_count == 1 ? "1 host" : "%d hosts", s.machine_count);
    snprintf(w[3].line, sizeof w[3].line, s.tab_count == 1 ? "1 tab" : "%d tabs", s.tab_count);
    unsigned unread = notice_unread(NULL);
    if (unread) {
        snprintf(w[4].line, sizeof w[4].line, "%u unread", unread);
        w[4].glow = true; w[4].tone = waiting() ? p.yellow : p.accent;
    } else snprintf(w[4].line, sizeof w[4].line, "all read");
    w[4].live = s.notice_count > 0;
    char clock[8], summary[16];
    uint16_t tone = p.accent;
    nf_clock(clock, sizeof clock, now);
    nixfred_fleet_summary(summary, sizeof summary, &tone, st, n, &p);
    int bloom = s.nf_hub_at && now - s.nf_hub_at < NIXFRED_HUB_BLOOM_MS ?
        (int)((now - s.nf_hub_at) * 1000 / NIXFRED_HUB_BLOOM_MS) : 1000;
    nixfred_hub(f, w, 5, bloom, s.pressed >= 0 && s.pressed < 5 ? s.pressed : -1, clock, summary, tone, &p);
    // Tap targets: the wedges first (the first hit under a finger wins), then the centre, then the rest
    // of the glass, which closes it too.
    for (int i = 0; i < 5; i++) {
        int x, y;
        nixfred_hub_centre(i, 5, &x, &y);
        s.hits[s.hit_count++] = (hit_t){{x - NIXFRED_HUB_HIT_W / 2, y - NIXFRED_HUB_HIT_H / 2, NIXFRED_HUB_HIT_W,
                                         NIXFRED_HUB_HIT_H}, w[i].live ? opens[i] : A_NONE, 0, true}; // a dim wedge swallows its tap
    }
    s.hits[s.hit_count++] = (hit_t){{HT_WIDTH / 2 - NIXFRED_HUB_CORE_R, HT_HEIGHT / 2 - NIXFRED_HUB_CORE_R,
                                     2 * NIXFRED_HUB_CORE_R, 2 * NIXFRED_HUB_CORE_R}, A_NF_HUB_CLOSE, 0, true};
    s.hits[s.hit_count++] = (hit_t){{0, 0, HT_WIDTH, HT_HEIGHT}, A_NF_HUB_CLOSE, 0, true};
}

bool habitat_scene_take(ht_scene_t *f)
{
#ifdef DEVICE_CREATURE_GALLERY
    // App snapshots never choose a scene in this visual-only build.
    if (!s.ready) return false;
    return ht_gallery_take(&gallery, f, ms());
#endif
    if (!s.ready || !s.dirty || s.bulk)
        return false;
    s.dirty = false;
    s.notice_frame = 0;
    s.hit_count = 0;
    ht_scene_clear(f, BG);
    switch (s.view) {
    case FORM:
        render_form(f);
        break;
    case DRAFT:
        render_draft(f);
        break;
    case DRAFT_OPTIONS:
        render_draft_options(f);
        break;
    case HOME:
        if (nf_ambient_on(ms())) nf_render_ambient(f, ms());
        else { render_home(f); nf_home_extras(f, ms()); }
        break;
    case NF_PLANS:
        nf_render_plans(f);
        break;
    case NF_HUB:
        nf_render_hub(f, ms());
        break;
    case AGENTS:
        render_agents(f);
        break;
    case AGENT:
        render_agent(f);
        break;
    case QUESTION:
        render_question(f);
        break;
    case CHOICE:
        render_choices(f);
        break;
    case ANSWER_REVIEW:
        render_answer_review(f);
        break;
    case TABS:
    case MACHINES:
    case INBOX:
        if (s.view == MACHINES && character.id == HT_CHARACTER_FOCUS) nf_render_machines(f);
        else render_list(f);
        nf_swarm_overlay(f, ms());
        break;
    case VOICE:
        render_voice(f);
        break;
    case SELECTION:
        render_selection(f);
        break;
    case SETTINGS:
        render_settings(f);
        break;
    case READER: {
        agent_t *a = active();
        heading(f, "latest result");
        if (a)
            ht_wrap(f, FACE_CX(348), 125, 348, 5, s.offset, UI_FONT, FG, a->full);
        control(f, 119, 387, 72, "<", A_UP, 0, s.offset > 0);
        control(f, 205, 366, 153, "[desktop]", A_DESKTOP, 0, s.connected);
        break;
    }
    case STOP:
        heading(f, "stop this turn?");
        center(f, 185, "Your work stays.", FG);
        center(f, 227, "This turn stops.", DIM);
        control(f, 83, 355, 156, "[cancel]", A_HOME, 0, true);
        control(f, 263, 355, 120, "[stop]", A_STOP_YES, 0, s.connected);
        break;
    case MODELS:
        heading(f, "model");
        if (s.model_count < 0)
            center(f, 211, "Loading models...", DIM);
        else if (!s.model_count)
            center(f, 211, "No models available.", DIM);
        else
            for (int i = s.offset; i < s.model_count && i < s.offset + 3; i++) {
                const char *label = strrchr(s.models[i].id, ':');
                control(f, 59, (153 + (i - s.offset) * 72), 348, label ? label + 1 : s.models[i].id,
                        A_MODEL, i, s.connected);
            }
        page_controls(f, s.model_count);
        break;
    case OTA:
        render_brand(f);
        break;
    case MESSAGE:
        if (nf_render_message(f, ms())) break;
        if (s.nf_msg_kind == 2) {
            nixfred_panic(f, ms() - s.nf_msg_at, s.nf_stopped, color(HT_THEME_FAILED), FG, DIM);
            control(f, 87, 67, 48, "<", A_HOME, 0, true);
            break;
        }
        nf_message_chrome(f, ms());
        heading(f, s.title);
        ht_wrap(f, FACE_CX(336), 161, 336, 5, 0, UI_FONT, FG, s.message);
        break;
    }
    nf_transition(f, ms(), s.view == HOME && nf_ambient_on(ms()));
    if (s.nf_hold_step) nixfred_hold_rim(f, s.nf_hold_step * (1000 / NF_HOLD_STEPS), ACCENT);
    return true;
}

static bool queue(action_t a)
{
#ifdef DEVICE_CREATURE_GALLERY
    (void)a;
    return false; // Never enqueue a desktop or audio action in the visual study.
#endif
    // Background read receipts must never occupy the last touch/audio slot or
    // replace the screen with a cable-busy warning. Retry quietly next tick.
    if (a.kind == A_NOTICE_READ)
        return actions && uxQueueSpacesAvailable(actions) > 1 && xQueueSend(actions, &a, 0) == pdPASS;
    // A live scroll owns the final slot, so a stalled USB writer cannot drop its UP.
    if (actions && ((!scroll.live && !selection.active && !visit.id[0]) || uxQueueSpacesAvailable(actions) > 1) &&
        xQueueSend(actions, &a, 0) == pdPASS)
        return true;
    COPY(s.title, "One moment");
    COPY(s.message, "The cable is busy. Try again.");
    view(MESSAGE);
    return false;
}
static bool scroll_emit(ht_scroll_phase_t phase, int dy, int velocity, void *ctx)
{
    (void)ctx;
    action_t a = {.kind = A_SCROLL, .value = (int)phase, .dy = dy, .velocity = velocity};
    unsigned required = phase == HT_SCROLL_UP ? 1 : 2;
    if (!actions || uxQueueSpacesAvailable(actions) < required) return false;
    bool ok = xQueueSend(actions, &a, 0) == pdPASS;
    // Every producer holds display_lock. DOWN/MOVE and other actions reserve this slot.
    if (phase == HT_SCROLL_UP) assert(ok);
    return ok;
}
static bool form_emit(const ht_form_command_t *c, void *ctx)
{
    (void)ctx;
    if (!actions || uxQueueSpacesAvailable(actions) < 2) return false;
    action_t a = {.kind = A_FORM_SEND, .value = c->op, .revision = c->request,
                  .dy = (int)c->revision, .velocity = c->delta};
    COPY(a.id, c->id);
    return xQueueSend(actions, &a, 0) == pdPASS;
}
static bool draft_emit(const ht_draft_command_t *c, void *ctx)
{
    (void)ctx;
    if (!actions || uxQueueSpacesAvailable(actions) < 2) return false;
    action_t a = {.kind = A_DRAFT_COMMAND, .value = c->op, .revision = c->request,
        .dy = (int)c->revision, .velocity = c->delta};
    COPY(a.id, c->id);
    return xQueueSend(actions, &a, 0) == pdPASS;
}
static bool visit_emit(const ht_visit_command_t *c, void *ctx)
{
    (void)ctx;
    if (!actions || uxQueueSpacesAvailable(actions) < (c->op == HT_VISIT_CANCEL ? 1 : 2)) return false;
    action_t a = {.kind = A_VISIT_SEND, .value = c->op, .revision = c->request};
    COPY(a.id, c->agent); COPY(a.text, c->id);
    return xQueueSend(actions, &a, 0) == pdPASS;
}
static bool selection_emit(const ht_select_command_t *c, void *ctx)
{
    (void)ctx;
    // Selection keeps a slot for cancellation, just as scrolling keeps one for UP.
    if (!actions || uxQueueSpacesAvailable(actions) < (c->op == HT_SELECT_CANCEL ? 1 : 2)) return false;
    action_t a = {.kind = A_SELECT_SEND, .value = c->op, .revision = c->revision,
                  .dy = c->delta, .velocity = (int)c->request};
    COPY(a.id, c->agent); COPY(a.text, c->id);
    return xQueueSend(actions, &a, 0) == pdPASS;
}
static bool carry_emit(const ht_carry_command_t *c, void *ctx)
{
    (void)ctx;
    if (!actions || uxQueueSpacesAvailable(actions) < (c->cancel ? 1 : 2)) return false;
    action_t a = {.kind=A_CARRY_SEND,.value=c->cancel,.revision=c->revision,.dy=(int)c->request};
    COPY(a.id,c->agent); copy(a.text,48,c->id); copy(a.text+48,48,c->selection);
    return xQueueSend(actions,&a,0)==pdPASS;
}
static action_t make_action(hit_t h)
{
    action_t a = {.kind = h.action, .value = h.value, .revision = s.q.revision};
    if (s.view == DRAFT || s.view == DRAFT_OPTIONS) {
        a.revision = draft.page.revision; a.dy = (int)draft.page.revision;
        copy(a.text, sizeof draft.page.id, draft.page.id);
    } else if (h.action == A_FORM_MAIN || h.action == A_FORM_BACK || h.action == A_FORM_SAY) {
        a.revision = form.page.revision;
        a.dy = (int)form.page.revision;
        copy(a.text, sizeof form.id, form.id);
    } else if (s.view == SELECTION && (h.action == A_PET || h.action == A_CARRY || h.action == A_SELECT_FIND)) {
        COPY(a.id, selection.agent);
        copy(a.text, sizeof selection.id, selection.id);
        a.dy = (int)selection.revision;
    } else if ((s.view == HOME || s.view == AGENT) && h.action == A_PET && carry.active) {
        if (active()) COPY(a.id,active()->id);
        copy(a.text,sizeof carry.id,carry.id); a.value=3;
    } else if (h.action == A_RETURN) {
        copy(a.text,sizeof visit.id,visit.id); a.revision=visit.request;
    } else if (h.action == A_CARRY_DROP) {
        copy(a.text,sizeof carry.id,carry.id); a.revision=carry.serial;
    } else if (h.action == A_AGENT && h.value < s.count)
        COPY(a.id, s.agents[h.value].id);
    else if (h.action == A_NOTICE && h.value < s.notice_count)
        COPY(a.id, s.notice[h.value].agent_id);
    else if (h.action == A_TAB && h.value < s.tab_count)
        COPY(a.id, s.tabs[h.value].id);
    else if (h.action == A_MACHINE && h.value < s.machine_count)
        COPY(a.id, s.machines[h.value].id);
    else if (h.action == A_MODEL && h.value < s.model_count) {
        COPY(a.id, s.model_agent);
        COPY(a.text, s.models[h.value].id);
    } else if (question_view(s.view) && h.action != A_HOME) {
        COPY(a.id,s.q.agent); a.dy=s.q.index;
    } else if (h.action == A_DESKTOP && h.value == 1)
        COPY(a.id, s.q.agent);
    else if (active())
        COPY(a.id, active()->id);
    return a;
}
static void open_question(void)
{
    if (!s.connected || !active()) return;
    if (!cable_client_supports(CABLE_FEATURE_QUESTIONS)) {
        action_t open={.kind=A_DESKTOP}; COPY(open.id,active()->id);
        queue(open);
        return;
    }
    char agent[ID_MAX], name[64]; COPY(agent,active()->id); copy(name,sizeof active()->name,active()->name);
    uint32_t revision = s.q.revision + 1;
    memset(&s.q,0,sizeof s.q); s.q.revision=revision; s.q.loading=true;
    COPY(s.q.agent,agent); COPY(s.q.name,name);
    snprintf(s.q.fetch,sizeof s.q.fetch,"q-%08lx%08lx",(unsigned long)esp_random(),(unsigned long)esp_random());
    s.q.deadline=ms()+4000;
    action_t a={.kind=A_QUESTION_READ,.revision=revision}; COPY(a.id,agent); copy(a.text,sizeof s.q.fetch,s.q.fetch);
    if (!queue(a)) { s.q.loading=false; COPY(s.q.error,"Could not load. Open the alert again."); }
    view(QUESTION);
}
static bool question_answer(void)
{
    question_item_t *q=&s.q.item[s.q.index];
    if (!s.q.supported) return false;
    if (q->draft[0]) return q->can_text && q->answer[0];
    if (!q->selected) return false;
    q->answer[0]=0; size_t used=0;
    for (int i=0;i<q->count;i++) if (q->selected & (1u<<i)) {
        int n=snprintf(q->answer+used,sizeof q->answer-used,"%s%s",used ? "\n\n" : "",q->options[i]);
        if (n<0 || (size_t)n>=sizeof q->answer-used) return false;
        used+=(size_t)n;
    }
    return used>0;
}
static void question_move(int delta)
{
    if (!question_view(s.view) || !s.q.valid || !s.q.supported || s.q.loading || s.q.pending || s.q.error[0]) return;
    s.q.drag+=delta;
    while (s.q.drag>=40 || s.q.drag<=-40) {
        int step=s.q.drag>0 ? 1 : -1; s.q.drag-=step*40;
        question_item_t *q=&s.q.item[s.q.index];
        const char *value=s.view==QUESTION ? q->prompt : s.view==CHOICE ? q->options[s.q.choice] : q->answer;
        int last=question_rows(value)-Q_ROWS; if (last<0) last=0;
        if (step>0 && s.offset<last) s.offset++;
        else if (step<0 && s.offset>0) s.offset--;
        else if (s.view==CHOICE && s.q.choice+step>=0 && s.q.choice+step<q->count) {
            s.q.choice+=step; s.offset=step>0 ? 0 : question_rows(q->options[s.q.choice])-Q_ROWS;
            if (s.offset<0) s.offset=0;
        }
        change();
    }
}
static void send_answer(void)
{
    if (!s.connected || s.view!=ANSWER_REVIEW || !s.q.valid || s.q.pending ||
        !s.q.supported || !s.q.token[0] || !question_answer()) return;
    if (s.q.index+1<s.q.count) { s.q.index++; s.q.choice=0; view(QUESTION); return; }
    for (int i=0;i<s.q.count;i++) if (!s.q.item[i].selected && !s.q.item[i].draft[0]) return;
    action_t a={.kind=A_ANSWER,.revision=s.q.revision}; COPY(a.id,s.q.agent);
    if (queue(a)) { s.q.pending=true; s.q.deadline=ms()+15000; change(); }
}
static void draft_move(int delta, uint32_t now)
{
    if (s.view != DRAFT || draft.pending || draft.failed || draft.page.locked) return;
    s.draft_drag += delta;
    while (s.draft_drag >= 40 || s.draft_drag <= -40) {
        int step = s.draft_drag > 0 ? 1 : -1;
        s.draft_drag -= step * 40;
        int last = question_rows(draft.page.text) - DRAFT_ROWS;
        if (last < 0) last = 0;
        if (step > 0 && s.offset < last) s.offset++;
        else if (step < 0 && s.offset > 0) s.offset--;
        else if ((step > 0 && draft.page.position < draft.page.total) || (step < 0 && draft.page.position > 1)) {
            ht_draft_command(&draft, HT_DRAFT_MOVE, draft.page.revision, step, now);
            s.draft_drag = 0; change(); return;
        }
        change();
    }
}
static void dispatch(action_t a)
{
#ifdef DEVICE_CREATURE_GALLERY
    (void)a;
    return; // Defense in depth: no voice, commands, approvals, or pane navigation.
#endif
    switch (a.kind) {
    case A_DRAFT_EDIT:
    case A_DRAFT_APPEND:
    case A_DRAFT_UNDO:
    case A_DRAFT_SEND:
    case A_DRAFT_DISCARD:
    case A_DRAFT_STATE:
    case A_DRAFT_OPTIONS:
    case A_DRAFT_BACK:
        if ((s.view != DRAFT && s.view != DRAFT_OPTIONS) || !draft.page.active || draft.pending ||
            a.revision != draft.page.revision || strcmp(a.text, draft.page.id)) break;
        if (a.kind == A_DRAFT_OPTIONS) view(DRAFT_OPTIONS);
        else if (a.kind == A_DRAFT_BACK) view(DRAFT);
        else if (a.kind == A_DRAFT_EDIT || a.kind == A_DRAFT_APPEND) {
            if (draft.failed || draft.page.locked) break;
            view(DRAFT);
            a.value = a.kind == A_DRAFT_APPEND ? 6 : 5; a.kind = A_VOICE;
            ht_gesture_guard(&gesture, ms()); dispatch(a);
        } else {
            ht_draft_op_t op = a.kind == A_DRAFT_SEND ? HT_DRAFT_SEND : a.kind == A_DRAFT_DISCARD ? HT_DRAFT_DISCARD :
                a.kind == A_DRAFT_UNDO ? HT_DRAFT_UNDO : HT_DRAFT_STATE;
            if (ht_draft_command(&draft, op, a.revision, 0, ms())) {
                view(DRAFT); ht_gesture_guard(&gesture, ms());
            }
        }
        break;
    case A_HOME:
        if (workspace.phase!=HT_WORKSPACE_IDLE) {
            ht_workspace_cancel_request(&workspace); s.loading=false; s.active=-1;
        }
        if (visit.pending) { ht_visit_close(&visit); s.pending_focus[0] = 0; }
        view(HOME);
        break;
    case A_AGENTS:
        agents_open();
        break;
    case A_AGENT: {
        int i = find(a.id);
        if (i < 0)
            break;
        if (visit.available && strcmp(visit.agent, a.id)) ht_visit_close(&visit);
        s.active = i;
        view(AGENT);
        if (s.connected)
            queue(a);
        break;
    }
    case A_READER:
        view(READER);
        break;
    case A_QUESTION:
        if (find(a.id) >= 0) s.active = find(a.id);
        open_question();
        break;
    case A_QUESTION_CHOICES:
    case A_QUESTION_REVIEW:
    case A_QUESTION_BACK:
    case A_QUESTION_SAY:
    case A_CHOICE:
    case A_ANSWER:
        if (!question_view(s.view) || a.revision!=s.q.revision || a.dy!=s.q.index ||
            !s.q.valid || s.q.loading || s.q.pending || s.q.error[0] || strcmp(a.id,s.q.agent)) break;
        if (a.kind==A_QUESTION_SAY && s.q.item[s.q.index].can_text) {
            a.kind=A_VOICE; a.value=4; copy(a.text,sizeof s.q.token,s.q.token);
            ht_gesture_guard(&gesture,ms()); dispatch(a);
        } else if (a.kind==A_QUESTION_CHOICES && s.view==QUESTION) view(CHOICE);
        else if (a.kind==A_QUESTION_BACK) view(s.view==ANSWER_REVIEW && !s.q.item[s.q.index].draft[0] ? CHOICE : QUESTION);
        else if (a.kind==A_CHOICE && s.view==CHOICE && a.value>=0 && a.value<s.q.item[s.q.index].count) {
            question_item_t *q=&s.q.item[s.q.index];
            q->draft[0]=q->answer[0]=0; s.q.speech_error[0]=0;
            if (q->multi) q->selected^=1u<<a.value;
            else q->selected=1u<<a.value;
            change();
        } else if (a.kind==A_QUESTION_REVIEW && (s.view==CHOICE || (s.view==QUESTION && s.q.item[s.q.index].draft[0])) && question_answer()) {
            view(ANSWER_REVIEW); ht_gesture_guard(&gesture,ms());
        }
        else if (a.kind==A_ANSWER) send_answer();
        break;
    case A_INBOX:
        notice_open();
        break;
    case A_NF_CARD:
        s.nf_card_at = 0;
        notice_open();
        break;
    case A_NF_PLANS:
        view(NF_PLANS);
        break;
    case A_NF_HUB_CLOSE:
        nf_hub_close();
        break;
    case A_NOTICE: {
        if (s.connected && !visit.pending && a.id[0]) {
            for (int i = 0; i < s.notice_count; i++)
                if (!strcmp(s.notice[i].agent_id, a.id)) notice_mark_read(&s.notice[i]);
            // The shipping bridge supports agent.open, but not the experiment's
            // visit/bookmark protocol. Stay in the inbox while the app opens it;
            // its usual focus/seen messages reconcile the recipient and inbox.
            action_t open={.kind=A_DESKTOP}; COPY(open.id,a.id);
            if (queue(open)) {
                ht_visit_close(&visit);
                COPY(s.opening_notice, a.id);
                // The outcome was already read on this card. Keep its pane in
                // presence mode, including panes whose history arrives later.
                // Opening a question never answers or dismisses that question.
                for (int i = 0; i < s.notice_count; i++)
                    if (!strcmp(s.notice[i].agent_id, a.id) && !s.notice[i].question) {
                        dismiss_result(a.id);
                        break;
                    }
            }
            else {
                COPY(s.title,"Device busy");
                COPY(s.message,"Open the update again.");
                view(MESSAGE);
            }
        }
        break;
    }
    case A_LATEST:
        if (cable_client_supports(CABLE_FEATURE_VISIT) && s.connected && !s.voice_open && !s.loading && !visit.pending &&
            active() && !strcmp(active()->id,a.id)) {
            char id[48];
            if (visit.available) COPY(id,visit.id);
            else snprintf(id,sizeof id,"visit-%08lx%08lx",(unsigned long)esp_random(),(unsigned long)esp_random());
            if (!ht_visit_latest(&visit,id,a.id,ms(),visit_emit,NULL)) {
                COPY(s.title,"Latest output"); COPY(s.message,"The cable is busy. Try again."); view(MESSAGE);
                break;
            }
            COPY(s.title,"Latest output");
            COPY(s.message,"Keeping your reading place...");
            view(MESSAGE);
        }
        break;
    case A_RETURN:
        if (!s.connected || !visit.available || visit.pending || !a.text[0] ||
            strcmp(a.text,visit.id) || a.revision!=visit.request) break;
        if (ht_visit_back(&visit, ms())) {
            COPY(s.title, "Returning");
            snprintf(s.message, sizeof(s.message), "%.79s", visit.label[0] ? visit.label : "Your previous pane");
            view(MESSAGE);
        } else {
            COPY(s.title,"Return"); COPY(s.message,"The cable is busy. Try again."); view(MESSAGE);
        }
        break;
    case A_TABS:
    case A_TAB_LIST:
        tabs_open();
        break;
    case A_MACHINES:
        view(MACHINES);
        break;
    case A_TAB:
        if (!s.connected || s.voice_open || s.loading || workspace_index(a.id)<0) break;
        if (!strcmp(a.id,s.selected_tab)) { view(HOME); break; }
        if (ht_workspace_request(&workspace,a.id,ms())) {
            a.revision=workspace.serial;
            if (!queue(a)) { workspace_failed("Device busy. Choose the tab again."); break; }
            ht_visit_close(&visit); s.pending_focus[0]=0;
            COPY(s.title,"Switching tab"); COPY(s.message,"Opening your workspace...");
            view(MESSAGE); s.loading=true;
        }
        break;
    case A_MACHINE:
        if (s.connected && queue(a)) {
            ht_visit_close(&visit);
            COPY(s.pending_machine, a.id);
            s.machine_deadline = ms() + 6000;
            change();
        }
        break;
    case A_SELECT_FIND:
        a.kind = A_VOICE; a.value = 7;
        dispatch(a); break;
    case A_VOICE:
        if (a.value != 2 && a.value != 4 && a.value != 5 && a.value != 6 && a.value != 7 && s.view != SELECTION && carry.error[0]) {
            COPY(s.title,"Carried text"); copy(s.message,sizeof carry.error,carry.error); view(MESSAGE); break;
        }
        if (a.value == 4 && (!question_view(s.view) || !s.q.valid || !s.q.supported || s.q.pending ||
            a.revision!=s.q.revision || a.dy!=s.q.index || !s.q.item[s.q.index].can_text ||
            strcmp(a.id,s.q.agent) || strcmp(a.text,s.q.token))) break;
        if (a.value == 3 && (!carry.active || strcmp(a.text,carry.id) || !a.id[0])) break;
        if (a.value == 5 || a.value == 6) {
            if (s.view != DRAFT || !draft.page.active || draft.pending || draft.failed || draft.page.locked ||
                a.revision != draft.page.revision || strcmp(a.text, draft.page.id)) break;
            a.id[0] = 0;
        } else if (draft.page.active) { view(DRAFT); break; }
        if (a.value == 2) {
            if (s.view != FORM || form.pending || form.failed || !form.page.active ||
                !form.page.can_query || form.page.busy || strcmp(a.text, form.id) ||
                a.dy < 0 || (uint32_t)a.dy != form.page.revision) break;
        } else if (form.id[0]) { view(FORM); break; }
        if (a.value == 7 && (s.view != SELECTION || strcmp(a.id,selection.agent) ||
            strcmp(a.text,selection.id) || a.dy <= 0 || (uint32_t)a.dy != selection.revision)) break;
        if (s.view == SELECTION && (carry.pending || !ht_selection_ready(&selection) ||
            (a.value != 7 && !selection.excerpt[0]))) break;
        if (s.voice_open || audio_client_active() || s.voice_waiting) {
            s.voice_open = true;
            view(VOICE);
            break;
        }
        if (s.connected && !visit.pending) {
            // Main-surface voice always has an explicit recipient. Home orchestration is deferred.
            if (s.view == HOME || s.view == AGENT) {
                if (!a.id[0] || s.loading) break;
            }
            if (a.value==4) {
                s.voice_question_revision=s.q.revision; s.voice_question_index=s.q.index;
                s.q.speech_error[0]=0;
            }
            a.revision = ++s.voice_generation;
            if (!queue(a))
                break;
            s.voice_open = s.voice_start_pending = true;
            s.voice_carry = a.value == 3;
            s.voice_search = a.value == 7;
            s.voice_review = a.value == 5 || a.value == 6;
            s.voice_draft_append = a.value == 6;
            s.voice_draft_revision = (uint32_t)a.dy;
            s.nap = false;
            s.voice_return = s.view;
            int target = find(a.id);
            if (a.value == 2) snprintf(s.voice_target, sizeof s.voice_target, "Find %.48s",
                !strcmp(form.page.title, "Find Harness") ? "Harness" :
                !strcmp(form.page.title, "New Harness") ? form.page.label : form.page.title);
            else if (a.value == 7) COPY(s.voice_target, "Find in output");
            else if (a.value == 5 || a.value == 6) COPY(s.voice_target, draft.page.name);
            else COPY(s.voice_target, target >= 0 ? s.agents[target].name : "harness");
            s.voice_started = ms();
            view(VOICE);
            ESP_LOGI("habitat", "voice queued generation=%lu", (unsigned long)a.revision);
        }
        break;
    case A_VOICE_STOP:
        if (s.voice_open && !s.voice_start_pending && !s.voice_waiting && audio_client_recording()) {
            if (a.value == 1 && cable_client_supports(CABLE_FEATURE_DRAFT) && !s.voice_search && (s.voice_return == HOME || s.voice_return == AGENT || s.voice_return == SELECTION)) {
                s.voice_review = true; audio_client_request_review();
            }
            audio_client_stop();
            s.voice_waiting = true;
            s.voice_wait_until = ms() + 65000;
            change();
        }
        break;
    case A_VOICE_ABORT:
        audio_client_abort();
        audio_client_copy_upload_id(a.text, sizeof(a.text));
        voice_close();
        queue(a); // also cancel host work after capture has already finished
        ht_gesture_guard(&gesture, ms());
        view(s.voice_return == DRAFT && draft.page.active ? DRAFT : s.voice_return == FORM && form.id[0] ? FORM : question_view(s.voice_return) && s.q.valid ? s.voice_return : HOME);
        if (s.view == DRAFT) ht_draft_command(&draft, HT_DRAFT_STATE, draft.page.revision, 0, ms());
        break;
    case A_PET:
        s.nap = false;
        s.pet_pose = 1;
        s.pet_until = ms() + 900;
        change();
        break;
    case A_SELECT_BEGIN:
        if (cable_client_supports(CABLE_FEATURE_SELECTION) && s.connected && !s.loading && active()) {
            ht_carry_close(&carry);
            char id[48]; snprintf(id, sizeof(id), "pick-%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
            view(SELECTION);
            ht_selection_open(&selection, id, active()->id, ms(), selection_emit, NULL);
            change();
        }
        break;
    case A_SELECT_EXTEND:
        ht_selection_extend(&selection, ms()); change();
        break;
    case A_CARRY:
        if (s.view == SELECTION && !carry.pending && ht_selection_ready(&selection) &&
            selection.excerpt[0] && !strcmp(a.id,selection.agent) &&
            !strcmp(a.text,selection.id) && (uint32_t)a.dy==selection.revision) {
            char id[48]; snprintf(id,sizeof(id),"carry-%08lx%08lx",(unsigned long)esp_random(),(unsigned long)esp_random());
            ht_carry_open(&carry,id,a.id,a.text,(uint32_t)a.dy,ms(),carry_emit,NULL);
            if (carry.error[0]) COPY(selection.error,carry.error);
            change();
        }
        break;
    case A_CARRY_DROP:
        if (a.revision==carry.serial && !strcmp(a.text,carry.id)) {
            ht_carry_close(&carry); change();
        }
        break;
    case A_NAP:
        s.nap = !s.nap;
        s.nap_until = ms() + 15 * 60 * 1000;
        change();
        break;
    case A_FIND:
    case A_FORM: {
        if (!s.connected || s.voice_open) break;
        if (!cable_client_supports(CABLE_FEATURE_FORM)) {
            if (a.kind == A_FIND) view(AGENTS);
            else { COPY(s.title,"New Harness"); COPY(s.message,"Open New Harness on your computer."); view(MESSAGE); }
            break;
        }
        if (!form.id[0]) {
            char id[48]; snprintf(id, sizeof id, "%s-%08lx-%08lx", a.kind == A_FIND ? "find" : "form",
                                  (unsigned long)esp_random(), (unsigned long)ms());
            ht_visit_close(&visit);
            ht_form_open(&form, id, ms(), form_emit, NULL);
        }
        ht_gesture_guard(&gesture, ms());
        view(FORM);
        break;
    }
    case A_FORM_SAY:
        if (s.view == FORM) {
            a.kind = A_VOICE; a.value = 2;
            ht_gesture_guard(&gesture, ms());
            dispatch(a);
        }
        break;
    case A_FORM_MAIN:
        if (s.view == FORM && s.connected) {
            if (form.failed) {
                action_kind_t destination = !strncmp(form.id, "find-", 5) ? A_FIND : A_FORM;
                ht_form_reset(&form); dispatch((action_t){.kind = destination});
            } else ht_form_command(&form, HT_FORM_ACTIVATE, a.revision, 0, ms());
            ht_gesture_guard(&gesture, ms()); change();
        }
        break;
    case A_FORM_BACK:
        if (s.view == FORM && (!form.id[0] ||
            (!strncmp(form.id,"find-",5) && (!s.connected || form.pending || form.failed || !form.page.active)))) {
            ht_form_dismiss(&form); view(HOME); ht_gesture_guard(&gesture,ms());
        } else if (s.view == FORM && s.connected) {
            if (form.failed) {
                action_kind_t destination = !strncmp(form.id, "find-", 5) ? A_FIND : A_FORM;
                ht_form_reset(&form); dispatch((action_t){.kind = destination});
            } else ht_form_command(&form, HT_FORM_BACK, a.revision, 0, ms());
            change();
        }
        break;
    case A_SETTINGS:
        view(SETTINGS);
        break;
    case A_STOP:
        COPY(s.stop_agent, a.id);
        view(STOP);
        break;
    case A_STOP_YES:
        if (s.connected && find(s.stop_agent) >= 0 && s.agents[find(s.stop_agent)].busy) {
            COPY(a.id, s.stop_agent);
            queue(a);
            view(AGENT);
        }
        break;
    case A_MODELS:
        if (s.connected && active()) {
            COPY(s.model_agent, active()->id);
            COPY(s.model_selected, active()->model);
            s.model_count = -1;
            s.model_request = true;
            view(MODELS);
            if (reload_waiter)
                xTaskNotifyGive(reload_waiter);
        }
        break;
    case A_MODEL:
        if (s.connected) {
            queue(a);
            view(AGENT);
        }
        break;
    case A_RECAP_DISMISS:
        dismiss_result(a.id);
        break;
    case A_DESKTOP:
        if (s.connected)
            queue(a);
        break;
    case A_UP:
        s.offset -= s.view == READER ? 5 : 3;
        if (s.offset < 0)
            s.offset = 0;
        change();
        break;
    case A_DOWN:
        if (s.view == INBOX)
            s.offset = s.notice_count ? (s.offset + 1) % s.notice_count : 0;
        else s.offset += s.view == READER ? 5 : 3;
        change();
        break;
    case A_SETTINGS_SAVE:
        break;   // the worker's alone: it is queued, never dispatched from a hit rect
    case A_QUESTION_READ:
    case A_NOTICE_READ:
    case A_TAB_REFRESH:
    case A_NONE:
    case A_SELECT_SEND:
    case A_CARRY_SEND:
    case A_FORM_SEND:
    case A_DRAFT_COMMAND:
    case A_VISIT_SEND:
    case A_SCROLL:
        break;
    }
}
static void worker(void *unused)
{
    (void)unused;
    action_t a;
    static EXT_RAM_BSS_ATTR question_submit_t packet;
    while (xQueueReceive(actions, &a, portMAX_DELAY) == pdTRUE) {
        switch (a.kind) {
        case A_DRAFT_COMMAND: {
            static const char *ops[] = {"state", "move", "undo", "discard", "send"};
            if (a.value >= 0 && a.value <= HT_DRAFT_SEND)
                cable_client_draft(a.id, ops[a.value], a.revision, (uint32_t)a.dy, a.velocity);
            break;
        }
        case A_CARRY_SEND:
            cable_client_carry(a.text,a.id,a.text+48,(uint32_t)a.dy,a.revision,a.value!=0);
            break;
        case A_FORM_SEND: {
            static const char *ops[] = {"open", "state", "move", "activate", "back", "close"};
            if (a.value >= 0 && a.value < 6)
                cable_client_form(a.id, a.revision, ops[a.value], (uint32_t)a.dy, a.velocity);
            break;
        }
        case A_VISIT_SEND: {
            static const char *ops[] = {"open", "back", "cancel", "latest"};
            display_lock();
            bool current=a.value==HT_VISIT_CANCEL ||
                (visit.pending && a.revision==visit.request && a.value==(int)visit.op && !strcmp(a.text,visit.id));
            display_unlock();
            if (current && a.value >= 0 && a.value <= HT_VISIT_LATEST)
                cable_client_visit(a.text, a.revision, ops[a.value], a.id);
            break;
        }
        case A_SELECT_SEND: {
            static const char *ops[] = {"begin", "step", "extend", "extend", "cancel", "match", "lines"};
            if (a.value >= 0 && a.value <= HT_SELECT_LINES)
                cable_client_select_text(a.id, a.text, (uint32_t)a.velocity, a.revision,
                                         ops[a.value], a.dy, a.value == HT_SELECT_EXTEND);
            break;
        }
        case A_SCROLL:
            cable_client_send_scroll((cable_scroll_phase_t)a.value, a.dy, a.velocity);
            break;
        case A_AGENT:
            cable_client_send_focus(a.id);
            break;
        case A_DESKTOP:
            cable_client_send_open(a.id, NULL);
            break;
        case A_NOTICE_READ:
            cable_client_notification_read(a.id, a.text);
            break;
        case A_TAB: {
            display_lock();
            bool valid=s.connected && workspace.phase==HT_WORKSPACE_WAIT_TAB &&
                a.revision==workspace.serial && !strcmp(a.id,workspace.pending);
            display_unlock();
            if (valid) cable_client_select_swarm(a.id);
            break;
        }
        case A_TAB_REFRESH: {
            uint32_t generation=cable_client_agent_generation();
            display_lock();
            bool valid=s.connected && ht_workspace_refresh(&workspace,a.revision,generation);
            display_unlock();
            if (valid && !cable_client_request_agents()) {
                display_lock();
                if (a.revision==workspace.serial && workspace.phase!=HT_WORKSPACE_IDLE)
                    workspace_failed("Could not refresh the tab. Try again.");
                display_unlock();
            }
            break;
        }
        case A_MACHINE:
            cable_client_select_machine(a.id);
            break;
        case A_VOICE:
            display_lock();
            if (s.connected && s.voice_open && s.voice_start_pending &&
                a.revision == s.voice_generation) {
                if (a.value == 7) audio_client_start_search(a.id, a.text, (unsigned)a.dy);
                else if (a.value == 5 || a.value == 6) audio_client_start_draft(a.text, (unsigned)a.dy, a.value == 6);
                else if (a.value == 4) audio_client_start_question(a.id,a.text,(unsigned)a.dy);
                else if (a.value == 2) audio_client_start_form(a.text, (unsigned)a.dy);
                else if (a.value == 3) audio_client_start_carry(a.id,a.text);
                else if (a.text[0] && a.dy > 0) audio_client_start_selection(a.id, a.text, (unsigned)a.dy);
                else audio_client_start_cable(a.id[0] ? a.id : NULL,
                                              a.value == 1 ? VOICE_CMD_GOAL : VOICE_CMD_NONE);
                s.voice_start_pending = false;
                change();
            }
            display_unlock();
            break;
        case A_VOICE_ABORT:
            cable_client_voice_cancel(a.text);
            break;
        case A_STOP_YES:
            cable_client_stop_turn(a.id);
            break;
        case A_MODEL: {
            const char *p = strrchr(a.text, ':');
            char model[128];
            COPY(model, p ? p + 1 : a.text);
            char *effort = strrchr(model, '@');
            if (effort)
                *effort++ = 0;
            cable_client_agent_update(a.id, model, effort);
            break;
        }
        case A_SETTINGS_SAVE: {
            // Everything the app asked for, written off the render path. The report at the end carries
            // what the device HOLDS, read back — which is what corrects a window whose change failed.
            display_lock();
            ui_settings_t want = settings_pending.values;
            uint32_t fields = settings_pending.fields;
            settings_pending.fields = 0;
            display_unlock();
            if (fields & UI_SETTING_BRIGHTNESS)
                config_save_brightness((uint8_t)((want.brightness * 255 + 50) / 100));
            if (fields & UI_SETTING_CHARACTER && !config_save_habitat_character(want.character))
                ui_cable_toast("Character changed; saving failed.");
            if (fields & (UI_SETTING_QUIET | UI_SETTING_STRAIGHT_TITLE | UI_SETTING_FOCUS_FACE | UI_SETTING_FOLLOW_COMPANION)) {
                // Bit 1 was rim scrolling and is RETIRED, not reused: devices in the field still
                // hold it set, and a new preference on that bit would inherit their answer.
                uint8_t options = (uint8_t)((want.focus_face ? 1 : 0) |
                                            (want.quiet ? 4 : 0) | (want.straight_title ? 8 : 0) |
                                            (want.follow_companion ? 0 : 16));
                if (!config_save_habitat_options(options))
                    ui_cable_toast("Preference changed; saving failed.");
            }
            if (fields & UI_SETTING_SCROLL) config_save_scroll_reversed(want.scroll_reversed);
            if (fields & UI_SETTING_VOICELANG) config_save_voicelang(want.voicelang);
            if (fields & UI_SETTING_MUTED && !audio_notify_set_muted(want.muted))
                ui_cable_toast("Sound changed; saving failed.");
            ui_settings_changed();
            break;
        }
        case A_QUESTION_READ:
            cable_client_question_read(a.id,a.text);
            break;
        case A_ANSWER: {
            display_lock();
            bool valid=s.q.valid && s.q.pending && s.q.revision==a.revision && !strcmp(a.id,s.q.agent);
            if (valid) {
                COPY(packet.agent,s.q.agent); COPY(packet.fetch,s.q.fetch); COPY(packet.token,s.q.token);
                packet.count=s.q.count;
                for (int i=0;i<packet.count;i++) {
                    packet.choices[i]=s.q.item[i].selected; COPY(packet.drafts[i],s.q.item[i].draft);
                }
            }
            display_unlock();
            if (!valid) break;
            bool sent=cable_client_answer_reviewed(packet.agent,packet.fetch,packet.token,packet.choices,packet.drafts,packet.count);
            if (!sent) {
                display_lock();
                if (s.q.revision==a.revision) {
                    s.q.uncertain=true; COPY(s.q.error,"Could not confirm sending. Check the terminal."); change();
                }
                display_unlock();
            }
            break;
        }
        default:
            break;
        }
    }
}
void habitat_touch(bool down, int x, int y, uint32_t now)
{
#ifdef DEVICE_CREATURE_GALLERY
    if (s.ready) {
        ht_gallery_touch(&gallery, down, x, y, now);
        habitat_render_notify();
    }
    return;
#endif
    if (!s.ready)
        return;
    bool surface = s.view == HOME || s.view == AGENT;
    if (s.touch_down && !s.touch_cancelled) {
        // Classify this sample before the hold deadline. A delayed MOVE/UP
        // must not turn a long swipe into a stationary hold.
        ht_gesture_move(&gesture, x, y);
        surface_tick(now);
    }
    surface = s.view == HOME || s.view == AGENT;
    if (down && !s.touch_down) {
        s.touch_cancelled = false;
        s.touch_brake = s.coasting && (int32_t)(now - s.coast_until) < 0;
        s.coasting = false;
        ht_scroll_cancel(&scroll);
        scroll = (ht_scroll_t){0};
        s.start_x = x;
        s.start_y = y;
        s.touch_started = now;
        if (question_view(s.view)) s.q.drag=0;
        s.draft_drag = 0;
        s.tab_drag = 0;
        s.pressed = -1;
        pressed_action = make_action((hit_t){.action = A_NONE});
        for (int i = 0; i < s.hit_count; i++) {
            hit_t h = s.hits[i];
            if (h.enabled && hit_contains(&h, x, y, surface)) {
                s.pressed = i;
                pressed_action = make_action(h);
                s.pressed_rect = h.rect;   // a footer release has to land back inside it — see below
                break;
            }
        }
        if (surface && pressed_action.kind==A_TABS && !s.touch_brake)
            ht_workspace_touch(&workspace,workspace_index(s.selected_tab),s.tab_count,x,y,now);
        if (s.view == TABS && pressed_action.kind == A_TAB) ht_tab_carousel_begin(&tab_carousel, x, now);
        ht_gesture_begin(&gesture, x, y, now, ((uint32_t)s.view << 8) | pressed_action.kind);
        if (pressed_action.kind != A_PET && pressed_action.kind != A_FORM_MAIN && pressed_action.kind != A_FORM_SAY &&
            pressed_action.kind != A_ANSWER && pressed_action.kind != A_DRAFT_SEND && pressed_action.kind != A_DRAFT_EDIT &&
            pressed_action.kind != A_DRAFT_APPEND && pressed_action.kind != A_DRAFT_UNDO) gesture.guarded = false; // Discard is always immediate.
        if (s.pressed >= 0 && ((!surface && s.view != VOICE) || home_footer(pressed_action.kind))) change();
        if (ui_scroll_reportable()) {
            if (surface && home_footer(pressed_action.kind)) {
                // Footer choices send no terminal scroll. A contact
                // that stops an existing fling still has to reach the app.
                if (s.touch_brake) {
                    ht_scroll_begin(&scroll,x,y,now,scroll_reversed,scroll_emit,NULL);
                    ht_scroll_cancel(&scroll);
                }
            } else ht_scroll_begin(&scroll, x, y, now, scroll_reversed, scroll_emit, NULL);
        }
    } else if (down && !s.touch_cancelled) {
        ht_gesture_move(&gesture, x, y);
        if (surface && home_footer(pressed_action.kind)) {
            if (pressed_action.kind==A_TABS && ht_workspace_move(&workspace,x,y,gesture.axis,now)) change();
        } else if (s.view == TABS) {
            if (gesture.axis == 2 && ht_tab_carousel_move(&tab_carousel, x, now)) change();
        } else if (s.view == AGENTS && character.id == HT_CHARACTER_FOCUS && gesture.axis == 1) {
            panes_move((s.last_y - y) * (scroll_reversed ? -1 : 1));
        } else if ((s.view == AGENTS || s.view == SETTINGS) && gesture.axis == 1) {
            tabs_move((s.last_y - y) * (scroll_reversed ? -1 : 1));
        } else if (s.view == DRAFT && gesture.axis == 1) {
            draft_move((s.last_y - y) * (scroll_reversed ? -1 : 1), now);
        } else if (s.view == FORM && gesture.axis == 1) {
            ht_form_move(&form, (s.last_y - y) * (scroll_reversed ? -1 : 1), now);
        } else if (question_view(s.view) && gesture.axis == 1) {
            question_move((s.last_y-y)*(scroll_reversed ? -1 : 1));
        } else if (s.view == SELECTION && gesture.axis == 1) {
            int travel = (s.last_y - y) * (scroll_reversed ? -1 : 1);
            ht_selection_move(&selection, travel, now);
            change();
        } else ht_scroll_move(&scroll, x, y, now);
        if (gesture.moved && s.pressed >= 0) {
            s.pressed = -1;
            if ((!surface && s.view != VOICE) || home_footer(pressed_action.kind)) change();
        }
    }
    if (!down && s.touch_down) {
        ht_touch_result_t result = ht_gesture_end(&gesture, x, y, now);
        if (s.view == AGENTS && character.id == HT_CHARACTER_FOCUS) {
            if (!s.touch_cancelled && gesture.axis == 1) panes_move((s.last_y - y) * (scroll_reversed ? -1 : 1));
            panes_settle();
        } else if (!s.touch_cancelled && (s.view == AGENTS || s.view == SETTINGS) && gesture.axis == 1)
            tabs_move((s.last_y - y) * (scroll_reversed ? -1 : 1));
        bool tab_contact = s.view == TABS && tab_carousel.touching;
        bool tab_tap = tab_contact && ht_tab_carousel_end(&tab_carousel, x, gesture.axis == 2, now);
        bool scrolled = ht_scroll_end(&scroll, x, y, now);
        if (scrolled) {
            uint32_t coast = ht_scroll_coast_ms(scroll.velocity);
            s.coasting = coast > 0;
            s.coast_until = now + coast;
        }
        int dx = x - s.start_x, dy = y - s.start_y;
        s.pressed = -1;
        if (!s.touch_cancelled && gesture.axis == 1 && abs(dy) > 40 && nf_card_swipe(s.start_y, dy)) {
            // nixfred: a swipe up from the card dismissed it (with its trail).
        } else if (s.view == NF_HUB && !s.touch_cancelled && (abs(dx) > 40 || abs(dy) > 40)) {
            nf_hub_close();   // nixfred slice 5: a swipe either way closes the hub, opening nothing
        } else if (scrolled || s.touch_cancelled) {
            // Motion owns this entire contact, even if it returns to its start.
        } else if (tab_contact) {
            int index = pressed_action.value;
            if (tab_tap && result == HT_TOUCH_TAP && pressed_action.kind == A_TAB && index >= 0 &&
                index < s.tab_count && !strcmp(pressed_action.id, s.tabs[index].id)) dispatch(pressed_action);
            change();
        } else if (result == HT_TOUCH_TAP && s.touch_brake) {
            // DOWN already stopped desktop inertia. This entire tap is only a brake.
        } else if (surface && pressed_action.kind==A_TABS) {
            bool cancelled=workspace.cancelled || (workspace.touching && now-workspace.began>=5000);
            int chosen=ht_workspace_release(&workspace,x,y,gesture.axis,now);
            if (!s.touch_brake && !cancelled) {
                if (chosen>=0 && chosen<s.tab_count) {
                    action_t tab={.kind=A_TAB}; COPY(tab.id,s.tabs[chosen].id); dispatch(tab);
                } else if (result==HT_TOUCH_TAP || result==HT_TOUCH_HOLD) dispatch((action_t){.kind=A_TABS});
            }
            change();
        } else if (surface && home_footer(pressed_action.kind)) {
            /*
             * A BUTTON IS PRESSED AND RELEASED, not tapped within a tolerance.
             *
             * ht_gesture_end() calls a contact moved at 12 px — 1.20 mm on this glass — and allows a
             * tap 350 ms. A thumb on a circle held in the hand drifts further than that and lingers
             * longer, so a press that looked perfectly still classified as HT_TOUCH_NONE and the
             * button did nothing. Same fault the voice Discard control had, measured then at 21
             * presses in 49; the Focus face's microphone is where it surfaced again.
             *
             * So a footer control answers a release that lands back inside the rect its press began
             * on. Dragging OFF it still cancels — that is what makes it a button rather than a region
             * — and the footer has no scroll or swipe of its own to compete with, which is why the
             * rule belongs here and not on the surface above it, where 12 px is also what claims a
             * scroll.
             */
            bool on_target = s.pressed_rect.w &&
                x >= s.pressed_rect.x && x < s.pressed_rect.x + s.pressed_rect.w &&
                y >= s.pressed_rect.y && y < s.pressed_rect.y + s.pressed_rect.h;
            if (result == HT_TOUCH_TAP || (on_target && now - s.touch_started < 1800))
                dispatch(pressed_action);
            change();
        } else if (result == HT_TOUCH_TAP && pressed_action.kind == A_PET &&
                   (surface || s.view == VOICE || s.view == SELECTION)) {
            ht_gesture_guard(&gesture, now);
            if (s.view == VOICE) {
                ESP_LOGI("habitat", "gesture tap: finish voice");
                dispatch((action_t){.kind = A_VOICE_STOP});
            } else if (character.id == HT_CHARACTER_FOCUS && s.view != SELECTION) {
                /*
                 * On Focus the microphone starts speech and nothing else does. A creature skin has
                 * no button — the creature IS the affordance, so the middle of the glass has to be
                 * one. Focus draws its button, and the middle is the recap somebody is reading: a
                 * tap there opening the mic surprised people, and the mic is right under it.
                 */
            } else if (s.connected && !s.loading && pressed_action.id[0]) {
                ESP_LOGI("habitat", "gesture tap: start voice");
                pressed_action.kind = A_VOICE;
                dispatch(pressed_action);
            }
        } else if (result == HT_TOUCH_HOLD) {
            if (s.view == VOICE && pressed_action.kind == A_PET && cable_client_supports(CABLE_FEATURE_DRAFT)) {
                ht_gesture_guard(&gesture, now);
                dispatch((action_t){.kind = A_VOICE_STOP, .value = 1});
            } else if (s.view == DRAFT && pressed_action.kind == A_DRAFT_EDIT) {
                pressed_action.kind = A_DRAFT_OPTIONS; dispatch(pressed_action);
            } else if (surface && pressed_action.kind == A_PET)
                tabs_open();
        } else if (result == HT_TOUCH_TAP) {
            if (pressed_action.kind == A_PET) {
                if (surface) dispatch(pressed_action); // immediate, harmless acknowledgement
            } else {
                ht_gesture_cancel(&gesture);
                dispatch(pressed_action);
            }
        } else if (gesture.axis == 1 && abs(dy) > 55 && abs(dy) > abs(dx)) {
            if (s.view == TABS || s.view == AGENTS || s.view == SETTINGS) {
                // The list consumed the drag already, including its final sample.
            } else if (s.view == DRAFT || s.view == DRAFT_OPTIONS) {
                // Reading a draft never submits or starts recording.
            } else if (s.view == FORM) {
                // The form cursor consumed the drag; never launch from motion.
            } else if (question_view(s.view)) {
                // Reading/choosing consumed this contact; motion cannot submit an answer.
            } else if (s.view == SELECTION) {
                // Its bounded reading cursor already consumed this vertical drag.
            } else if (surface && character.id == HT_CHARACTER_FOCUS && dy > 0 && notice_unread(active() ? active()->id : NULL)) {
                // Pull down from the badge. The creature skins keep this drag inert — their footer
                // badge is a target you tap — but on Focus the badge sits at the top edge and a pull
                // is the gesture the rest of the world already means by it.
                view(INBOX);
            } else if (surface) {
                // A congested scroll queue cannot turn a scroll into navigation or voice.
            } else if (s.start_y >= 400 && dy < 0)
                view(HOME);
            else if (s.view == READER) {
                int next = s.offset + (dy < 0 ? 5 : -5);
                s.offset = next < 0 ? 0 : next;
            } else if (s.view == INBOX && s.notice_count)
                s.offset = (s.offset + (dy < 0 ? 1 : s.notice_count - 1)) % s.notice_count;
            else {
                int count = s.view == AGENTS     ? s.count
                            : s.view == TABS     ? s.tab_count
                            : s.view == MACHINES ? s.machine_count
                            : s.view == MODELS   ? s.model_count
                            : s.view == SETTINGS ? 9
                            : s.view == QUESTION ? s.q.item[s.q.index].count : 0;
                int next = s.offset + (dy < 0 ? 3 : -3);
                if (next >= 0 && next < count) s.offset = next;
            }
        } else if (gesture.axis == 2 && abs(dx) > 60 && abs(dx) > abs(dy)) {
            if (s.view == TABS) {
                // The carousel owns horizontal motion, including contacts that began on its footer.
            } else if (s.view == DRAFT || s.view == DRAFT_OPTIONS) {
                if (dx > 0) {
                    action_t a = make_action((hit_t){.action = s.view == DRAFT ? A_DRAFT_OPTIONS : A_DRAFT_BACK});
                    dispatch(a);
                }
            } else if (s.view == FORM) {
                if (dx > 0) dispatch((action_t){.kind = A_FORM_BACK, .revision = form.page.revision});
            } else if (question_view(s.view)) {
                if (dx>0 && !s.q.pending) view(s.view==ANSWER_REVIEW ? CHOICE : s.view==CHOICE ? QUESTION : HOME);
            } else if (s.view == INBOX && s.notice_count)
                s.offset = (s.offset + (dx < 0 ? 1 : s.notice_count - 1)) % s.notice_count;
            else if (surface && s.count && s.connected && !s.loading) {
                int i = s.active < 0 ? 0 : (s.active + (dx < 0 ? 1 : s.count - 1)) % s.count;
                action_t a = {.kind = A_AGENT};
                COPY(a.id, s.agents[i].id);
                dispatch(a);
            } else if (!surface)
                view(HOME);
        }
        change();
    }
    s.touch_down = down;
    s.last_x = x;
    s.last_y = y;
    surface_tick(now);
}
void habitat_touch_cancel(void)
{
#ifdef DEVICE_CREATURE_GALLERY
    ht_gallery_cancel(&gallery);
    return;
#endif
    bool visible = s.touch_down || s.pressed >= 0;
    input_cancel();
    s.touch_down = false; // driver swallows the rest of this contact until a trustworthy UP
    if (visible) change();
}
bool habitat_is_voice_view(void) { return s.view == VOICE; }
uint32_t habitat_next_wake_ms(void)
{
#ifdef DEVICE_CREATURE_GALLERY
    return display_is_asleep() ? 1000 : ht_gallery_wake(&gallery, ms());
#endif
    uint32_t delay = 1000, now = ms();
    if (!s.ready)
        return delay;
    if (s.voice_open)
        delay = 125;
    if (s.view == TABS && tab_carousel.animating && !display_is_asleep()) delay = 16;
    if (selection.pending && delay > 100) delay = 100;
    if (visit.pending && delay > 100) delay = 100;
    if (s.view == FORM && delay > 100) delay = 100;
    if (character.motion.next_ms && character.motion.next_ms < delay) delay = character.motion.next_ms;
    if (home_caption_rotates() && home_caption.next_ms && home_caption.next_ms < delay)
        delay = home_caption.next_ms;
    if (brand_visible() && !(s.view == OTA && s.ota_pct >= 0)) {
        uint32_t period = 1000 / NIXFRED_SCAN_STEPS, due = period - now % period;
        if (due < delay) delay = due ? due : 1;
    }
    {
        uint32_t period = nf_period(now);
        if (period) { uint32_t due = period - now % period; if (due < delay) delay = due ? due : 1; }
        else if (s.nf_tick && delay > 1) delay = 1; // the last frame of an animation that just ended
    }
    if (status_animated()) {
        uint32_t due = status_wake_ms(now);
        if (due < delay) delay = due;
    }
    if ((s.view == HOME || s.view == AGENT) && pressed_action.kind == A_PET && s.touch_down && !s.touch_cancelled &&
        gesture.live && !gesture.moved && !gesture.guarded) {
        uint32_t elapsed = now - s.touch_started;
        uint32_t due = 650;
        uint32_t left = elapsed >= due ? 1 : due - elapsed;
        if (left < delay) delay = left;
    }
    {
        uint32_t hold = nf_hold_wait(now);
        if (hold && hold < delay) delay = hold;
    }
    uint32_t deadlines[] = {s.pet_pose ? s.pet_until : 0, s.nap ? s.nap_until : 0,
                            s.voice_retry_until};
    for (unsigned i = 0; i < sizeof(deadlines) / sizeof(deadlines[0]); i++)
        if (deadlines[i]) {
            int32_t left = (int32_t)(deadlines[i] - now);
            if (left <= 0)
                return 1;
            if ((uint32_t)left < delay)
                delay = (uint32_t)left;
        }
    return delay;
}
void habitat_tick(void)
{
#ifdef DEVICE_CREATURE_GALLERY
    if (s.ready && !display_is_asleep()) ht_gallery_tick(&gallery, ms());
    return;
#endif
    if (!s.ready)
        return;
    uint32_t now = ms();
    if (s.voice_retry_until && (int32_t)(now - s.voice_retry_until) >= 0) {
        s.voice_retry_until = 0;
        change();
    }
    surface_tick(now);
    if (ht_workspace_tick(&workspace,now)) workspace_failed("The tab did not open. Choose it again.");
    if ((s.q.loading || (s.q.pending && !s.q.uncertain)) && (int32_t)(now-s.q.deadline)>=0) {
        if (s.q.loading) { s.q.loading=false; COPY(s.q.error,"Question did not arrive. Open the alert again."); }
        else { s.q.uncertain=true; COPY(s.q.error,"No answer receipt. Check the terminal before trying again."); }
        change();
    }
    if (ht_selection_tick(&selection, now)) change();
    if (!(s.voice_open && s.voice_carry) && ht_carry_tick(&carry,now)) {
        if (carry.error[0] && s.view==SELECTION) COPY(selection.error,carry.error);
        change();
    }
    // A background read must not begin halfway through a person's tap/drag.
    // An already pending request still settles or times out normally.
    if (s.view == FORM && (!s.touch_down || form.pending) && ht_form_tick(&form, now)) change();
    if (ht_draft_tick(&draft, now)) change();
    if (ht_visit_tick(&visit, now)) {
        s.pending_focus[0] = 0;
        COPY(s.title, "Visit ended");
        COPY(s.message, "The app did not answer. Try the alert again.");
        view(MESSAGE);
    }
    if (selection.active && !s.voice_open &&
        (!s.connected || !active() || strcmp(active()->id, selection.agent))) view(HOME);
    if (s.pet_pose && (int32_t)(now - s.pet_until) >= 0) {
        s.pet_pose = 0;
        change();
    }
    if (s.nap && (int32_t)(now - s.nap_until) >= 0) {
        s.nap = false;
        change();
    }
    if (s.voice_open) {
        display_bump_activity();
        uint32_t second = (now - s.voice_started) / 1000;
        // Recording is explicitly started and finished by the person. The energy estimate can
        // miss quiet speech and normal gaps between syllables; it must never discard their words.
        // Keep the existing duration cap, using the same finalization as tapping Done.
        if (audio_client_recording() && !s.voice_waiting && second >= 600) {
            audio_client_stop();
            s.voice_waiting = true;
            s.voice_wait_until = now + 65000;
            change();
        }
        if (!s.voice_start_pending && !audio_client_active() && !s.voice_waiting &&
            now - s.voice_started > 700) {
            dispatch((action_t){.kind = A_VOICE_ABORT});
            if (s.view == FORM) {
                COPY(form.page.error, "Recording stopped. Say the name again."); form.poll = now + 6000; change();
            } else if (s.view == DRAFT) {
                COPY(draft.page.error, "Recording stopped. Checking your draft."); change();
            } else {
                COPY(s.title, "Voice"); COPY(s.message, "Recording stopped. Please try again."); view(MESSAGE);
            }
        }
        if (s.voice_waiting && (int32_t)(now - s.voice_wait_until) >= 0) {
            dispatch((action_t){.kind = A_VOICE_ABORT});
            if (s.view == FORM) {
                COPY(form.page.error, "Search timed out. Say the name again."); form.poll = now + 6000; change();
            } else if (s.view == DRAFT) {
                COPY(draft.page.error, "No voice reply. Checking your draft."); change();
            } else {
                COPY(s.title, "Voice"); COPY(s.message, "No response yet. Check Harness on your computer."); view(MESSAGE);
            }
        }
    }
}
static void power(bool on)
{
    if (!on) {
        input_cancel();
        if (!s.voice_open && selection.active) view(HOME);
        return;
    }
}
void ui_init(void)
{
    display_lock();
    memset(&s, 0, sizeof(s));
    s.active = -1;
    s.ota_pct = -1;
    s.pressed = -1;
    s.brightness = (config_load_brightness() * 100 + 127) / 255;
    s.muted = config_load_muted();
    memset(&character, 0, sizeof character);
    memset(&home_caption, 0, sizeof home_caption);
    uint8_t saved_character = config_load_habitat_character((uint8_t)ht_character_default());
    if (!ht_character_select(&character, (ht_character_id_t)saved_character))
        ht_character_select(&character, ht_character_default());
    device_skin = character.id <= HT_CHARACTER_FOCUS ? character.id : ht_character_default();
    desktop_companion = HT_CHARACTER_COUNT;
    ht_character_select(&character, device_skin);
    ESP_LOGI("habitat", "character %s; shared moods and controls", ht_character_name(character.id));
    uint8_t options = config_load_habitat_options();
    follow_companion = !(options & 16);
#ifdef HABITAT_FOCUS_ONLY
    device_skin = HT_CHARACTER_FOCUS;
    follow_companion = false;
    ht_character_select(&character, device_skin);
#endif
    s.focus_face = (options & 1) != 0;
    s.quiet = (options & 4) != 0;
    s.straight_title = (options & 8) != 0;
    s.ready = true;
#ifdef DEVICE_CREATURE_GALLERY
    ht_gallery_init(&gallery, ms());
    ESP_LOGI("gallery", "20 text creatures / local only; swipe X creature, Y mood or speed, tap replay");
#endif
    s.loading = true;
    s.view = HOME;
    s.dirty = true;
    scroll_reversed = config_load_scroll_reversed();
    display_set_power_cb(power);
    actions = xQueueCreate(8, sizeof(action_t));
    assert(actions);
    assert(xTaskCreate(worker, "habitat_actions", 6144, NULL, 4, NULL) == pdPASS);
    display_unlock();
    habitat_render_notify();
}
/*
 * THE SETTINGS, AS THE APP READS AND WRITES THEM.
 *
 * NVS is the record and this screen is the applier, so every field goes through the same two steps it
 * takes when a finger changes it here: save, then move the live state under the display lock. Read is
 * deliberately NOT a copy of what was last written — it reports what the device actually holds, which
 * is what makes a refusal self-correcting at the other end.
 */
void ui_settings_read(ui_settings_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    display_lock();
    out->brightness = (uint8_t)s.brightness;
    out->muted = s.muted;
    out->character = (uint8_t)device_skin;
    out->follow_companion = follow_companion;
    const char *species = follow_companion ? ht_character_species(desktop_companion) : NULL;
    if (species) {
        snprintf(out->companion, sizeof out->companion, "%s", species);
        out->companion_details=desktop_identity;
    }
    out->quiet = s.quiet;
    out->straight_title = s.straight_title;
    out->focus_face = s.focus_face;
    out->scroll_reversed = scroll_reversed;
    // This firmware only builds round. The field stays on the wire because another device speaking
    // this protocol may not be, and the app hides a row rather than greying it — see ui_screens.h.
    out->round = true;
    out->face = HT_WIDTH;
    config_load_voicelang(out->voicelang, sizeof out->voicelang);
    display_unlock();
}
bool ui_settings_apply(const ui_settings_t *want, uint32_t fields, char *error, size_t cap)
{
    if (!want) return false;
    if (error && cap) error[0] = 0;
    // Validate everything BEFORE writing anything: a frame that names four rows and fails on the third
    // must not leave two of them changed and the app told the whole thing was refused.
    if ((fields & UI_SETTING_BRIGHTNESS) && want->brightness > 100) {
        if (error) snprintf(error, cap, "Brightness is 0 to 100.");
        return false;
    }
    if (fields & UI_SETTING_CHARACTER) {
        ht_character_t probe;
        memset(&probe, 0, sizeof probe);
        if (want->character > HT_CHARACTER_FOCUS || !ht_character_select(&probe, (ht_character_id_t)want->character)) {
            if (error) snprintf(error, cap, "This device has no such character.");
            return false;
        }
    }
    if ((fields & UI_SETTING_VOICELANG) && !memchr(want->voicelang, '\0', sizeof want->voicelang)) {
        if (error) snprintf(error, cap, "Language code is too long.");
        return false;
    }
    display_lock();
    // The live state moves now, so the next frame is already right; the flash write is the worker's.
    if (fields & UI_SETTING_BRIGHTNESS) {
        s.brightness = want->brightness;
        display_set_brightness((uint8_t)((want->brightness * 255 + 50) / 100));
    }
#ifdef HABITAT_FOCUS_ONLY
    fields &= ~(uint32_t)(UI_SETTING_CHARACTER | UI_SETTING_FOLLOW_COMPANION);
#endif
    if (fields & UI_SETTING_CHARACTER) device_skin = (ht_character_id_t)want->character;
    if (fields & UI_SETTING_FOLLOW_COMPANION) follow_companion = want->follow_companion;
    select_companion();
    if (fields & UI_SETTING_FOCUS_FACE) s.focus_face = want->focus_face;
    if (fields & UI_SETTING_QUIET) s.quiet = want->quiet;
    if (fields & UI_SETTING_STRAIGHT_TITLE) s.straight_title = want->straight_title;
    if (fields & UI_SETTING_SCROLL) scroll_reversed = want->scroll_reversed;
    if (fields & UI_SETTING_MUTED) s.muted = want->muted;
    settings_pending.values = *want;
    settings_pending.values.brightness = (uint8_t)s.brightness;
    settings_pending.fields |= fields;
    bool queued = !fields || queue((action_t){.kind = A_SETTINGS_SAVE});
    change();
    display_unlock();
    if (!queued && error) snprintf(error, cap, "The device is busy. Try again.");
    return queued;
}
void ui_settings_changed(void)
{
    cable_client_report_settings();
}
bool ui_set_companion_identity(const ui_companion_t *identity)
{
    ht_character_id_t id=ht_character_companion(identity?identity->id:NULL);
    if (identity && (id==HT_CHARACTER_COUNT || identity->colour < -1 || identity->colour>5 || identity->mark>4 ||
        (strcmp(identity->version,"0.1") && strcmp(identity->version,"1.0") && strcmp(identity->version,"2.0")))) return false;
    display_lock();
    desktop_companion=id; companion_celebrating=false;
    desktop_identity=identity?*identity:(ui_companion_t){.colour=-1};
    select_companion(); change(); display_unlock();
    ESP_LOGI("companion","desktop=%s uid=%s version=%s colour=%d mark=%u",identity?identity->id:"none",
        identity?identity->uid:"",identity?identity->version:"",identity?identity->colour:-1,identity?identity->mark:0);
    return true;
}
bool ui_set_companion(const char *species)
{
    if (!species) return ui_set_companion_identity(NULL);
    if (ht_character_companion(species)==HT_CHARACTER_COUNT) return false;
    ui_companion_t identity={.colour=-1};
    snprintf(identity.id,sizeof identity.id,"%s",species);
    snprintf(identity.uid,sizeof identity.uid,"%s",species);
    snprintf(identity.name,sizeof identity.name,"%s",species);
    snprintf(identity.version,sizeof identity.version,"2.0");
    return ui_set_companion_identity(&identity);
}
bool ui_companion_celebrate(const ui_companion_t *identity,const char *kind,const char *token)
{
    if (!identity || !token || !token[0] || strlen(token)>=sizeof celebration_tokens[0] ||
        (!kind || (strcmp(kind,"hatch") && strcmp(kind,"grow"))) ||
        ht_character_companion(identity->id)==HT_CHARACTER_COUNT || identity->colour < -1 || identity->colour > 5 || identity->mark > 4 ||
        (strcmp(identity->version,"0.1") && strcmp(identity->version,"1.0") && strcmp(identity->version,"2.0"))) return false;
    display_lock();
    bool seen=false;
    for (unsigned i=0;i<8;i++) if (!strcmp(token,celebration_tokens[i])) seen=true;
    if (!seen) {
        snprintf(celebration_tokens[celebration_next++%8],sizeof celebration_tokens[0],"%s",token);
        // A sleeping/reading/quiet dial consumes the event without scheduling a later surprise.
        if (follow_companion && s.connected && !s.quiet && !s.nap && s.view==HOME && !display_is_asleep() && !s.touch_down && character_mood()!=HT_CHARACTER_ATTENTION) {
            celebration_identity=*identity; companion_celebrating=true; celebration_began=ms();
            snprintf(celebration_label,sizeof celebration_label,"%.24s %s",identity->name,!strcmp(kind,"hatch")?"hatched!":"grew!");
            select_companion(); change();
            ESP_LOGI("companion","milestone=%s token=%s",kind,token);
        }
    }
    display_unlock(); return true;
}
void ui_set_brightness(uint8_t level)
{
    display_lock();
    s.brightness = (level * 100 + 127) / 255;
    display_set_brightness(level);
    change();
    display_unlock();
}

// Protocol-facing adapter. The cable reader never waits for rendering or a DMA transaction.
void ui_set_connected(bool value)
{
    display_lock();
    if (!value) {
        desktop_companion = HT_CHARACTER_COUNT;
        desktop_identity=(ui_companion_t){.colour=-1}; companion_celebrating=false;
        select_companion();
        input_cancel();
        s.voice_retry_until = 0;
        s.pending_machine[0] = 0;
        // A reconnect may bring a newer saved result than our last live event.
        for (int i = 0; i < PANE_MEMORY_MAX; i++) s.memory[i].live_summary = false;
        if (workspace.phase!=HT_WORKSPACE_IDLE) {
            ht_workspace_cancel_request(&workspace); s.loading=false; s.active=-1; view(HOME);
        }
        s.q.valid=s.q.loading=s.q.pending=false; s.q.revision++;
        if (question_view(s.view)) view(HOME);
        ht_visit_close(&visit);
        ht_carry_close(&carry);
    }
    s.connected = value;
    if (value) s.nf_retries = 0;   // nixfred: the connecting ring starts over next time
    if (!value && form.id[0]) { ht_form_reset(&form); view(HOME); }
    if (!value && draft.page.active) { ht_draft_reset(&draft); view(HOME); }
    if (!value && (s.voice_open || audio_client_active())) {
        audio_client_abort();
        voice_close();
        view(HOME);
    }
    change();
    display_unlock();
}
void ui_project_set_name(const char *id, const char *name)
{
    display_lock();
    int i = ensure(id);
    if (i >= 0) {
        COPY(s.agents[i].name, name);
        change();
    }
    display_unlock();
}
void ui_project_set_engine(const char *id, const char *engine)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        COPY(s.agents[i].engine, engine);
        change();
    }
    display_unlock();
}
void ui_project_set_machine(const char *id, const char *machine_id, const char *name)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        COPY(s.agents[i].machine_id, machine_id);
        COPY(s.agents[i].machine, name);
        change();
    }
    display_unlock();
}
void ui_project_fill_missing_engine(const char *engine)
{
    display_lock();
    for (int i = 0; i < s.count; i++)
        if (!s.agents[i].engine[0])
            COPY(s.agents[i].engine, engine);
    change();
    display_unlock();
}
void ui_project_set_selected_model(const char *id, const char *model)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        COPY(s.agents[i].model, model);
        change();
    }
    display_unlock();
}
void ui_project_reconcile_selected_model(const char *id, const char *model)
{
    ui_project_set_selected_model(id, model);
}
void ui_projects_bulk_begin(void)
{
    display_lock();
    s.bulk++;
    display_unlock();
}
void ui_projects_bulk_end(void)
{
    display_lock();
    if (s.bulk)
        s.bulk--;
    change();
    display_unlock();
}
void ui_project_remove(const char *id)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        if (s.active == i) {
            input_cancel();
        }
        memmove(&s.agents[i], &s.agents[i + 1], (size_t)(s.count - i - 1) * sizeof(agent_t));
        s.count--;
        if (s.active > i)
            s.active--;
        else if (s.active >= s.count)
            s.active = s.count - 1;
        change();
    }
    display_unlock();
}
void ui_project_clear_all(void)
{
    display_lock();
    input_cancel();
    s.count = 0;
    s.active = -1;
    change();
    display_unlock();
}
void ui_project_apply_order(const char *const *ids, int n)
{
    static EXT_RAM_BSS_ATTR agent_t swap;
    display_lock();
    char selected[ID_MAX] = "";
    if (active())
        COPY(selected, active()->id);
    for (int i = 0; i < n && i < s.count; i++) {
        int j = find(ids[i]);
        if (j >= 0 && j != i) {
            swap = s.agents[i];
            s.agents[i] = s.agents[j];
            s.agents[j] = swap;
        }
    }
    s.active = find(selected);
    change();
    display_unlock();
}
int ui_project_count(void)
{
    display_lock();
    int n = s.count;
    display_unlock();
    return n;
}
bool ui_project_id_at(int i, char *buf, size_t n)
{
    display_lock();
    bool ok = i >= 0 && i < s.count;
    if (ok)
        copy(buf, n, s.agents[i].id);
    display_unlock();
    return ok;
}
bool ui_project_known(const char *id)
{
    display_lock();
    bool ok = find(id) >= 0;
    display_unlock();
    return ok;
}
bool ui_project_has_event(const char *id)
{
    display_lock();
    int i = find(id);
    bool ok = i >= 0 && s.agents[i].has_event;
    display_unlock();
    return ok;
}
bool ui_project_is_busy(const char *id)
{
    display_lock();
    int i = find(id);
    bool ok = i >= 0 && s.agents[i].busy;
    display_unlock();
    return ok;
}
static void event(const char *id, const char *session, const char *kind, const char *text_,
                  const char *recap, bool restore)
{
    display_lock();
    pane_memory_t *m = pane_memory(id, true);
    if (!m) { display_unlock(); return; }
    int i = find(id);
    agent_t *a = i >= 0 ? &s.agents[i] : NULL;
    if (session && *session)
        COPY(m->session, session);
    if (kind && !strcmp(kind, "activity")) {
        // Activity is a read of the current terminal, not a new turn or a recap.
        // A late read must never reanimate an idle pane.
        if (m->busy && ms() - m->last_busy <= 25000) {
            activity_text(m->activity, sizeof m->activity, text_);
            if (a) { COPY(a->tool, m->activity); change(); }
        }
        display_unlock(); return;
    }
    if (kind && (!strcmp(kind, "processing") || !strcmp(kind, "summarizing"))) {
        if (!restore) {
            if (!m->busy) {
                m->busy_ms = ms();
                m->activity[0] = 0;
                if (a && i == s.active) s.character_activity++;
            }
            m->busy = true;
            m->awaiting_result = true;
            m->last_busy = ms();
            // Old bridges send these generic labels. Keep liveness, but do not
            // pretend they are words being displayed by the agent itself.
            if (text_ && *text_ && strcmp(text_, "Processing") &&
                strcmp(text_, "Summarizing...") && strcmp(text_, "Summarizing\xe2\x80\xa6"))
                activity_text(m->activity, sizeof m->activity, text_);
            if (a) {
                a->busy = true;
                a->recap_ready = false;
                a->busy_ms = m->busy_ms;
                a->last_busy = m->last_busy;
                COPY(a->session, m->session);
                COPY(a->tool, m->activity);
            }
        }
        if (a) change();
        display_unlock();
        return;
    }
    if (!restore) { m->busy = false; m->activity[0] = 0; }
    bool has_text = text_ && *text_ && strcmp(text_, "done");
    if ((has_text || (recap && *recap)) && !(restore && (m->live_summary || m->awaiting_result || m->busy))) {
        char preview[sizeof m->preview];
        recap_preview(preview, sizeof preview, recap && *recap ? recap : text_);
        // Retain history privately, but a new turn stays in presence mode until
        // its own live result arrives. Late history cannot resurrect an old recap.
        if (preview[0]) {
            m->awaiting_result = false;
            // An opened off-tab notification can precede its first history
            // snapshot. Fill that empty record without showing the same result
            // twice. Every new live result still becomes visible normally.
            if (!restore || (m->preview[0] && strcmp(m->preview, preview))) m->dismissed = false;
            COPY(m->preview, preview);
            COPY(m->full, has_text ? text_ : recap);
            if (!restore) m->live_summary = true;
        }
    }
    pane_memory_apply(a, m);
    // Agent events may belong to an earlier turn. Only the voice result finishes voice UI.
    if (a) change();
    display_unlock();
}
void ui_project_emit(const char *id, const char *session, const char *kind, const char *text_,
                     const char *recap)
{
    event(id, session, kind, text_, recap, false);
}
void ui_project_restore_event(const char *id, const char *kind, const char *text_,
                              const char *recap)
{
    event(id, NULL, kind, text_, recap, true);
}
void ui_project_clear_event(const char *id)
{
    display_lock();
    pane_memory_t *m = pane_memory(id, false);
    if (m) { m->preview[0] = m->full[0] = 0; m->live_summary = false; }
    int i = find(id);
    if (i >= 0) {
        s.agents[i].preview[0] = 0;
        s.agents[i].full[0] = 0;
        s.agents[i].has_event = false;
        s.agents[i].recap_ready = false;
        change();
    }
    display_unlock();
}
void ui_project_set_busy_tokens(const char *id, int tokens)
{
    display_lock();
    int i = find(id);
    if (i >= 0)
        s.agents[i].tokens = tokens;
    display_unlock();
}
void ui_project_set_tool(const char *id, const char *name, const char *title, const char *hex,
                         const char *detail)
{
    (void)hex;
    (void)detail;
    display_lock();
    int i = find(id);
    if (i >= 0) {
        char next[sizeof(s.agents[i].tool)];
        snprintf(next, sizeof(next), "%s%s%s", name ? name : "",
                 title && *title ? ": " : "", title ? title : "");
        if (i == s.active && strcmp(next, s.agents[i].tool)) s.character_activity++;
        snprintf(s.agents[i].tool, sizeof(s.agents[i].tool), "%s%s%s", name ? name : "",
                 title && *title ? ": " : "", title ? title : "");
        change();
    }
    display_unlock();
}
void ui_project_set_todos(const char *id, const cJSON *todos)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        const cJSON *t;
        cJSON_ArrayForEach(t, todos)
        {
            const cJSON *status = cJSON_GetObjectItemCaseSensitive(t, "status"),
                        *content = cJSON_GetObjectItemCaseSensitive(t, "content");
            if (cJSON_IsString(status) && !strcmp(status->valuestring, "in_progress") &&
                cJSON_IsString(content)) {
                if (i == s.active && strcmp(s.agents[i].tool, content->valuestring)) s.character_activity++;
                COPY(s.agents[i].tool, content->valuestring);
                change();
                break;
            }
        }
    }
    display_unlock();
}
void ui_project_set_agents(const char *id, const cJSON *agents)
{
    (void)id;
    (void)agents; /* Detail stays on the desktop; the face shows the current tool. */
}
int ui_prune_stale_busy(void)
{
    display_lock();
    int n = 0;
    uint32_t now = ms();
    for (int i = 0; i < s.count; i++)
        if (s.agents[i].busy && now - s.agents[i].last_busy > 25000) {
            s.agents[i].busy = false;
            pane_memory_t *m = pane_memory(s.agents[i].id, false);
            if (m) m->busy = false;
            n++;
        }
    if (n)
        change();
    display_unlock();
    return n;
}
void ui_cancel_acked(const char *session)
{
    display_lock();
    for (int i = 0; i < s.count; i++)
        if (session && !strcmp(s.agents[i].session, session)) {
            s.agents[i].busy = false;
            pane_memory_t *m = pane_memory(s.agents[i].id, false);
            if (m) m->busy = false;
            change();
        }
    display_unlock();
}
void ui_fleet_set(int total, bool window)
{
    display_lock();
    s.total = total;
    s.window = window;
    change();
    display_unlock();
}
void ui_focus_project(const char *id)
{
    if (!id || !*id || strnlen(id, ID_MAX) >= ID_MAX) return;
    display_lock();
    int i = find(id);
    if (i < 0) {
        COPY(s.pending_focus, id);
        display_unlock();
        return;
    }
    bool requested = s.pending_focus[0] && !strcmp(s.pending_focus, id);
    s.pending_focus[0] = 0;
    bool opened = s.opening_notice[0] && !strcmp(s.opening_notice, id);
    if (opened) s.opening_notice[0] = 0;
    if (s.active != i) {
        input_cancel();
    }
    s.active = i;
    // Focus changes the main surface's recipient. Voice and confirmations keep their pinned targets.
    // A requested remote open lands only after the host has supplied that agent.
    if (opened && s.view == INBOX) view(HOME);
    else if (requested && s.view == MESSAGE && !visit.pending) {
        if (visit.available && !strcmp(visit.agent,id) && is_question(id)) open_question();
        else view(AGENT);
    }
    if (visit.available && !visit.pending && strcmp(visit.agent, id)) ht_visit_close(&visit);
    change();
    display_unlock();
}
void ui_apply_pending_focus(void)
{
    display_lock();
    char id[ID_MAX];
    COPY(id, s.pending_focus);
    display_unlock();
    if (id[0] && ui_project_known(id))
        ui_focus_project(id);
}
void ui_show_projects(void)
{
    display_lock();
    view(HOME);
    display_unlock();
}
void ui_enter_boot_loading(void)
{
    display_lock();
    s.loading = true;
    view(HOME);
    display_unlock();
}
void ui_land_after_reload(void)
{
    display_lock();
    if (s.loading && (workspace.phase==HT_WORKSPACE_IDLE || workspace.phase==HT_WORKSPACE_READY)) {
        ht_workspace_cancel_request(&workspace);
        s.loading = false;
        view(HOME);
    }
    change();
    display_unlock();
}
void ui_workspace_applied(const char *tab, uint32_t generation)
{
    display_lock();
    if (!strcmp(s.selected_tab,workspace.pending)) ht_workspace_applied(&workspace,tab,generation);
    display_unlock();
}
void ui_report_active_agent(void)
{
    display_lock();
    action_t a = {.kind = A_AGENT};
    if (active())
        COPY(a.id, active()->id);
    if (a.id[0])
        queue(a);
    display_unlock();
}
int ui_get_active_project_index(void)
{
    display_lock();
    int i = s.view == HOME || s.view == AGENT || s.view == READER || s.view == QUESTION ? s.active : -1;
    display_unlock();
    return i;
}
const char *ui_get_active_project_id(void) { return active() ? active()->id : NULL; }
const char *ui_get_active_session_id(void) { return active() ? active()->session : NULL; }
bool ui_is_projects_active(void)
{
    return s.view == HOME || s.view == AGENT || s.view == AGENTS;
}
bool ui_reader_is_open(void) { return s.view == READER; }
bool ui_picker_is_open(void) { return s.view == MODELS || s.view == MACHINES || s.view == TABS; }
bool ui_switch_is_open(void) { return s.view == TABS; }
bool ui_scroll_reportable(void)
{
    return s.ready && s.connected && !s.loading && (s.view == HOME || s.view == AGENT) && active() &&
           !display_is_asleep() && !s.voice_open && !audio_client_active();
}
int ui_notif_pull_zone_px(void) { return 0; }
bool ui_action_hit(uint16_t x, uint16_t y)
{
    (void)x;
    (void)y;
    return true;
}
void ui_swipe_begin(void) {}
void ui_swipe_end(int dir)
{
    display_lock();
    if (s.count) {
        s.active = (s.active + (dir > 0 ? 1 : s.count - 1)) % s.count;
        view(AGENT);
    }
    display_unlock();
}
void ui_home_overview(void)
{
    display_lock();
    view(HOME);
    display_unlock();
}
void ui_tap(int32_t x, int32_t y)
{
    display_lock();
    habitat_touch(true, x, y, ms());
    habitat_touch(false, x, y, ms());
    display_unlock();
}
void ui_notif_open(void)
{
    display_lock();
    notice_open();
    display_unlock();
}
void ui_notif_close(void)
{
    display_lock();
    if (s.view == INBOX)
        view(HOME);
    display_unlock();
}
bool ui_notif_is_open(void) { return s.view == INBOX; }
bool ui_notif_pill_hit(uint16_t x, uint16_t y)
{
    (void)x;
    (void)y;
    return false;
}
void ui_notif_swipe_up(void) { ui_notif_close(); }
static void notice_remove(const char *id, bool questions_too)
{
    if (!id) return;
    for (int i = s.notice_count - 1; i >= 0; i--)
        if (!strcmp(s.notice[i].agent_id, id) && (questions_too || !s.notice[i].question)) {
            memmove(&s.notice[i], &s.notice[i + 1],
                    (size_t)(s.notice_count - i - 1) * sizeof(cable_notif_t));
            s.notice_count--;
            if (s.view == INBOX && i < s.offset) s.offset--;
        }
}
static void notice_sync_view(void)
{
    if (s.view != INBOX) return;
    // Reconcile after the complete mutation, never during remove-then-add.
    // Cancel a finger already down so the new home cannot receive its release.
    input_cancel();
    if (!s.notice_count) view(HOME);
    else if (s.offset >= s.notice_count) s.offset = s.notice_count - 1;
}
static void notice_selection(char *id, size_t capacity)
{
    copy(id, capacity, s.view == INBOX && s.offset >= 0 && s.offset < s.notice_count
        ? s.notice[s.offset].agent_id : "");
}
static void notice_restore_selection(const char *id)
{
    if (s.view != INBOX || !id[0]) return;
    for (int i = 0; i < s.notice_count; i++)
        if (!strcmp(id, s.notice[i].agent_id)) { s.offset = i; return; }
}
static void notice_add(const char *id, const char *name, const char *machine, const char *recap,
                       bool question, bool failed)
{
    if (!id || !*id || strnlen(id, ID_MAX) >= ID_MAX) return;
    char selected[ID_MAX]; notice_selection(selected, sizeof selected);
    notice_remove(id, true);
    if (s.notice_count == NOTICES) {
        // Keep a message being read even when the bounded inbox fills. The
        // oldest other message gives way; arrival never moves the current card.
        int drop = s.notice_count - 1;
        if (!strcmp(selected, s.notice[drop].agent_id)) drop--;
        memmove(&s.notice[drop], &s.notice[drop + 1],
                (size_t)(s.notice_count - drop - 1) * sizeof(cable_notif_t));
        s.notice_count--;
    }
    int pos = 0;
    if (!question)
        while (pos < s.notice_count && s.notice[pos].question)
            pos++;
    memmove(&s.notice[pos + 1], &s.notice[pos],
            (size_t)(s.notice_count - pos) * sizeof(cable_notif_t));
    s.notice_count++;
    cable_notif_t *n = &s.notice[pos];
    memset(n, 0, sizeof(*n));
    COPY(n->agent_id, id);
    COPY(n->name, name && *name ? name : "Harness");
    COPY(n->machine, machine);
    recap_preview(n->summary, sizeof n->summary, recap);
    n->question = question;
    n->failed = failed;
    n->read_on_dial = notice_was_read(n);
    if (!++s.notice_revision) ++s.notice_revision;
    n->display_revision = s.notice_revision;
    notice_restore_selection(selected);
    notice_sync_view();
}
void ui_notify_task_done(const char *id, const char *name, const char *machine, const char *recap)
{
    if (!id || !*id || strnlen(id, ID_MAX) >= ID_MAX) return;
    display_lock();
    notice_forget_read(id); // A fresh completion is new even if its words repeat.
    notice_add(id, name, machine, recap, false, false);
    s.notice_sequence++;
    uint32_t now = ms();
    { int i = find(id); if (i >= 0) s.agents[i].failed_at = 0; }
    if (!s.quiet && !s.nap) { s.nf_done_at = now | 1; COPY(s.nf_done_agent, id); }
    {   // nixfred slice 3: another agent's finished turn slides up as a card (the active one has the done motion)
        agent_t *shown = active();
        if (!s.quiet && !s.nap && (!shown || strcmp(shown->id, id))) {
            s.nf_card_at = now | 1; s.nf_card_gone = 0;
            COPY(s.nf_card_id, id);
            COPY(s.nf_card_name, name && *name ? name : "Harness");
            recap_preview(s.nf_card_text, sizeof s.nf_card_text, recap);
        }
    }
    if (!waiting() && !s.nap && !s.quiet && (!s.last_celebration || now - s.last_celebration >= 20000)) {
        s.pet_pose = 3;
        s.pet_until = now + 2000;
        s.last_celebration = now;
    }
    change();
    display_wake();
    display_unlock();
}
void ui_notif_seen(const char *id)
{
    display_lock();
    bool opened = id && s.opening_notice[0] && !strcmp(s.opening_notice, id);
    for (int i = 0; id && i < s.notice_count; i++)
        if (!strcmp(s.notice[i].agent_id, id)) notice_mark_read(&s.notice[i]);
    notice_remove(id, false);
    notice_sync_view();
    change();
    display_unlock();
    // An already-focused desktop pane may only echo "seen", with no focus
    // change. That acknowledgement also completes the requested inbox open.
    if (opened) ui_focus_project(id);
}
void ui_notif_read(const char *id, const char *token)
{
    if (!id || !token || !token[0]) return;
    display_lock();
    for (int i = 0; i < NOTICES; i++)
        if (!strcmp(s.notice_reads[i].id, id) && !strcmp(s.notice_reads[i].token, token))
            s.notice_reads[i].pending = false;
    bool opened = false;
    for (int i = 0; i < s.notice_count; i++) {
        cable_notif_t *n = &s.notice[i];
        if (strcmp(n->agent_id, id) || strcmp(n->read_token, token)) continue;
        n->read_on_dial = true;
        opened = !strcmp(s.opening_notice, id);
        if (s.view != INBOX || i != s.offset || opened) {
            notice_remove(id, true); notice_sync_view();
        }
        change(); break;
    }
    display_unlock();
    if (opened) ui_focus_project(id);
}
void ui_notif_replace(const cable_notif_t *rows, int count)
{
    display_lock();
    char selected[ID_MAX]; notice_selection(selected, sizeof selected);
    cable_notif_t held = {0};
    if (selected[0] && s.notice[s.offset].read_on_dial && s.notice[s.offset].read_token[0])
        held = s.notice[s.offset];
    if (!rows || count < 0) count = 0;
    if (count > NOTICES) count = NOTICES;
    s.notice_count = 0;
    for (int i = count - 1; i >= 0; i--) {
        notice_add(rows[i].agent_id, rows[i].name, rows[i].machine, rows[i].summary,
                   rows[i].question, rows[i].failed);
        for (int j = 0; j < s.notice_count; j++) if (!strcmp(s.notice[j].agent_id, rows[i].agent_id)) {
            COPY(s.notice[j].read_token, rows[i].read_token);
            s.notice[j].read_on_dial = notice_was_read(&s.notice[j]);
            break;
        }
    }
    // An authoritative absence acknowledges the read. It must not make the
    // card disappear while the person is still reading it.
    for (int i = 0; i < NOTICES; i++) if (s.notice_reads[i].pending) {
        bool present = false;
        for (int j = 0; j < count; j++)
            if (!strcmp(rows[j].agent_id, s.notice_reads[i].id) &&
                !strcmp(rows[j].read_token, s.notice_reads[i].token)) present = true;
        if (!present) s.notice_reads[i].pending = false;
    }
    bool retained = false;
    for (int i = 0; i < s.notice_count; i++) if (!strcmp(s.notice[i].agent_id, selected)) retained = true;
    if (held.agent_id[0] && !retained && s.notice_count < NOTICES) {
        s.notice[s.notice_count++] = held;
    }
    notice_restore_selection(selected);
    notice_sync_view();
    change();
    display_unlock();
}
static void question_load(const cJSON *questions)
{
    s.q.count=s.q.index=s.q.choice=0; s.q.supported=true; s.q.valid=false; s.q.permission=false;
    memset(s.q.item,0,sizeof s.q.item);
    const cJSON *item;
    cJSON_ArrayForEach(item,questions) {
        if (s.q.count==QUESTION_MAX) { s.q.supported=false; break; }
        question_item_t *q=&s.q.item[s.q.count++];
        const cJSON *key=cJSON_GetObjectItemCaseSensitive(item,"key"),
            *prompt=cJSON_GetObjectItemCaseSensitive(item,"q"),
            *options=cJSON_GetObjectItemCaseSensitive(item,"options");
        COPY(q->key,cJSON_IsString(key) ? key->valuestring : "");
        COPY(q->prompt,cJSON_IsString(prompt) ? prompt->valuestring : "");
        q->multi=cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(item,"multi"));
        q->can_text=!q->multi && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(item,"canText"));
        if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(item,"permission"))) s.q.permission=true;
        if (!cJSON_IsString(key) || !q->key[0] || strlen(key->valuestring)>=sizeof q->key ||
            !cJSON_IsString(prompt) || !q->prompt[0] || strlen(prompt->valuestring)>=sizeof q->prompt ||
            !ht_can_display(q->prompt,UI_FONT,348,256)) s.q.supported=false;
        const cJSON *option;
        cJSON_ArrayForEach(option,options) {
            if (q->count==OPTION_MAX) { s.q.supported=false; break; }
            if (!cJSON_IsString(option) || !option->valuestring[0]) { s.q.supported=false; continue; }
            if (strlen(option->valuestring)>=sizeof q->options[0] ||
                !ht_can_display(option->valuestring,UI_FONT,348,256)) s.q.supported=false;
            COPY(q->options[q->count++],option->valuestring);
        }
        if (!q->count) s.q.supported=false;
    }
    s.q.valid=s.q.count>0;
}
void ui_question_show(const char *id, const char *name, const char *machine, const char *request,
                      const cJSON *questions)
{
    if (!id || !request) return;
    display_lock();
    const cJSON *first=cJSON_GetArrayItem(questions,0);
    const cJSON *prompt=cJSON_GetObjectItemCaseSensitive(first,"q");
    notice_forget_read(id);
    notice_add(id,name,machine,cJSON_IsString(prompt) ? prompt->valuestring : "Needs your answer",true,false);
    s.notice_sequence++;
    // A different agent's alert cannot replace the question being read.
    if (s.q.valid && !strcmp(s.q.agent,id) && strcmp(s.q.request,request)) {
        s.q.valid=false; s.q.pending=false; s.q.revision++;
        if (question_view(s.view)) { COPY(s.q.error,"The question changed. Open the alert again."); view(QUESTION); }
    }
    // The question is shown on the home face, in the recap's place (render_home): no screen opens
    // for it. The display wakes so a person glancing over sees it.
    change();
    display_wake();
    display_unlock();
}
void ui_question_state(const cJSON *p)
{
    const cJSON *agent=cJSON_GetObjectItemCaseSensitive(p,"agentId"),
        *fetch=cJSON_GetObjectItemCaseSensitive(p,"requestId"),
        *id=cJSON_GetObjectItemCaseSensitive(p,"id"),
        *token=cJSON_GetObjectItemCaseSensitive(p,"token"),
        *name=cJSON_GetObjectItemCaseSensitive(p,"name"),
        *error=cJSON_GetObjectItemCaseSensitive(p,"error");
    if (!cJSON_IsString(agent) || !cJSON_IsString(fetch)) return;
    display_lock();
    if (s.q.loading && s.view==QUESTION && !strcmp(agent->valuestring,s.q.agent) && !strcmp(fetch->valuestring,s.q.fetch)) {
        s.q.loading=false;
        if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"ok")) && cJSON_IsString(id) &&
            strlen(id->valuestring)<sizeof s.q.request && cJSON_IsString(token) && token->valuestring[0] &&
            strlen(token->valuestring)<sizeof s.q.token) {
            COPY(s.q.request,id->valuestring); COPY(s.q.token,token->valuestring);
            if (cJSON_IsString(name)) COPY(s.q.name,name->valuestring);
            question_load(cJSON_GetObjectItemCaseSensitive(p,"questions"));
            if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"submitted"))) {
                s.q.pending=s.q.uncertain=true;
                COPY(s.q.error,"An answer was already sent. Check the terminal.");
            }
        } else COPY(s.q.error,cJSON_IsString(error) ? error->valuestring : "Could not load the question.");
        input_cancel(); change();
    }
    display_unlock();
}
void ui_answer_receipt(const cJSON *p)
{
    const cJSON *agent=cJSON_GetObjectItemCaseSensitive(p,"agentId"),
        *fetch=cJSON_GetObjectItemCaseSensitive(p,"requestId"),
        *token=cJSON_GetObjectItemCaseSensitive(p,"token"),
        *error=cJSON_GetObjectItemCaseSensitive(p,"error");
    if (!cJSON_IsString(agent) || !cJSON_IsString(fetch) || !cJSON_IsString(token)) return;
    display_lock();
    if (s.q.pending && !strcmp(s.q.agent,agent->valuestring) && !strcmp(s.q.fetch,fetch->valuestring) &&
        !strcmp(s.q.token,token->valuestring)) {
        if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"ok"))) {
            if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"pending"))) { display_unlock(); return; }
            s.q.valid=s.q.pending=false; s.q.revision++; notice_remove(s.q.agent,true);
            if (question_view(s.view)) view(HOME);
            notice_sync_view();
        } else {
            s.q.uncertain=true;
            COPY(s.q.error,cJSON_IsString(error) ? error->valuestring : "Could not confirm. Check the terminal.");
            change();
        }
    }
    display_unlock();
}
void ui_question_close(const char *id, const char *request)
{
    if (!id || !request) return;
    display_lock();
    if (!strcmp(s.q.agent,id) && !strcmp(s.q.request,request)) {
        s.q.valid=s.q.pending=s.q.loading=false; s.q.revision++;
        if (question_view(s.view)) view(HOME);
        notice_remove(id,true);
    } else if (strcmp(s.q.agent,id)) notice_remove(id,true);
    notice_sync_view();
    change(); display_unlock();
}

void ui_service_model_picker(void)
{
    char id[ID_MAX], selected[192];
    display_lock();
    bool request = s.model_request;
    s.model_request = false;
    COPY(id, s.model_agent);
    COPY(selected, s.model_selected);
    display_unlock();
    if (!request)
        return;
    static EXT_RAM_BSS_ATTR model_item_t results[48];
    int n = cable_client_models_list(id, "model", selected, results, 48);
    display_lock();
    if (s.view == MODELS && !strcmp(id, s.model_agent)) {
        s.model_count = n < 0 ? 0 : n;
        memcpy(s.models, results, (size_t)s.model_count * sizeof(model_item_t));
        change();
    }
    display_unlock();
}
void ui_swarms_replace(const cable_swarm_t *rows, int count, const char *selected)
{
    display_lock();
    int bounded=count<0 ? 0 : count>SWARMS_MAX ? SWARMS_MAX : count;
    if (!rows) bounded=0;
    char focused[ID_MAX] = "";
    int focused_index = ht_tab_carousel_index(&tab_carousel);
    if (s.view == TABS && focused_index >= 0 && focused_index < s.tab_count) COPY(focused, s.tabs[focused_index].id);
    bool changed=bounded!=s.tab_count || strcmp(s.selected_tab,selected ? selected : "");
    for (int i=0;!changed && i<bounded;i++) {
        changed=strcmp(rows[i].id,s.tabs[i].id) || strcmp(rows[i].name,s.tabs[i].name);
    }
    if (changed && (workspace.touching || s.view == TABS)) input_cancel();
    s.tab_count=bounded;
    if (bounded) memcpy(s.tabs,rows,(size_t)bounded*sizeof *rows);
    COPY(s.selected_tab,selected);
    if (changed && s.view == TABS) {
        int index = workspace_index(focused);
        ht_tab_carousel_reset(&tab_carousel, bounded, index >= 0 ? index : workspace_index(s.selected_tab));
    }
    if (workspace.phase!=HT_WORKSPACE_IDLE && workspace_index(workspace.pending)<0) {
        workspace_failed("That workspace is gone. Choose another.");
    } else if (ht_workspace_selected(&workspace,s.selected_tab)) {
        // Even identical/empty tabs need a fresh roster to acknowledge landing.
        // A narrow refresh forces that snapshot without replaying other state.
        if (!queue((action_t){.kind=A_TAB_REFRESH,.revision=workspace.serial}))
            workspace_failed("Device busy. Choose the tab again.");
    }
    change(); display_unlock();
}
void ui_show_machines(void)
{
    display_lock();
    view(MACHINES);
    display_unlock();
}
void ui_machines_replace(const cable_machine_t *rows, int count, const char *selected,
                         const char *previous)
{
    (void)previous;
    display_lock();
    s.machine_count = !rows || count < 0 ? 0 : count > CABLE_MAX_MACHINES ? CABLE_MAX_MACHINES : count;
    if (s.machine_count > 0)
        memcpy(s.machines, rows, (size_t)s.machine_count * sizeof(*rows));
    COPY(s.selected_machine, selected);
    change();
    display_unlock();
}
void ui_machines_replace_one(const cable_machine_t *row, const char *selected)
{
    if (!row) return;
    display_lock();
    for (int i = 0; i < s.machine_count; i++)
        if (!strcmp(s.machines[i].id, row->id)) {
            s.machines[i] = *row;
            break;
        }
    COPY(s.selected_machine, selected);
    change();
    display_unlock();
}
void ui_machines_source(const char *source) { (void)source; }
void ui_machines_clear(void)
{
    display_lock();
    s.machine_count = 0;
    change();
    display_unlock();
}
void ui_set_selected_machine(const char *id)
{
    display_lock();
    COPY(s.selected_machine, id);
    change();
    display_unlock();
}
void ui_machine_selected_ack(const char *id)
{
    if (!id || !*id || strlen(id) >= sizeof s.selected_machine) return;
    display_lock();
    COPY(s.selected_machine, id);
    // The host owns actual selection. Its older acknowledgement must not
    // consume a more recent request that is still waiting for its own reply.
    if (!strcmp(s.pending_machine, id)) s.pending_machine[0] = 0;
    change();
    display_unlock();
}
void ui_machine_select_error(const char *id, const char *code, const char *message)
{
    (void)code;
    display_lock();
    if (!id || !s.pending_machine[0] || strcmp(s.pending_machine, id)) {
        display_unlock();
        return;
    }
    s.pending_machine[0] = 0;
    show_failure("Machine", message);
    display_unlock();
}
void ui_tick_machine_select(void)
{
    display_lock();
    if (s.pending_machine[0] && (int32_t)(ms() - s.machine_deadline) >= 0) {
        s.pending_machine[0] = 0;
        COPY(s.title, "No response");
        COPY(s.message, "The machine did not answer. Please try again.");
        view(MESSAGE);
    }
    display_unlock();
}
void ui_machines_refresh(void)
{
    display_lock();
    change();
    display_unlock();
}
bool ui_selected_machine_is_local(void)
{
    return !s.selected_machine[0] || !strcmp(s.selected_machine, cable_client_machine_id());
}
void ui_set_reload_waiter(TaskHandle_t task) { atomic_store(&reload_waiter, task); }
void ui_request_agent_reload(void)
{
    atomic_store(&reload_requested, true);
    TaskHandle_t waiter = atomic_load(&reload_waiter);
    if (waiter)
        xTaskNotifyGive(waiter);
}
bool ui_take_agent_reload_req(void) { return atomic_exchange(&reload_requested, false); }
bool ui_peek_agent_reload_req(void) { return atomic_load(&reload_requested); }
bool ui_scroll_is_reversed(void) { return scroll_reversed; }
bool ui_take_portal_req(void) { return false; }
bool ui_take_wifi_retry_req(void) { return false; }
void ui_set_creating(bool on)
{
    display_lock();
    if (on) {
        COPY(s.title, "A new thought");
        COPY(s.message, "Finding its home...");
        view(MESSAGE);
    }
    change();
    display_unlock();
}
void ui_show_error(const char *title, const char *detail)
{
    display_lock();
    COPY(s.title, title);
    COPY(s.message, detail);
    view(MESSAGE);   // pairing codes and notes come through here too; view() clears the failure mark
    display_unlock();
}
// nixfred: a turn ended in turn.error. Its rim arc flashes twice and holds thin red until it works again.
void ui_nixfred_turn_failed(const char *id, const char *message)
{
    display_lock();
    int i = find(id);
    if (i >= 0) {
        s.agents[i].failed_at = ms() | 1;
        s.nf_fail_at = s.agents[i].failed_at;
        change();
    }
    // The words the toast used to carry, on the failure screen. A live recording keeps its screen.
    if (!s.voice_open && message && *message) show_failure(i >= 0 ? s.agents[i].name : "Harness", message);
    display_unlock();
}
// nixfred: the daemon stopped every agent (`harness stop-all`). Every ring closes to one red dot.
void ui_nixfred_panic(int stopped)
{
    display_lock();
    s.nf_msg_kind = 2;
    s.nf_stopped = stopped;
    s.nf_msg_at = ms() | 1;
    s.title[0] = s.message[0] = 0;
    nf_msg_keep = true; view(MESSAGE); nf_msg_keep = false;
    change();
    display_wake();
    display_unlock();
}
// nixfred: the plans' weekly use, as the daemon's `nixfred.subs` frame carries it.
void ui_nixfred_plan_detail(const char (*name)[10], const int16_t *banked, int pick, int n)
{
    display_lock();
    if (n > NIXFRED_PLANS_MAX) n = NIXFRED_PLANS_MAX;
    for (int i = 0; i < n; i++) { memcpy(s.nf_plan_name[i], name[i], 10); s.nf_plan_name[i][9] = 0; s.nf_plan_banked[i] = banked[i]; }
    s.nf_plan_pick = pick >= 0 && pick < n ? pick + 1 : 0;   // stored +1: zero-initialised means none
    change();
    display_unlock();
}
// nixfred: `nixfred.fleet`. A new collision alert opens its card on the home face.
void ui_nixfred_fleet(const ui_nf_fleet_t *fleet)
{
    display_lock();
    s.nf_fleet = *fleet;
    if (fleet->clock_s >= 0) { s.nf_clock_s = fleet->clock_s; s.nf_clock_at = ms() | 1; }
    if (fleet->alert && fleet->alert_at != s.nf_alert_seen) {
        s.nf_alert_seen = fleet->alert_at;
        if (s.view == HOME && !s.voice_open && s.connected && !s.loading) {
            s.nf_msg_kind = 4;
            s.nf_msg_at = ms() | 1;
            s.title[0] = s.message[0] = 0;
            nf_msg_keep = true; view(MESSAGE); nf_msg_keep = false;
            display_wake();
        }
    }
    change();
    display_unlock();
}
void ui_nixfred_plans(const uint16_t *used_permille, const uint8_t *tone, int n)
{
    display_lock();
    if (n > NIXFRED_PLANS_MAX) n = NIXFRED_PLANS_MAX;
    if (n < 0) n = 0;
    for (int i = 0; i < n; i++) { s.nf_plan_used[i] = used_permille[i]; s.nf_plan_tone[i] = tone[i]; }
    s.nf_plan_count = n;
    change();
    display_unlock();
}
void ui_carry_state(const cJSON *p)
{
    const cJSON *request=cJSON_GetObjectItemCaseSensitive(p,"requestId"),
        *id=cJSON_GetObjectItemCaseSensitive(p,"carryId"),
        *source=cJSON_GetObjectItemCaseSensitive(p,"sourceName"),
        *excerpt=cJSON_GetObjectItemCaseSensitive(p,"excerpt"),
        *rows=cJSON_GetObjectItemCaseSensitive(p,"rows"),
        *ttl=cJSON_GetObjectItemCaseSensitive(p,"ttlMs"),
        *error=cJSON_GetObjectItemCaseSensitive(p,"error");
    if (!cJSON_IsString(request) || strncmp(request->valuestring,"carry-",6) || !cJSON_IsString(id)) return;
    char *end=NULL; unsigned long serial=strtoul(request->valuestring+6,&end,10);
    if (!serial || !end || *end || serial>UINT32_MAX) return;
    bool ok=cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"ok"));
    if (ok && (!cJSON_IsString(source) || !cJSON_IsString(excerpt) ||
        !cJSON_IsNumber(rows) || rows->valuedouble!=rows->valueint ||
        !cJSON_IsNumber(ttl) || ttl->valuedouble!=ttl->valueint || ttl->valueint<1)) return;
    display_lock();
    if (ht_carry_reply(&carry,id->valuestring,(uint32_t)serial,ok,
            cJSON_IsString(source)?source->valuestring:NULL,
            cJSON_IsString(excerpt)?excerpt->valuestring:NULL,
            cJSON_IsNumber(rows)?rows->valueint:0,cJSON_IsNumber(ttl)?(uint32_t)ttl->valueint:0,
            cJSON_IsString(error)?error->valuestring:NULL,ms())) {
        if (carry.active && s.view==SELECTION) {
            ht_selection_close(&selection);
            dispatch((action_t){.kind=A_FIND});
        } else if (s.view==SELECTION) COPY(selection.error,carry.error);
        ht_gesture_guard(&gesture,ms()); change();
    }
    display_unlock();
}
static bool selection_search_fields(const cJSON *p, const char **query, int *match, int *matches)
{
    const cJSON *q = cJSON_GetObjectItemCaseSensitive(p,"query"),
        *m = cJSON_GetObjectItemCaseSensitive(p,"match"), *n = cJSON_GetObjectItemCaseSensitive(p,"matches");
    *query = NULL; *match = *matches = 0;
    if (!q) return !m && !n;
    if (!cJSON_IsString(q) || !q->valuestring[0] || strlen(q->valuestring) > 120 ||
        !cJSON_IsNumber(m) || !cJSON_IsNumber(n) || m->valuedouble != m->valueint ||
        n->valuedouble != n->valueint || m->valueint < 0 || n->valueint < 0 || m->valueint > n->valueint) return false;
    *query = q->valuestring; *match = m->valueint; *matches = n->valueint; return true;
}
void ui_voice_search(const cJSON *p)
{
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(p,"selectionId"),
        *agent = cJSON_GetObjectItemCaseSensitive(p,"agentId"),
        *revision = cJSON_GetObjectItemCaseSensitive(p,"revision"),
        *excerpt = cJSON_GetObjectItemCaseSensitive(p,"excerpt"),
        *rows = cJSON_GetObjectItemCaseSensitive(p,"rows");
    const char *query; int match, matches;
    if (!cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p,"ok")) || !cJSON_IsString(id) || !cJSON_IsString(agent) ||
        !cJSON_IsNumber(revision) || revision->valueint < 1 || revision->valuedouble != revision->valueint ||
        !cJSON_IsNumber(rows) || rows->valuedouble != rows->valueint || !cJSON_IsString(excerpt) ||
        !selection_search_fields(p,&query,&match,&matches) || !query) return;
    display_lock();
    if (s.voice_open && s.voice_waiting && s.voice_search && s.voice_return == SELECTION &&
        ht_selection_found(&selection,id->valuestring,agent->valuestring,(uint32_t)revision->valueint,
            excerpt->valuestring,rows->valueint,query,match,matches)) {
        voice_close(); view(SELECTION); ht_gesture_guard(&gesture,ms());
    }
    display_unlock();
}
void ui_selection_state(const cJSON *p)
{
    const cJSON *request = cJSON_GetObjectItemCaseSensitive(p, "requestId");
    if (!cJSON_IsString(request) || strncmp(request->valuestring, "pick-", 5)) return;
    char *end = NULL;
    unsigned long serial = strtoul(request->valuestring + 5, &end, 10);
    if (!serial || !end || *end || serial > UINT32_MAX) return;
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(p, "selectionId"),
        *revision = cJSON_GetObjectItemCaseSensitive(p, "revision"),
        *excerpt = cJSON_GetObjectItemCaseSensitive(p, "excerpt"),
        *rows = cJSON_GetObjectItemCaseSensitive(p, "rows"),
        *error = cJSON_GetObjectItemCaseSensitive(p, "error");
    bool ok = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok"));
    if (ok && (!cJSON_IsNumber(revision) || revision->valueint < 1 ||
        revision->valuedouble != revision->valueint || !cJSON_IsNumber(rows) ||
        rows->valuedouble != rows->valueint || !cJSON_IsString(id) || !cJSON_IsString(excerpt))) return;
    const char *query; int match, matches;
    if (ok && !selection_search_fields(p,&query,&match,&matches)) return;
    if (!ok) { query = NULL; match = matches = 0; }
    display_lock();
    if (ht_selection_reply_search(&selection, (uint32_t)serial, cJSON_IsString(id) ? id->valuestring : NULL, ok,
        cJSON_IsNumber(revision) ? (uint32_t)revision->valueint : 0,
        cJSON_IsString(excerpt) ? excerpt->valuestring : "", cJSON_IsNumber(rows) ? rows->valueint : 0,
        cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "extending")),
        cJSON_IsString(error) ? error->valuestring : NULL, query, match, matches, ms())) change();
    display_unlock();
}

static bool form_page(const cJSON *p, ht_form_page_t *page)
{
#define FORM_TEXT(field) do { const cJSON *v = cJSON_GetObjectItemCaseSensitive(p, #field); \
    if (cJSON_IsString(v)) COPY(page->field, v->valuestring); } while (0)
    FORM_TEXT(title); FORM_TEXT(label); FORM_TEXT(detail); FORM_TEXT(previous); FORM_TEXT(next);
    FORM_TEXT(error); FORM_TEXT(status); FORM_TEXT(action); FORM_TEXT(query);
#undef FORM_TEXT
    page->active = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "active"));
    page->busy = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "busy"));
    page->enabled = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "enabled"));
    const cJSON *revision = cJSON_GetObjectItemCaseSensitive(p, "revision"),
                *position = cJSON_GetObjectItemCaseSensitive(p, "position"),
                *total = cJSON_GetObjectItemCaseSensitive(p, "total");
    if (page->active && (!cJSON_IsNumber(revision) || revision->valuedouble < 0 || revision->valuedouble > INT32_MAX ||
        !cJSON_IsNumber(position) || position->valuedouble < 0 || position->valuedouble > INT32_MAX ||
        !cJSON_IsNumber(total) || total->valuedouble < 0 || total->valuedouble > INT32_MAX)) return false;
    page->revision = cJSON_IsNumber(revision) ? (uint32_t)revision->valueint : 0;
    page->position = cJSON_IsNumber(position) ? position->valueint : 0;
    page->total = cJSON_IsNumber(total) ? total->valueint : 0;
    page->can_query = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "canQuery"));
    return true;
}
static bool draft_page(const cJSON *p, ht_draft_page_t *page)
{
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(p, "id"),
        *revision = cJSON_GetObjectItemCaseSensitive(p, "revision"),
        *position = cJSON_GetObjectItemCaseSensitive(p, "position"),
        *total = cJSON_GetObjectItemCaseSensitive(p, "total"),
        *text_ = cJSON_GetObjectItemCaseSensitive(p, "text"),
        *agent = cJSON_GetObjectItemCaseSensitive(p, "agentId");
    if (!cJSON_IsString(id) || !id->valuestring[0] || strlen(id->valuestring) >= sizeof page->id ||
        !cJSON_IsNumber(revision) || revision->valuedouble < 1 || revision->valuedouble > INT32_MAX ||
        revision->valuedouble != revision->valueint) return false;
    COPY(page->id, id->valuestring); page->revision = (uint32_t)revision->valueint;
    page->active = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "active"));
    const cJSON *error = cJSON_GetObjectItemCaseSensitive(p, "error");
    if (cJSON_IsString(error)) COPY(page->error, error->valuestring);
    if (!page->active) return true;
    if (!cJSON_IsNumber(position) || !cJSON_IsNumber(total) ||
        position->valuedouble != position->valueint || total->valuedouble != total->valueint ||
        position->valueint < 1 || position->valueint > total->valueint || total->valueint > 128 ||
        !cJSON_IsString(text_) || !text_->valuestring[0] || strlen(text_->valuestring) > 480 ||
        !cJSON_IsString(agent) || !agent->valuestring[0] || strlen(agent->valuestring) >= sizeof page->agent) return false;
    COPY(page->text, text_->valuestring); COPY(page->agent, agent->valuestring);
    const cJSON *name = cJSON_GetObjectItemCaseSensitive(p, "name"),
        *context = cJSON_GetObjectItemCaseSensitive(p, "context");
    COPY(page->name, cJSON_IsString(name) ? name->valuestring : "Harness");
    if (cJSON_IsString(context)) COPY(page->context, context->valuestring);
    page->position = position->valueint; page->total = total->valueint;
    page->can_undo = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "canUndo"));
    page->locked = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "locked"));
    page->can_send = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "canSend")) &&
        ht_can_display(page->text, UI_FONT, 348, 512);
    return true;
}
void ui_voice_draft(const cJSON *p)
{
    ht_draft_page_t page = {0};
    if (!draft_page(p, &page) || !page.active || !cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok"))) return;
    display_lock();
    if (!s.voice_open || !s.voice_waiting || !s.voice_review ||
        (s.voice_return == DRAFT && (!draft.page.active || strcmp(page.id, draft.page.id) ||
            draft.page.revision != s.voice_draft_revision || page.revision <= s.voice_draft_revision))) {
        display_unlock(); return;
    }
    voice_close(); ht_draft_open(&draft, &page, draft_emit, NULL);
    view(DRAFT); ht_gesture_guard(&gesture, ms());
    display_unlock();
}
void ui_draft_state(const cJSON *p)
{
    const cJSON *request = cJSON_GetObjectItemCaseSensitive(p, "requestId");
    if (!cJSON_IsString(request) || strncmp(request->valuestring, "draft-", 6)) return;
    char *end = NULL; unsigned long serial = strtoul(request->valuestring+6, &end, 10);
    if (!serial || !end || *end || serial > UINT32_MAX) return;
    ht_draft_page_t page = {0};
    if (!draft_page(p, &page)) return;
    bool ok = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok"));
    display_lock();
    ht_draft_op_t op = draft.op; int direction = draft.delta;
    if (ht_draft_reply(&draft, page.id, (uint32_t)serial, ok, &page)) {
        if (!draft.page.active) {
            const cJSON *carried = cJSON_GetObjectItemCaseSensitive(p, "carryId");
            if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "sent")) &&
                cJSON_IsString(carried) && !strcmp(carried->valuestring, carry.id)) ht_carry_close(&carry);
            if (!ok) { COPY(s.title, "Draft"); copy(s.message, sizeof page.error, page.error); view(MESSAGE); }
            else view(HOME);
        } else if (s.view == DRAFT || s.view == DRAFT_OPTIONS) {
            if (ok && op == HT_DRAFT_MOVE) {
                s.offset = direction < 0 ? question_rows(page.text)-5 : 0;
                if (s.offset < 0) s.offset = 0;
            } else if (ok && op == HT_DRAFT_UNDO) s.offset = 0;
            input_cancel(); change();
        }
        ht_gesture_guard(&gesture, ms());
    }
    display_unlock();
}
void ui_form_state(const cJSON *p)
{
    const cJSON *request = cJSON_GetObjectItemCaseSensitive(p, "requestId"),
                *id = cJSON_GetObjectItemCaseSensitive(p, "formId");
    if (!cJSON_IsString(request) || strncmp(request->valuestring, "form-", 5) || !cJSON_IsString(id)) return;
    char *end = NULL;
    unsigned long serial = strtoul(request->valuestring + 5, &end, 10);
    if (!serial || !end || *end || serial > UINT32_MAX) return;
    ht_form_page_t page = {0};
    if (!form_page(p, &page)) return;
    display_lock();
    bool ok=cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok"));
    if (form.pending && form.request==(uint32_t)serial && !strcmp(form.id,id->valuestring) &&
        (form.pending_op!=HT_FORM_STATE || !ok))
        ESP_LOGI("habitat","picker reply req=%lu ok=%d active=%d query=%d busy=%d",
            serial,ok,page.active,page.can_query,page.busy);
    if (ht_form_reply(&form, id->valuestring, (uint32_t)serial,
            ok, &page, ms())) {
        if (!form.id[0]) { ht_gesture_guard(&gesture, ms()); view(HOME); }
        else if (s.view == FORM) change();
    }
    display_unlock();
}
void ui_voice_question(const cJSON *p)
{
    const cJSON *agent=cJSON_GetObjectItemCaseSensitive(p,"agentId"),
        *token=cJSON_GetObjectItemCaseSensitive(p,"token"),
        *index=cJSON_GetObjectItemCaseSensitive(p,"questionIndex"),
        *draft=cJSON_GetObjectItemCaseSensitive(p,"draftId"),
        *text=cJSON_GetObjectItemCaseSensitive(p,"text");
    display_lock();
    if (!s.voice_open || !s.voice_waiting || !question_view(s.voice_return)) { display_unlock(); return; }
    if (!s.q.valid || s.q.revision!=s.voice_question_revision ||
        !cJSON_IsString(agent) || strcmp(agent->valuestring,s.q.agent) ||
        !cJSON_IsString(token) || strcmp(token->valuestring,s.q.token) ||
        !cJSON_IsNumber(index) || index->valuedouble!=s.voice_question_index || s.q.index!=s.voice_question_index) {
        voice_close(); COPY(s.title,"Question changed"); COPY(s.message,"Open the alert again."); view(MESSAGE);
        display_unlock(); return;
    }
    question_item_t *q=&s.q.item[s.q.index];
    voice_close();
    if (!q->can_text || !cJSON_IsString(draft) || !draft->valuestring[0] || strlen(draft->valuestring)>=sizeof q->draft ||
        !cJSON_IsString(text) || !text->valuestring[0] || strlen(text->valuestring)>1200 ||
        !ht_can_display(text->valuestring,UI_FONT,348,1200)) {
        q->draft[0]=q->answer[0]=0; q->selected=0;
        COPY(s.q.speech_error,"Cannot show that answer. Say it again or use the terminal."); view(QUESTION);
    } else {
        COPY(q->draft,draft->valuestring); COPY(q->answer,text->valuestring); q->selected=0;
        s.q.speech_error[0]=0; view(ANSWER_REVIEW);
    }
    ht_gesture_guard(&gesture,ms());
    display_unlock();
}
void ui_voice_form(const cJSON *p)
{
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(p, "formId");
    if (!cJSON_IsString(id)) return;
    ht_form_page_t page = {0};
    if (!form_page(p, &page)) return;
    display_lock();
    if (!s.voice_open || !s.voice_waiting || s.voice_return != FORM || strcmp(form.id, id->valuestring)) {
        display_unlock(); return;
    }
    voice_close();
    if (cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok")) && !page.active) {
        ht_form_reset(&form); view(HOME);
    } else {
        if (page.active) form.page = page;
        else COPY(form.page.error, page.error[0] ? page.error : "Say the name again.");
        form.poll = ms() + (form.page.error[0] ? 6000 : 1000);
        view(FORM);
    }
    ht_gesture_guard(&gesture, ms());
    display_unlock();
}
void ui_visit_state(const cJSON *p)
{
    const cJSON *request = cJSON_GetObjectItemCaseSensitive(p, "requestId"),
        *id = cJSON_GetObjectItemCaseSensitive(p, "visitId"),
        *label = cJSON_GetObjectItemCaseSensitive(p, "label"),
        *agent = cJSON_GetObjectItemCaseSensitive(p, "agentId"),
        *error = cJSON_GetObjectItemCaseSensitive(p, "error"),
        *note = cJSON_GetObjectItemCaseSensitive(p, "note");
    if (!cJSON_IsString(request) || strncmp(request->valuestring, "visit-", 6) || !cJSON_IsString(id)) return;
    char *end = NULL;
    unsigned long serial = strtoul(request->valuestring + 6, &end, 10);
    if (!serial || !end || *end || serial > UINT32_MAX) return;
    bool ok = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "ok"));
    if (ok && (!cJSON_IsString(agent) || !agent->valuestring[0] || strlen(agent->valuestring) >= ID_MAX)) return;
    display_lock();
    bool inspect=visit.op==HT_VISIT_OPEN;
    bool latest=visit.op==HT_VISIT_LATEST;
    if (ht_visit_reply(&visit, id->valuestring, (uint32_t)serial,
            cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(p, "active")),
            cJSON_IsString(label) ? label->valuestring : "")) {
        s.pending_focus[0] = 0;
        if (ok) {
            int i = find(agent->valuestring);
            if (i >= 0) {
                input_cancel(); s.active = i;
                if (inspect && visit.available && is_question(agent->valuestring)) open_question();
                else view(HOME);
            } else {
                COPY(s.pending_focus, agent->valuestring);
                COPY(s.title, "On your desktop");
                COPY(s.message, "Waiting for that pane...");
                view(MESSAGE);
            }
            if (cJSON_IsString(note) && note->valuestring[0]) {
                COPY(s.title, "Returned"); COPY(s.message, note->valuestring); view(MESSAGE);
            }
        } else {
            if (latest) COPY(s.title,"Latest output");
            else COPY(s.title,"Visit");
            COPY(s.message, cJSON_IsString(error) ? error->valuestring : "Open the alert again.");
            view(MESSAGE);
        }
        change();
    }
    display_unlock();
}

void ui_cable_toast(const char *message)
{
    display_lock();
    // General desktop notices must not dismiss a live recording or routing request.
    if (s.voice_open) {
        display_unlock();
        return;
    }
    display_unlock();
    ui_show_error("Harness", message);
}
void ui_voice_error(const char *message)
{
    display_lock();
    if (!s.voice_open || !s.voice_waiting) {
        display_unlock();
        return;
    }
    voice_close();
    if (s.voice_search && selection.active) {
        COPY(selection.error, message); view(SELECTION);
    } else if (s.voice_return == DRAFT && draft.page.active) {
        COPY(draft.page.error, message); draft.failed = true; view(DRAFT);
    } else if (question_view(s.voice_return) && s.q.valid && s.q.revision==s.voice_question_revision) {
        COPY(s.q.speech_error,message); view(s.voice_return);
    } else if (s.voice_return == FORM && form.id[0]) {
        COPY(form.page.error, message); form.poll = ms() + 6000; view(FORM);
    } else if (message && !strcmp(message, "Didn't catch that")) {
        // An empty transcript sent nothing. Keep the familiar voice surface
        // available for one-tap retry, then restore its previous result/status.
        view(HOME);
        s.voice_retry_until = ms() + 3000;
        if (!s.voice_retry_until) s.voice_retry_until = 1;
        change();
    } else {
        show_failure("Voice", message);
    }
    ht_gesture_guard(&gesture, ms());
    display_unlock();
}
void ui_show_connecting(const char *step)
{
    (void)step;
    display_lock();
    if (s.nf_retries < 999) s.nf_retries++;   // nixfred: one dot on the connecting ring per attempt
    display_unlock();
    ui_enter_boot_loading();
}
void ui_enter_remote_offline(void)
{
    ui_enter_boot_loading();
}
void ui_enter_link_guide(void)
{
    ui_show_error(
        "Link this machine",
        "On that computer:\nharness link create\n\nOn this computer:\nharness link import");
}
void ui_leave_remote_offline_loading(void) { ui_enter_boot_loading(); }
void ui_leave_error_screen(void) { ui_home_overview(); }
// nixfred: a pairing code sits in a hexagon whose edges pulse until the daemon answers (the screen leaves).
static void nf_show_pairing(const char *title, const char *code)
{
    display_lock();
    COPY(s.title, title);
    COPY(s.message, code ? code : "");
    s.nf_msg_kind = 3;
    s.nf_msg_at = ms() | 1;
    nf_msg_keep = true; view(MESSAGE); nf_msg_keep = false;
    display_unlock();
}
void ui_show_pairing(const char *code, int seconds)
{
    (void)seconds;
    nf_show_pairing("Pair device", code);
}
void ui_show_e2ee_pair(const char *code, int seconds)
{
    (void)seconds;
    nf_show_pairing("Pair machine", code);
}
void ui_show_e2ee_paired(const char *fingerprint) { ui_show_error("Machine paired", fingerprint); }
void ui_show_unpaired(void) { ui_enter_boot_loading(); }
void ui_show_ota_restarting(void)
{
    display_lock();
    view(OTA);
    display_unlock();
}
void ui_ota_boot_show(const char *version)
{
    (void)version;
    audio_client_abort();
    display_lock();
    voice_close();
    s.ota_pct = 0;
    view(OTA);
    display_unlock();
}
void ui_ota_boot_pct(int percent)
{
    // The rim fills with it (render_brand). Only a whole-percent change repaints: this is called per chunk.
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    display_lock();
    if (s.ota_pct != percent) { s.ota_pct = (int8_t)percent; change(); }
    display_unlock();
}
bool ui_voice_is_recording(void) { return audio_client_recording(); }
bool ui_voice_is_active(void) { return audio_client_active(); }
uint32_t ui_voice_start_tick(void) { return s.voice_started; }
void ui_voice_start(void)
{
    display_lock();
    action_t a = {.kind = A_VOICE};
    if ((s.view == HOME || s.view == AGENT) && active())
        COPY(a.id, active()->id);
    dispatch(a);
    display_unlock();
}
void ui_voice_start_goal(void)
{
    display_lock();
    action_t a = {.kind = A_VOICE, .value = 1};
    if ((s.view == HOME || s.view == AGENT) && active())
        COPY(a.id, active()->id);
    dispatch(a);
    display_unlock();
}
void ui_voice_stop(void)
{
    display_lock();
    dispatch((action_t){.kind = A_VOICE_STOP});
    display_unlock();
}
void ui_voice_routed(bool auto_sent, bool need_new, const char *route, const char *id,
                     const char *name, double confidence)
{
    (void)name;
    (void)confidence;
    display_lock();
    if (!s.voice_open || !s.voice_waiting || s.voice_review || s.voice_search || s.voice_return == DRAFT ||
        s.voice_return == FORM || question_view(s.voice_return)) {
        display_unlock();
        return;
    }
    if (auto_sent && s.voice_carry) ht_carry_close(&carry);
    voice_close();
    if (!need_new && id && *id) {
        int i = find(id);
        if (i >= 0)
            s.active = i;
        else
            COPY(s.pending_focus, id);
        view(AGENT);
    } else
        view(HOME);
    display_unlock();
    if (!auto_sent && route && *route && id && *id)
        cable_client_voice_confirm(route, id);
}
void ui_voice_route_abort(void)
{
    display_lock();
    dispatch((action_t){.kind = A_VOICE_ABORT});
    display_unlock();
}
void ui_voice_quota_status(int seconds)
{
    (void)seconds; /* Server still enforces quota; exceeded immediately aborts capture below. */
}
void ui_voice_quota_exceeded(void)
{
    ui_voice_route_abort();
    ui_cable_toast("Voice allowance reached.");
}
void ui_stop_active_turn(void)
{
    display_lock();
    if (active() && active()->busy) {
        COPY(s.stop_agent, active()->id);
        view(STOP);
    }
    display_unlock();
}
void ui_boot_pressed(void)
{
    display_lock();
    if (s.voice_open || audio_client_active()) {
        dispatch((action_t){.kind = A_VOICE_ABORT});
    } else if (s.view == AGENT && active() && active()->busy) {
        COPY(s.stop_agent, active()->id);
        view(STOP);
    } else
        view(HOME);
    display_unlock();
}
/*
 * THE SCREEN LOCK IS GONE.
 *
 * A 3 x 3 pattern drawn with a thumb protected a device that sits on a desk beside the unlocked
 * computer it is plugged into, and it was the one preference the app could never fully own: setting
 * one had to happen on the glass. It is not used, so it is not kept — and these three stay only as
 * the shape the rest of the firmware still calls.
 */
void ui_lock_init_gate(void) {}
void ui_lock_setup(void) {}
bool ui_lock_active(void) { return false; }
void ui_log_state_if_changed(void) {}

#ifdef DEVICE_OCTOPUS_BENCH
// Local fixtures only. No setting is saved and no action is sent to the desktop.
void habitat_bench_prepare(bool animate)
{
    (void)animate; // The benchmark switches only the shared body clock.
    display_lock();
    habitat_touch_cancel();
    s.quiet = s.nap = s.focus_face = s.straight_title = false;
    s.pet_pose = 0;
    s.notice_count = 0;
    s.tab_count = 0;
    s.connected = true;
    s.loading = false;
    s.voice_open = false;
    memset(&s.q, 0, sizeof s.q);
    memset(&character.motion, 0, sizeof character.motion);
    view(HOME);
    display_bump_activity();
    display_wake();
    display_unlock();
}
void habitat_bench_reader(void)
{
    display_lock();
    dispatch((action_t){.kind = A_READER});
    display_unlock();
}
void habitat_bench_question(const cJSON *questions)
{
    display_lock();
    s.q.loading = s.q.pending = false;
    s.q.error[0] = 0;
    COPY(s.q.name, "Benchmark question");
    question_load(questions);
    view(QUESTION);
    display_unlock();
}
bool habitat_bench_pressed(void)
{
    return s.touch_down && character.motion.reaction.pose.pressed;
}
#endif
