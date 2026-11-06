#ifndef HWM_PLANE_CLICK_RUNTIME_H
#define HWM_PLANE_CLICK_RUNTIME_H
#include "plane_click_intent.h"
#include <os/lock.h>
#include <stdatomic.h>
static os_unfair_lock hwm_click_history_lock=OS_UNFAIR_LOCK_INIT;
static HWMPlaneClickIntent hwm_click_history;
static _Atomic uint32_t hwm_click_published_focus;
static _Atomic uint32_t hwm_click_native_pending; // Tap owns normal updates; lifecycle may invalidate.
static uint32_t hwm_click_selected_window;
static double hwm_click_selected_time;
static void hwm_click_navigation(double now) {
    os_unfair_lock_lock(&hwm_click_history_lock);
    hwm_plane_click_note_navigation(&hwm_click_history,now);
    os_unfair_lock_unlock(&hwm_click_history_lock);
}
static void hwm_click_interaction(uint32_t id,double now) {
    if(!id) return;
    os_unfair_lock_lock(&hwm_click_history_lock);
    hwm_plane_click_note_interaction(&hwm_click_history,id,now);
    os_unfair_lock_unlock(&hwm_click_history_lock);
}
static void hwm_click_selection(uint32_t id,double now) {
    os_unfair_lock_lock(&hwm_click_history_lock);
    hwm_plane_click_note_interaction(&hwm_click_history,id,now);
    hwm_click_selected_window=id; hwm_click_selected_time=now;
    os_unfair_lock_unlock(&hwm_click_history_lock);
}
static void hwm_click_history_reset(void) {
    atomic_store(&hwm_click_native_pending,0);
    os_unfair_lock_lock(&hwm_click_history_lock);
    hwm_plane_click_reset(&hwm_click_history);
    hwm_click_selected_window=0;
    os_unfair_lock_unlock(&hwm_click_history_lock);
}
#endif
