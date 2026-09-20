#include "EncodedMuxer.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <poll.h>
#include <libavutil/time.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>

struct SAMuxer {
    AVFormatContext *format;
    AVIOContext *io;
    AVRational input_time_base;
    int fd;
    int header_written;
};

static int report(int code, char *error, size_t size) {
    if (error && size) av_strerror(code, error, size);
    return code;
}

static int write_bytes(void *opaque, const uint8_t *buffer, int size) {
    SAMuxer *muxer = opaque;
    int offset = 0;
    const int64_t deadline = av_gettime_relative() + 2000000;
    while (offset < size) {
        ssize_t count = write(muxer->fd, buffer + offset, (size_t)(size - offset));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (av_gettime_relative() >= deadline) return AVERROR(ETIMEDOUT);
            struct pollfd descriptor = { .fd = muxer->fd, .events = POLLOUT };
            int ready = poll(&descriptor, 1, 20);
            if (ready < 0 && errno != EINTR) return AVERROR(errno);
            continue;
        }
        if (count <= 0) return AVERROR(count < 0 ? errno : EIO);
        offset += (int)count;
    }
    return size;
}

static void release(SAMuxer *muxer) {
    if (!muxer) return;
    if (muxer->format) muxer->format->pb = NULL;
    if (muxer->io) {
        av_freep(&muxer->io->buffer);
        avio_context_free(&muxer->io);
    }
    avformat_free_context(muxer->format);
    av_free(muxer);
}

int sa_mux_open(SAMuxer **result, const uint8_t *sps, size_t sps_size,
                const uint8_t *pps, size_t pps_size, int width, int height,
                int fps, int fd, char *error, size_t error_size) {
    if (!result || !sps || !pps || sps_size < 4 || !pps_size ||
        sps_size > UINT16_MAX || pps_size > UINT16_MAX || width <= 0 ||
        height <= 0 || fps <= 0 || fd < 0)
        return report(AVERROR(EINVAL), error, error_size);
    *result = NULL;
    SAMuxer *muxer = av_mallocz(sizeof(*muxer));
    if (!muxer) return report(AVERROR(ENOMEM), error, error_size);
    muxer->fd = fd;
    muxer->input_time_base = (AVRational){1, fps};
    int status = avformat_alloc_output_context2(&muxer->format, NULL, "flv", NULL);
    if (status < 0) goto failed;
    uint8_t *buffer = av_malloc(32768);
    if (!buffer) { status = AVERROR(ENOMEM); goto failed; }
    muxer->io = avio_alloc_context(buffer, 32768, 1, muxer, NULL, write_bytes, NULL);
    if (!muxer->io) { av_free(buffer); status = AVERROR(ENOMEM); goto failed; }
    muxer->format->pb = muxer->io;
    muxer->format->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_FLUSH_PACKETS;
    AVStream *stream = avformat_new_stream(muxer->format, NULL);
    if (!stream) { status = AVERROR(ENOMEM); goto failed; }
    stream->time_base = muxer->input_time_base;
    stream->avg_frame_rate = (AVRational){fps, 1};
    AVCodecParameters *parameters = stream->codecpar;
    parameters->codec_type = AVMEDIA_TYPE_VIDEO;
    parameters->codec_id = AV_CODEC_ID_H264;
    parameters->width = width;
    parameters->height = height;
    parameters->bit_rate = 6000000;
    parameters->extradata_size = (int)(11 + sps_size + pps_size);
    parameters->extradata = av_mallocz((size_t)parameters->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!parameters->extradata) { status = AVERROR(ENOMEM); goto failed; }
    uint8_t *out = parameters->extradata;
    *out++ = 1; *out++ = sps[1]; *out++ = sps[2]; *out++ = sps[3];
    *out++ = 0xff; *out++ = 0xe1;
    *out++ = (uint8_t)(sps_size >> 8); *out++ = (uint8_t)sps_size;
    memcpy(out, sps, sps_size); out += sps_size;
    *out++ = 1;
    *out++ = (uint8_t)(pps_size >> 8); *out++ = (uint8_t)pps_size;
    memcpy(out, pps, pps_size);
    AVDictionary *options = NULL;
    // A pipe cannot seek back to rewrite duration/filesize; omit those fields.
    av_dict_set(&options, "flvflags", "no_duration_filesize", 0);
    status = avformat_write_header(muxer->format, &options);
    av_dict_free(&options);
    if (status < 0) goto failed;
    muxer->header_written = 1;
    avio_flush(muxer->io);
    if (muxer->io->error < 0) { status = muxer->io->error; goto failed; }
    *result = muxer;
    return 0;
failed:
    release(muxer);
    return report(status, error, error_size);
}

int sa_mux_write(SAMuxer *muxer, const uint8_t *data, size_t size,
                 int64_t pts, int64_t dts, int keyframe,
                 char *error, size_t error_size) {
    if (!muxer || !data || !size || size > INT_MAX)
        return report(AVERROR(EINVAL), error, error_size);
    AVStream *stream = muxer->format->streams[0];
    // av_write_frame retains caller ownership. The compressed sample stays alive
    // throughout this synchronous call; raw image memory is never accessed here.
    AVPacket packet = {0};
    packet.data = (uint8_t *)data;
    packet.size = (int)size;
    packet.pts = av_rescale_q(pts, muxer->input_time_base, stream->time_base);
    packet.dts = av_rescale_q(dts, muxer->input_time_base, stream->time_base);
    packet.duration = av_rescale_q(1, muxer->input_time_base, stream->time_base);
    packet.stream_index = stream->index;
    packet.pos = -1;
    if (keyframe) packet.flags |= AV_PKT_FLAG_KEY;
    int status = av_write_frame(muxer->format, &packet);
    avio_flush(muxer->io);
    if (status >= 0 && muxer->io->error < 0) status = muxer->io->error;
    return status < 0 ? report(status, error, error_size) : 0;
}

int sa_mux_close(SAMuxer **reference, char *error, size_t error_size) {
    if (!reference || !*reference) return 0;
    SAMuxer *muxer = *reference;
    *reference = NULL;
    int status = muxer->header_written ? av_write_trailer(muxer->format) : 0;
    if (muxer->io) {
        avio_flush(muxer->io);
        if (status >= 0 && muxer->io->error < 0) status = muxer->io->error;
    }
    release(muxer);
    return status < 0 ? report(status, error, error_size) : 0;
}
