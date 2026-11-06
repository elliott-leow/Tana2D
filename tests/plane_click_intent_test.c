#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/plane_click_intent.h"

int main(void)
{
    HWMPlaneClickIntent history = {0};
    HWMPlaneClickContext c = { .window = 1, .now = 100, .scale = .7,
                               .far_threshold = .5, .eligible = true };
    /* Unknown history keeps native behavior; explicit navigation selects. */
    assert(!hwm_plane_click_should_select(&history, c));
    hwm_plane_click_note_navigation(&history, 100);
    assert(hwm_plane_click_should_select(&history, c));
    /* A completed selection makes subsequent clicks on that app native. */
    hwm_plane_click_note_interaction(&history, 1, 101);
    c.now = 102;
    assert(!hwm_plane_click_should_select(&history, c));
    c.window = 2;
    assert(hwm_plane_click_should_select(&history, c));
    hwm_plane_click_note_interaction(&history, 2, 103);
    c.window = 1; c.now = 104;
    assert(hwm_plane_click_should_select(&history, c));
    /* Exclusions cover modified clicks and native controls/titlebars/edges. */
    c.eligible = false;
    assert(!hwm_plane_click_should_select(&history, c));
    hwm_plane_click_note_interaction(&history, 1, 104);
    c.eligible = true;
    c.now = 105;
    assert(!hwm_plane_click_should_select(&history, c));
    hwm_plane_click_note_navigation(&history, 106);
    c.now = 107;
    assert(hwm_plane_click_should_select(&history, c));
    /* Cancellation or drag does not call note_interaction. */
    assert(hwm_plane_click_should_select(&history, c));
    c.now = 137;
    assert(!hwm_plane_click_should_select(&history, c));
    c.now = 105; /* clock rollback */
    assert(!hwm_plane_click_should_select(&history, c));
    c.scale = .4;
    assert(hwm_plane_click_should_select(&history, c));
    c.eligible = false;
    assert(!hwm_plane_click_should_select(&history, c));
    c.eligible = true;
    c.scale = 1;
    assert(!hwm_plane_click_should_select(&history, c));
    c.scale = NAN;
    assert(!hwm_plane_click_should_select(&history, c));
    hwm_plane_click_note_navigation(&history,108);
    c.now=108; c.scale=.7; c.far_threshold=0;
    assert(!hwm_plane_click_should_select(&history,c));
    c.far_threshold=.5;
    hwm_plane_click_reset(&history);
    c.scale = .7; c.now = 108;
    assert(!hwm_plane_click_should_select(&history, c));
    puts("plane_click_intent_test: OK");
    return 0;
}
