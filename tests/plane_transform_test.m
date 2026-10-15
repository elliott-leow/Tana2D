/* Verify the byte-exact absolute transform packet shared by manager and helper. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>
#include <float.h>
#include <stdio.h>
#include "../vendor/yabai/src/misc/plane_transform.h"

static void near(double actual, double expected) { assert(fabs(actual - expected) < 1e-12); }

static void verify_transform(HwmPlaneTransform value)
{
    CGAffineTransform matrix = hwm_plane_transform_matrix(value);
    near(matrix.a, 1.0 / value.scale_x); near(matrix.d, 1.0 / value.scale_y);
    near(matrix.b, 0); near(matrix.c, 0);
    near(matrix.tx, -value.x / value.scale_x); near(matrix.ty, -value.y / value.scale_y);
}

int main(void)
{
    HwmPlaneTransform values[] = {
        { 41, 40, 60, .5, .5 },
        { 41, 40, 60, .5, .5 }, /* Repeating is another absolute target, never a toggle. */
        { 42, -250.25, 100.5, 2, 2 },
        { 43, 800, 600, 1, 1 }, /* Explicit reset resolved to native origin by manager. */
        { 44, 75, -125, .8, 1.25 }, /* Independent border/content-size animation scales. */
    };
    unsigned char packet[SA_SOCKET_BUFF_LEN]; size_t length = 0;
    assert(hwm_plane_transform_packet_encode(packet, sizeof(packet), values, 5, &length));
    assert(packet[0] == SA_OPCODE_WINDOW_PLANE_TRANSFORM);
    assert(length == SA_PLANE_TRANSFORM_HEADER_BYTES + 5 * SA_PLANE_TRANSFORM_RECORD_BYTES);

    HwmPlaneTransform decoded[SA_PLANE_TRANSFORM_MAX_RECORDS]; uint16_t count = 0;
    assert(hwm_plane_transform_packet_decode(packet + 1, length - 1, decoded, SA_PLANE_TRANSFORM_MAX_RECORDS, &count));
    assert(count == 5);
    for (uint16_t index = 0; index < count; ++index) {
        assert(decoded[index].wid == values[index].wid);
        near(decoded[index].x, values[index].x); near(decoded[index].y, values[index].y);
        near(decoded[index].scale_x, values[index].scale_x); near(decoded[index].scale_y, values[index].scale_y);
        verify_transform(decoded[index]);
    }
    assert(CGAffineTransformEqualToTransform(hwm_plane_transform_matrix(decoded[0]), hwm_plane_transform_matrix(decoded[1])));

    for (uint16_t index = 0; index < count; ++index) {
        CGRect native = CGRectMake(180, 51, 400, 300), displayed; bool reset;
        assert(hwm_plane_transform_bounds(values[index], native, &displayed, &reset));
        near(displayed.origin.x, values[index].x); near(displayed.origin.y, values[index].y);
        near(displayed.size.width, 400 * values[index].scale_x);
        near(displayed.size.height, 300 * values[index].scale_y);
        HwmPlaneTransform restore = {values[index].wid, 180, 51, 1, 1};
        assert(hwm_plane_transform_bounds(restore, native, &displayed, &reset) && reset);
        assert(!hwm_plane_transform_bounds(restore, CGRectNull, &displayed, &reset));
        HwmPlaneTransform overflow = {1, 0, 0, DBL_MAX, 1};
        assert(!hwm_plane_transform_bounds(overflow, native, &displayed, &reset));
    }

    uint16_t zero = 0;
    assert(!hwm_plane_transform_packet_decode((const unsigned char *) &zero, sizeof(zero), decoded, SA_PLANE_TRANSFORM_MAX_RECORDS, &count));
    assert(!hwm_plane_transform_packet_decode(packet + 1, length - 2, decoded, SA_PLANE_TRANSFORM_MAX_RECORDS, &count));
    HwmPlaneTransform invalid = { 1, 0, 0, NAN, 1 };
    assert(!hwm_plane_transform_packet_encode(packet, sizeof(packet), &invalid, 1, &length));

    HwmPlaneTransform maximum[SA_PLANE_TRANSFORM_MAX_RECORDS];
    for (uint16_t index = 0; index < SA_PLANE_TRANSFORM_MAX_RECORDS; ++index) maximum[index] = (HwmPlaneTransform){ index + 1, index, -index, 1, 1 };
    assert(hwm_plane_transform_packet_encode(packet, sizeof(packet), maximum, SA_PLANE_TRANSFORM_MAX_RECORDS, &length));
    assert(length <= SA_SOCKET_BUFF_LEN);
    puts("absolute plane transform packet tests passed");
}
