#ifndef TANA2D_PLANE_TRANSFORM_H
#define TANA2D_PLANE_TRANSFORM_H

/* Wire contract for absolute compositor transforms. The payload applies one
 * packet in one WindowServer transaction; native window frames are untouched. */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "../osax/common.h"

enum {
    SA_PLANE_TRANSFORM_HEADER_BYTES = 1 + sizeof(uint16_t),
    SA_PLANE_TRANSFORM_RECORD_BYTES = sizeof(uint32_t) + 4 * sizeof(double),
    SA_PLANE_TRANSFORM_MAX_RECORDS = (SA_SOCKET_BUFF_LEN - SA_PLANE_TRANSFORM_HEADER_BYTES) / SA_PLANE_TRANSFORM_RECORD_BYTES,
};

typedef struct {
    uint32_t wid;
    double x, y, scale_x, scale_y;
} HwmPlaneTransform;

static inline bool hwm_plane_transform_valid(HwmPlaneTransform transform)
{
    return transform.wid && isfinite(transform.x) && isfinite(transform.y) &&
           isfinite(transform.scale_x) && transform.scale_x > 0 &&
           isfinite(transform.scale_y) && transform.scale_y > 0 &&
           isfinite(1.0 / transform.scale_x) && isfinite(1.0 / transform.scale_y) &&
           isfinite(transform.x / transform.scale_x) && isfinite(transform.y / transform.scale_y);
}

static inline CGAffineTransform hwm_plane_transform_matrix(HwmPlaneTransform transform)
{
    double inverse_x = 1.0 / transform.scale_x;
    double inverse_y = 1.0 / transform.scale_y;
    return CGAffineTransformMake(inverse_x, 0, 0, inverse_y,
                                 -transform.x * inverse_x, -transform.y * inverse_y);
}

/* Encode the helper message excluding its int16 stream-length prefix. */
static inline bool hwm_plane_transform_packet_encode(unsigned char *out, size_t capacity,
                                                      const HwmPlaneTransform *items, uint16_t count,
                                                      size_t *length_out)
{
    size_t length = SA_PLANE_TRANSFORM_HEADER_BYTES + (size_t) count * SA_PLANE_TRANSFORM_RECORD_BYTES;
    if (!out || !items || !length_out || !count || count > SA_PLANE_TRANSFORM_MAX_RECORDS || length > capacity) return false;
    out[0] = SA_OPCODE_WINDOW_PLANE_TRANSFORM;
    memcpy(out + 1, &count, sizeof(count));
    size_t offset = SA_PLANE_TRANSFORM_HEADER_BYTES;
    for (uint16_t index = 0; index < count; ++index) {
        if (!hwm_plane_transform_valid(items[index])) return false;
        memcpy(out + offset, &items[index].wid, sizeof(items[index].wid)); offset += sizeof(items[index].wid);
        memcpy(out + offset, &items[index].x, sizeof(items[index].x)); offset += sizeof(items[index].x);
        memcpy(out + offset, &items[index].y, sizeof(items[index].y)); offset += sizeof(items[index].y);
        memcpy(out + offset, &items[index].scale_x, sizeof(items[index].scale_x)); offset += sizeof(items[index].scale_x);
        memcpy(out + offset, &items[index].scale_y, sizeof(items[index].scale_y)); offset += sizeof(items[index].scale_y);
    }
    *length_out = length;
    return true;
}

/* Decode bytes after the opcode. This is shared by the payload and unit test
 * so malformed count/length combinations cannot reach the transaction. */
static inline bool hwm_plane_transform_packet_decode(const unsigned char *bytes, size_t length,
                                                      HwmPlaneTransform *out, uint16_t capacity,
                                                      uint16_t *count_out)
{
    uint16_t count = 0;
    if (!bytes || !out || !count_out || length < sizeof(count)) return false;
    memcpy(&count, bytes, sizeof(count));
    if (!count || count > SA_PLANE_TRANSFORM_MAX_RECORDS || count > capacity ||
        length != sizeof(count) + (size_t) count * SA_PLANE_TRANSFORM_RECORD_BYTES) return false;
    size_t offset = sizeof(count);
    for (uint16_t index = 0; index < count; ++index) {
        memcpy(&out[index].wid, bytes + offset, sizeof(out[index].wid)); offset += sizeof(out[index].wid);
        memcpy(&out[index].x, bytes + offset, sizeof(out[index].x)); offset += sizeof(out[index].x);
        memcpy(&out[index].y, bytes + offset, sizeof(out[index].y)); offset += sizeof(out[index].y);
        memcpy(&out[index].scale_x, bytes + offset, sizeof(out[index].scale_x)); offset += sizeof(out[index].scale_x);
        memcpy(&out[index].scale_y, bytes + offset, sizeof(out[index].scale_y)); offset += sizeof(out[index].scale_y);
        if (!hwm_plane_transform_valid(out[index])) return false;
    }
    *count_out = count;
    return true;
}

#endif
