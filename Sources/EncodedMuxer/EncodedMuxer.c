#include "EncodedMuxer.h"
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

// Writes the FLV subset StreamApp's FFmpeg child reads: one H.264 video stream
// (FLV codec 7), onMetaData without duration/filesize (the fd is a pipe), an AVC
// sequence header, AVC NALU tags with millisecond timestamps, and an end tag.
// Byte layout matches libavformat's flv muxer for this configuration.

enum { TAG_VIDEO = 9, TAG_META = 18, AVC = 7, FRAME_KEY = 1 << 4, FRAME_INTER = 2 << 4 };
static const uint64_t stall_limit_ns = 2000000000ull;

struct SAMuxer {
    int fd;
    int fps;
    int started;
    int64_t offset_ms;  // shifts a negative first DTS to zero, as libavformat does
    int64_t last_dts_ms;
    uint32_t last_ts;
};

static int report(int code, char *error, size_t size) {
    if (error && size && strerror_r(-code, error, size) != 0)
        snprintf(error, size, "Error number %d occurred", code);
    return code;
}

static uint8_t *wb16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; return p + 2; }
static uint8_t *wb24(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 16); return wb16(p + 1, v); }
static uint8_t *wb32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); return wb24(p + 1, v); }
static uint8_t *timestamp(uint8_t *p, uint32_t ts) { p = wb24(p, ts & 0xffffff); *p++ = (ts >> 24) & 0x7f; return p; }
static uint8_t *amf_string(uint8_t *p, const char *s) {
    size_t n = strlen(s);
    p = wb16(p, (uint32_t)n);
    memcpy(p, s, n);
    return p + n;
}
static uint8_t *amf_number(uint8_t *p, const char *key, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    p = amf_string(p, key);
    *p++ = 0;  // AMF number
    p = wb32(p, (uint32_t)(bits >> 32));
    return wb32(p, (uint32_t)bits);
}
// Tag header for a tag whose body ends at `end`; returns the trailing previous-tag-size.
static uint8_t *close_tag(uint8_t *tag, uint8_t *end) {
    uint32_t body = (uint32_t)(end - tag - 11);
    wb24(tag + 1, body);
    return wb32(end, body + 11);
}

// Retries short/non-blocking writes; fails after two seconds without progress.
static int write_all(int fd, struct iovec *iov, int count) {
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + stall_limit_ns;
    while (count > 0) {
        ssize_t written = writev(fd, iov, count);
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline) return -ETIMEDOUT;
            struct pollfd descriptor = { .fd = fd, .events = POLLOUT };
            if (poll(&descriptor, 1, 20) < 0 && errno != EINTR) return -errno;
            continue;
        }
        if (written <= 0) return written < 0 ? -errno : -EIO;
        deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + stall_limit_ns;
        size_t remaining = (size_t)written;
        while (count > 0 && remaining >= iov->iov_len) { remaining -= iov->iov_len; iov++; count--; }
        if (count > 0) { iov->iov_base = (uint8_t *)iov->iov_base + remaining; iov->iov_len -= remaining; }
    }
    return 0;
}

// av_rescale_q(value, 1/fps, 1/1000) with round-half-away-from-zero.
static int64_t milliseconds(int64_t value, int fps) {
    int64_t scaled = value < 0 ? -value : value;
    scaled = (scaled * 1000 + fps / 2) / fps;
    return value < 0 ? -scaled : scaled;
}

int sa_mux_open(SAMuxer **result, const uint8_t *sps, size_t sps_size,
                const uint8_t *pps, size_t pps_size, int width, int height,
                int fps, int fd, char *error, size_t error_size) {
    if (!result || !sps || !pps || sps_size < 4 || !pps_size ||
        sps_size > UINT16_MAX || pps_size > UINT16_MAX || width <= 0 ||
        height <= 0 || fps <= 0 || fd < 0)
        return report(-EINVAL, error, error_size);
    *result = NULL;
    SAMuxer *muxer = calloc(1, sizeof(*muxer));
    uint8_t *header = malloc(256 + sps_size + pps_size);
    if (!muxer || !header) { free(muxer); free(header); return report(-ENOMEM, error, error_size); }
    muxer->fd = fd;
    muxer->fps = fps;
    muxer->last_ts = UINT32_MAX;

    uint8_t *p = header;
    memcpy(p, "FLV\x01\x01", 5); p += 5;  // version 1, video only
    p = wb32(p, 9);
    p = wb32(p, 0);

    uint8_t *tag = p;
    *p++ = TAG_META; p += 3; p = timestamp(p, 0); p = wb24(p, 0);
    *p++ = 2; p = amf_string(p, "onMetaData");
    *p++ = 8; p = wb32(p, 5);  // ECMA array of five entries
    p = amf_number(p, "width", width);
    p = amf_number(p, "height", height);
    p = amf_number(p, "videodatarate", 6000000 / 1024.0);
    p = amf_number(p, "framerate", fps);
    p = amf_number(p, "videocodecid", AVC);
    p = amf_string(p, ""); *p++ = 9;  // object end
    p = close_tag(tag, p);

    tag = p;
    *p++ = TAG_VIDEO; p += 3; p = timestamp(p, 0); p = wb24(p, 0);
    *p++ = FRAME_KEY | AVC; *p++ = 0; p = wb24(p, 0);  // AVC sequence header
    *p++ = 1; *p++ = sps[1]; *p++ = sps[2]; *p++ = sps[3];
    *p++ = 0xff; *p++ = 0xe1;  // four-byte NAL lengths, one SPS
    p = wb16(p, (uint32_t)sps_size); memcpy(p, sps, sps_size); p += sps_size;
    *p++ = 1;
    p = wb16(p, (uint32_t)pps_size); memcpy(p, pps, pps_size); p += pps_size;
    p = close_tag(tag, p);

    struct iovec iov = { header, (size_t)(p - header) };
    int status = write_all(fd, &iov, 1);
    free(header);
    if (status < 0) { free(muxer); return report(status, error, error_size); }
    *result = muxer;
    return 0;
}

int sa_mux_write(SAMuxer *muxer, const uint8_t *data, size_t size,
                 int64_t pts, int64_t dts, int keyframe,
                 char *error, size_t error_size) {
    // FLV stores 24-bit tag sizes; five bytes precede the payload.
    if (!muxer || !data || !size || size + 5 >= 1u << 24 ||
        pts > INT64_MAX / 1000 || pts < -INT64_MAX / 1000 ||
        dts > INT64_MAX / 1000 || dts < -INT64_MAX / 1000)
        return report(-EINVAL, error, error_size);
    int64_t pts_ms = milliseconds(pts, muxer->fps), dts_ms = milliseconds(dts, muxer->fps);
    if (!muxer->started && dts_ms < 0) muxer->offset_ms = -dts_ms;
    if ((muxer->started && dts_ms < muxer->last_dts_ms) || pts_ms < dts_ms)
        return report(-EINVAL, error, error_size);
    muxer->started = 1;
    muxer->last_dts_ms = dts_ms;
    uint32_t ts = (uint32_t)(dts_ms + muxer->offset_ms);
    muxer->last_ts = ts;

    uint8_t header[16], trailer[4], *p = header;
    *p++ = TAG_VIDEO; p = wb24(p, (uint32_t)size + 5); p = timestamp(p, ts); p = wb24(p, 0);
    *p++ = (keyframe ? FRAME_KEY : FRAME_INTER) | AVC; *p++ = 1;  // AVC NALU
    wb24(p, (uint32_t)(pts_ms - dts_ms));
    wb32(trailer, (uint32_t)size + 16);
    // The compressed sample stays alive throughout this synchronous call.
    struct iovec iov[3] = { { header, sizeof header }, { (void *)data, size }, { trailer, sizeof trailer } };
    int status = write_all(muxer->fd, iov, 3);
    return status < 0 ? report(status, error, error_size) : 0;
}

int sa_mux_close(SAMuxer **reference, char *error, size_t error_size) {
    if (!reference || !*reference) return 0;
    SAMuxer *muxer = *reference;
    *reference = NULL;
    uint8_t tag[20], *p = tag;
    *p++ = TAG_VIDEO; p = wb24(p, 5); p = timestamp(p, muxer->last_ts); p = wb24(p, 0);
    *p++ = FRAME_KEY | AVC; *p++ = 2; p = wb24(p, 0);  // AVC end of sequence
    wb32(p, 16);
    struct iovec iov = { tag, sizeof tag };
    int status = write_all(muxer->fd, &iov, 1);
    free(muxer);
    return status < 0 ? report(status, error, error_size) : 0;
}
