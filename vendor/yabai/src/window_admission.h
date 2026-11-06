#ifndef TANA2D_WINDOW_ADMISSION_H
#define TANA2D_WINDOW_ADMISSION_H

/* Secondary windows belong to another window of their application: dialogs
 * and alerts, inspectors and utility panels (AXFloatingWindow), windows
 * attached to a parent window, and app-modal windows. They float above the
 * plane next to the window they belong to; only that window is a tile.
 *
 * Accessibility roles describe app widgets inconsistently: Audition's main
 * window is AXLayoutArea/AXFloatingWindow. A window with a custom role is
 * therefore taken as a main window unless it says it is a dialog, while an
 * AXWindow must be a standard window. */
static bool window_manager_is_secondary_window(struct window *window)
{
    if (window->is_child || window->is_modal) return true;
    if (window_has_window_role(window)) return !window_is_standard(window);
    return window_is_dialog(window);
}

/* Movable, normal-level root windows that are not secondary join the plane,
 * including fixed-size windows and custom-role main windows. System overlays
 * and attached child windows stay outside it. */
static bool window_manager_is_plane_window(struct window *window)
{
    return window->is_root && window_can_move(window) && window_level_is_standard(window) &&
           !window_manager_is_secondary_window(window);
}

/* A yabai "manage=on" rule is the one explicit override. */
static bool window_manager_may_tile(struct window *window)
{
    return window_manager_is_plane_window(window) || window_check_rule_flag(window, WINDOW_RULE_MANAGED);
}

bool window_manager_is_window_eligible(struct window *window)
{
#ifdef HWM_TEST_FIXTURE_ONLY
    if(!window->application || !window->application->name || strcmp(window->application->name,"Tana2DFixture")) return false;
#endif
    return window->is_root && (window_is_real(window) || window_manager_may_tile(window));
}
static bool window_manager_should_float_by_default(struct window *window)
{
    return window_is_sticky(window->id) ||
           !window_manager_is_plane_window(window);
}

bool window_manager_should_manage_window(struct window *window)
{
#ifdef HWM_TEST_FIXTURE_ONLY
    if(!window_manager_is_window_eligible(window)) return false;
#endif
    if (!window->is_root)                           return false;
    if (window_check_flag(window, WINDOW_FLOAT))    return false;
    if (window_is_sticky(window->id))               return false;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return false;
    if (window->application->is_hidden)             return false;

    return window_manager_may_tile(window);
}

#endif
