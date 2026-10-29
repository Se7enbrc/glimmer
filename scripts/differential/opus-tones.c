// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Encodes channel-identification tones (channel n: 400 + 200n Hz) with libopus's multistream
// encoder and prints one hex packet per line. Input to make-corpus.py only; never linked into Glimmer.
// usage: opus-tones channels streams coupled mapping(csv) application frame fec loss bitrate packets
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <opus/opus_multistream.h>

int main(int argc, char **argv) {
    if (argc != 11) return 2;
    int channels = atoi(argv[1]), streams = atoi(argv[2]), coupled = atoi(argv[3]);
    unsigned char mapping[8];
    char *cursor = argv[4];
    for (int i = 0; i < channels; i++) { mapping[i] = (unsigned char)strtol(cursor, &cursor, 10); cursor++; }
    int application = strcmp(argv[5], "voip") == 0 ? OPUS_APPLICATION_VOIP
        : strcmp(argv[5], "audio") == 0 ? OPUS_APPLICATION_AUDIO : OPUS_APPLICATION_RESTRICTED_LOWDELAY;
    int frame = atoi(argv[6]), fec = atoi(argv[7]), loss = atoi(argv[8]), bitrate = atoi(argv[9]);
    int packets = atoi(argv[10]), error = 0;
    OpusMSEncoder *encoder = opus_multistream_encoder_create(48000, channels, streams, coupled, mapping,
                                                              application, &error);
    if (error != OPUS_OK) return 1;
    opus_multistream_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
    opus_multistream_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(fec));
    opus_multistream_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(loss));
    float pcm[5760 * 8];
    unsigned char out[1275 * 8];
    long t = 0;
    for (int p = 0; p < packets; p++) {
        for (int f = 0; f < frame; f++, t++)
            for (int c = 0; c < channels; c++)
                pcm[f * channels + c] = 0.4f * sinf(2.0f * (float)M_PI * (400.0f + 200.0f * c) * t / 48000.0f);
        int size = opus_multistream_encode_float(encoder, pcm, frame, out, sizeof out);
        if (size < 0) return 1;
        for (int i = 0; i < size; i++) printf("%02x", out[i]);
        printf("\n");
    }
    opus_multistream_encoder_destroy(encoder);
    return 0;
}
