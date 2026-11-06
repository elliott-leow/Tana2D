/* Production admission decisions, without querying or opening applications. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

enum { WINDOW_FLOAT=1, WINDOW_MINIMIZE=2, WINDOW_RULE_MANAGED=4 };
struct application { bool is_hidden; };
/* role: the AX role is AXWindow. standard/dialog: the subrole is
 * AXStandardWindow / a dialog subrole; neither is a panel (AXFloatingWindow)
 * or a custom subrole. */
struct window {
    uint32_t id;
    struct application *application;
    bool is_root, is_child, is_modal, role, standard, dialog, normal_level, movable, resizable;
    unsigned flags;
    double width, height;
};
static bool sticky;
static bool window_is_sticky(uint32_t id) { (void)id; return sticky; }
static bool window_can_move(struct window *w) { return w->movable; }
static bool window_has_window_role(struct window *w) { return w->role; }
static bool window_is_standard(struct window *w) { return w->role && w->standard; }
static bool window_is_dialog(struct window *w) { return w->dialog; }
/* window.c: AXWindow with a standard, floating or dialog subrole, which is
 * every AXWindow these cases describe. */
static bool window_is_real(struct window *w) { return w->role; }
static bool window_level_is_standard(struct window *w) { return w->normal_level; }
static bool window_check_flag(struct window *w,unsigned flag) { return (w->flags&flag)!=0; }
static bool window_check_rule_flag(struct window *w,unsigned flag) { return window_check_flag(w,flag); }
#include "../vendor/yabai/src/window_admission.h"

/* What window creation does with a new root window. */
static void created(struct window *w) { if(window_manager_should_float_by_default(w)) w->flags|=WINDOW_FLOAT; }

int main(void)
{
    struct application app={0};
    struct window startup={.id=1,.application=&app,.is_root=true,.role=true,.standard=true,
        .normal_level=true,.movable=true,.resizable=false,.width=300,.height=200};
    /* Previously creation floated this standard startup window permanently.
     * It must enter the plane while retaining its native dimensions. */
    struct window w=startup;
    created(&w);
    assert(window_manager_should_manage_window(&w));
    assert(w.width==300 && w.height==200 && !w.resizable);
    w.resizable=true; w.width=1000; w.height=800;
    assert(!window_manager_should_float_by_default(&w));
    assert(window_manager_should_manage_window(&w));

    /* Audition and other custom-role root windows must pass BOTH creation
     * eligibility and admission, without a per-app rule. No resize required.
     * Audition reports AXLayoutArea/AXFloatingWindow. */
    struct window custom=startup; custom.role=false; custom.standard=false;
    w=custom;
    assert(window_manager_is_window_eligible(&w));
    assert(!window_manager_should_float_by_default(&w));
    assert(window_manager_should_manage_window(&w));
    w.resizable=true; w.width=1710; w.height=1073;
    assert(window_manager_is_window_eligible(&w));
    assert(window_manager_should_manage_window(&w));

    /* Windows that belong to another window float and are never tiles:
     * dialogs, utility panels, attached child windows and modal windows. */
    struct window dialog=startup; dialog.standard=false; dialog.dialog=true;          /* AXWindow/AXDialog */
    struct window panel=startup; panel.standard=false;                                /* AXWindow/AXFloatingWindow */
    struct window child=startup; child.is_child=true;                                 /* WindowServer parent, AX root */
    struct window modal=startup; modal.is_modal=true;                                 /* app-modal AXStandardWindow */
    struct window custom_dialog=custom; custom_dialog.dialog=true;                    /* custom role, dialog subrole */
    struct window *secondary[]={&dialog,&panel,&child,&modal,&custom_dialog};
    for(size_t i=0;i<sizeof secondary/sizeof *secondary;i++) {
        w=*secondary[i];
        assert(window_manager_is_secondary_window(&w));
        assert(!window_manager_is_plane_window(&w));
        assert(window_manager_should_float_by_default(&w));
        created(&w);
        assert(!window_manager_should_manage_window(&w));
        /* Clearing the float flag (an app rule, the float toggle) is not admission. */
        w.flags&=~WINDOW_FLOAT;
        assert(!window_manager_should_manage_window(&w));
        assert(!window_manager_may_tile(&w));
    }
    /* AX dialogs and panels stay tracked (focus, floating behaviour) without
     * being tiled; custom-role dialogs are ignored like other unknown roles. */
    assert(window_manager_is_window_eligible(&dialog));
    assert(window_manager_is_window_eligible(&panel));
    assert(window_manager_is_window_eligible(&child));
    assert(!window_manager_is_window_eligible(&custom_dialog));
    /* A large or resizable dialog is still a dialog. */
    w=dialog; w.resizable=true; w.width=1200; w.height=900;
    assert(!window_manager_is_plane_window(&w));
    /* The main window those belong to is unaffected. */
    assert(!window_manager_is_secondary_window(&startup) && window_manager_is_plane_window(&startup));

    /* Raised overlays, immovable, sticky and child windows stay out. */
    w=startup; w.normal_level=false;
    assert(window_manager_should_float_by_default(&w));
    assert(!window_manager_should_manage_window(&w));
    w=startup; w.movable=false;
    assert(window_manager_should_float_by_default(&w));
    assert(!window_manager_should_manage_window(&w));
    w=startup; sticky=true;
    assert(window_manager_should_float_by_default(&w));
    assert(!window_manager_should_manage_window(&w));
    sticky=false; w.is_root=false;
    assert(!window_manager_is_window_eligible(&w));
    assert(!window_manager_should_manage_window(&w));

    /* User choices, hidden apps and minimization remain authoritative. */
    w=startup; w.flags=WINDOW_FLOAT;
    assert(!window_manager_should_manage_window(&w));
    w.flags=WINDOW_MINIMIZE;
    assert(!window_manager_should_manage_window(&w));
    w.flags=0; app.is_hidden=true;
    assert(!window_manager_should_manage_window(&w));
    app.is_hidden=false;
    /* An explicit yabai manage rule still tiles a nonstandard window. */
    w=panel; w.flags=WINDOW_RULE_MANAGED;
    assert(window_manager_may_tile(&w));
    assert(window_manager_should_manage_window(&w));
    w.flags|=WINDOW_FLOAT;
    assert(!window_manager_should_manage_window(&w));
    puts("window admission tests passed");
    return 0;
}
