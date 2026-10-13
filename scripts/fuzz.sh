#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Coverage-guided libFuzzer runs of the protocol parsers, which Xcode's toolchain can't build.
# Runs each fuzz/ target for FUZZ_SECONDS (default 60) in the pinned Swift.org Linux image;
# any crash, leak or hang fails the script and leaves its input under build/fuzz/.
set -euo pipefail

IMAGE="swift:6.3.2-noble@sha256:c4336909a71b2e69b884f4078cdf98c0cd081911632cb349ef72abc4cbed69fc"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${GLIMMER_FUZZ_IN_CONTAINER:-}" ]; then
    exec docker run --rm -e GLIMMER_FUZZ_IN_CONTAINER=1 -e FUZZ_SECONDS -e FUZZ_TARGETS \
        -v "$ROOT:/src" -w /src "$IMAGE" scripts/fuzz.sh
fi

NATIVE=GlimmerEngine/Network

OUT=build/fuzz
ENGINE=GlimmerEngine/Protocol
mkdir -p "$OUT/engine"
# Linux has no CryptoKit. Compile the parser/FEC slice as its own instrumented module;
# the Mac ASan suites retain control crypto coverage.
swiftc -swift-version 6 -strict-concurrency=complete -package-name Glimmer -O -g -parse-as-library \
    -sanitize=fuzzer,address -whole-module-optimization -emit-object -emit-module \
    -enable-testing -module-name GlimmerEngine -emit-module-path "$OUT/engine/GlimmerEngine.swiftmodule" \
    "$ENGINE/EnetWire.swift" "$ENGINE/ReedSolomon.swift" "$ENGINE/AudioFecDecoder.swift" \
    "$ENGINE/AudioFecDecoder+Recovery.swift" "$ENGINE/InputEncoder.swift" "$ENGINE/SdpCodec.swift" "$ENGINE/StreamProtocolConstants.swift" \
    "$ENGINE/StreamingBackend.swift" "$ENGINE/StreamingBackend+Values.swift" "$ENGINE/NativeAudioSink.swift" \
    "$ENGINE/StreamCrypto+VideoPacketLayout.swift" \
    "$NATIVE"/RtpVideoQueue*.swift "$NATIVE"/VideoDepacketizer*.swift \
    "$NATIVE"/RtpAudioQueue*.swift "$NATIVE/AudioFecDecoder+Queue.swift" \
    fuzz/Shims.swift \
    -o "$OUT/engine/GlimmerEngine.o"
for target in ${FUZZ_TARGETS:-rtsp video audio fec opus}; do
    mkdir -p "$OUT/$target/corpus"
    extra=()
    if [ "$target" = opus ]; then extra=(Glimmer/Stream/OpusDecoder+Packet.swift); fi
    swiftc -swift-version 6 -strict-concurrency=complete -package-name Glimmer -O -g -parse-as-library \
        -sanitize=fuzzer,address -use-ld=lld -I "$OUT/engine" "$OUT/engine/GlimmerEngine.o" \
        "fuzz/$target.swift" "${extra[@]}" -o "$OUT/$target/fuzzer"
    seeds=()
    if [ -d "fuzz/corpus/$target" ]; then seeds=("fuzz/corpus/$target"); fi
    echo "Fuzzing $target for ${FUZZ_SECONDS:-60} s"
    "$OUT/$target/fuzzer" -max_total_time="${FUZZ_SECONDS:-60}" -timeout=10 -print_final_stats=1 \
        -artifact_prefix="$OUT/$target/" "$OUT/$target/corpus" "${seeds[@]}"
done
