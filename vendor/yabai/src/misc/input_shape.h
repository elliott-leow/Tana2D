#ifndef TANA2D_INPUT_SHAPE_H
#define TANA2D_INPUT_SHAPE_H

/* The input-event shape is local window coordinates.  This deliberately
 * bounds all values: the helper is a privileged Dock payload, and an input
 * shape larger than 65536 points in any direction is never useful here. */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "../osax/common.h"

enum {
    HWM_INPUT_SHAPE_CLEAR = 0,
    HWM_INPUT_SHAPE_SET = 1,
    HWM_INPUT_SHAPE_MAX_COORDINATE = 65536,
    HWM_INPUT_SHAPE_LEASE_MS = 500,
    HWM_INPUT_SHAPE_PACKET_SET_BYTES = 1 + 1 + sizeof(uint32_t) + 4 * sizeof(double),
    HWM_INPUT_SHAPE_PACKET_CLEAR_BYTES = 1 + 1,
};

typedef struct {
    uint32_t wid;
    CGRect rect;
} HwmInputShapeRequest;

typedef struct {
    bool active;
    int owner_pid;
    uint32_t wid;
    long long expires_at_ms;
} HwmInputShapeLease;

static inline bool hwm_input_shape_rect_valid(CGRect rect)
{
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height) &&
           rect.size.width > 0 && rect.size.height > 0 &&
           fabs(rect.origin.x) <= HWM_INPUT_SHAPE_MAX_COORDINATE &&
           fabs(rect.origin.y) <= HWM_INPUT_SHAPE_MAX_COORDINATE &&
           rect.size.width <= HWM_INPUT_SHAPE_MAX_COORDINATE &&
           rect.size.height <= HWM_INPUT_SHAPE_MAX_COORDINATE &&
           fabs(rect.origin.x + rect.size.width) <= HWM_INPUT_SHAPE_MAX_COORDINATE &&
           fabs(rect.origin.y + rect.size.height) <= HWM_INPUT_SHAPE_MAX_COORDINATE;
}

static inline bool hwm_input_shape_packet_encode(unsigned char *out, size_t capacity,
                                                  const HwmInputShapeRequest *request)
{
    if (!out || !request || capacity < HWM_INPUT_SHAPE_PACKET_SET_BYTES ||
        !request->wid || !hwm_input_shape_rect_valid(request->rect)) return false;
    size_t offset = 0;
    out[offset++] = SA_OPCODE_WINDOW_INPUT_SHAPE;
    out[offset++] = HWM_INPUT_SHAPE_SET;
    memcpy(out + offset, &request->wid, sizeof(request->wid)); offset += sizeof(request->wid);
    double values[] = { request->rect.origin.x, request->rect.origin.y,
                        request->rect.size.width, request->rect.size.height };
    memcpy(out + offset, values, sizeof(values));
    return true;
}

static inline bool hwm_input_shape_packet_encode_clear(unsigned char *out, size_t capacity)
{
    if (!out || capacity < HWM_INPUT_SHAPE_PACKET_CLEAR_BYTES) return false;
    out[0] = SA_OPCODE_WINDOW_INPUT_SHAPE;
    out[1] = HWM_INPUT_SHAPE_CLEAR;
    return true;
}

/* Stream framing is part of the client contract: the Dock daemon reads this
 * signed 16-bit byte count before the opcode. */
static inline bool hwm_input_shape_wire_encode(unsigned char *out, size_t capacity,
                                               const unsigned char *payload, size_t payload_length)
{
    if (!out || !payload || !payload_length || payload_length > INT16_MAX ||
        capacity < payload_length + sizeof(int16_t)) return false;
    int16_t wire_length = (int16_t) payload_length;
    memcpy(out, &wire_length, sizeof(wire_length));
    memcpy(out + sizeof(wire_length), payload, payload_length);
    return true;
}

/* Decode bytes after the opcode.  SET and CLEAR have distinct exact lengths. */
static inline bool hwm_input_shape_packet_decode(const unsigned char *bytes, size_t length,
                                                  bool *clear, HwmInputShapeRequest *request)
{
    if (!bytes || !clear || !request || !length) return false;
    if (bytes[0] == HWM_INPUT_SHAPE_CLEAR) {
        if (length != 1) return false;
        *clear = true;
        memset(request, 0, sizeof(*request));
        return true;
    }
    if (bytes[0] != HWM_INPUT_SHAPE_SET || length != HWM_INPUT_SHAPE_PACKET_SET_BYTES - 1) return false;
    size_t offset = 1;
    memcpy(&request->wid, bytes + offset, sizeof(request->wid)); offset += sizeof(request->wid);
    double values[4]; memcpy(values, bytes + offset, sizeof(values));
    request->rect = CGRectMake(values[0], values[1], values[2], values[3]);
    *clear = false;
    return request->wid && hwm_input_shape_rect_valid(request->rect);
}

static inline bool hwm_input_shape_lease_is_live(const HwmInputShapeLease *lease, long long now_ms)
{
    return lease && lease->active && now_ms < lease->expires_at_ms;
}

static inline bool hwm_input_shape_lease_owner(const HwmInputShapeLease *lease, int pid, long long now_ms)
{
    return hwm_input_shape_lease_is_live(lease, now_ms) && lease->owner_pid == pid;
}

static inline void hwm_input_shape_lease_refresh(HwmInputShapeLease *lease, int pid,
                                                  uint32_t wid, long long now_ms)
{
    lease->active = true; lease->owner_pid = pid; lease->wid = wid;
    lease->expires_at_ms = now_ms + HWM_INPUT_SHAPE_LEASE_MS;
}

#endif
