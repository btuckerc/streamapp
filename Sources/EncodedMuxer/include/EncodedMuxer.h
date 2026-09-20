#ifndef STREAMAPP_ENCODED_MUXER_H
#define STREAMAPP_ENCODED_MUXER_H
#include <stddef.h>
#include <stdint.h>
// A timestamped, video-only FLV stream written to an already-open descriptor.
// The caller owns fd. Calls on a muxer must be serialized.
typedef struct SAMuxer SAMuxer;
int sa_mux_open(SAMuxer **muxer, const uint8_t *sps, size_t sps_size,
                const uint8_t *pps, size_t pps_size, int width, int height,
                int fps, int fd, char *error, size_t error_size);
// Packet is AVCC (four-byte NAL lengths). PTS/DTS are in 1/fps units.
int sa_mux_write(SAMuxer *muxer, const uint8_t *packet, size_t size,
                 int64_t pts, int64_t dts, int keyframe,
                 char *error, size_t error_size);
// Flushes trailer and frees the muxer, even when flushing fails; sets *muxer=NULL.
int sa_mux_close(SAMuxer **muxer, char *error, size_t error_size);
#endif
