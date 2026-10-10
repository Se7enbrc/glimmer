#!/bin/bash
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

NATIVE=Glimmer/Stream/Native
sources() {
    case "$1" in
        rtsp) echo "$NATIVE/SdpCodec.swift Glimmer/Stream/StreamingBackend.swift Glimmer/Stream/StreamProtocolConstants.swift" ;;
        video) echo "$NATIVE/RtpVideoQueue*.swift $NATIVE/VideoDepacketizer*.swift $NATIVE/ReedSolomon.swift" \
            "Glimmer/Stream/StreamingBackend.swift Glimmer/Stream/StreamProtocolConstants.swift" ;;
        audio) echo "$NATIVE/RtpAudioQueue*.swift $NATIVE/AudioFecDecoder.swift $NATIVE/ReedSolomon.swift" ;;
        fec) echo "$NATIVE/AudioFecDecoder.swift $NATIVE/ReedSolomon.swift" ;;
        opus) echo "Glimmer/Stream/OpusDecoder+Packet.swift" ;;
    esac
}

OUT=build/fuzz
for target in ${FUZZ_TARGETS:-rtsp video audio fec opus}; do
    mkdir -p "$OUT/$target/corpus"
    # shellcheck disable=SC2046 # the source lists are globs
    swiftc -swift-version 6 -O -g -parse-as-library -sanitize=fuzzer,address -use-ld=lld \
        fuzz/Shims.swift "fuzz/$target.swift" $(sources "$target") -o "$OUT/$target/fuzzer"
    seeds=()
    if [ -d "fuzz/corpus/$target" ]; then seeds=("fuzz/corpus/$target"); fi
    echo "Fuzzing $target for ${FUZZ_SECONDS:-60} s"
    "$OUT/$target/fuzzer" -max_total_time="${FUZZ_SECONDS:-60}" -timeout=10 -print_final_stats=1 \
        -artifact_prefix="$OUT/$target/" "$OUT/$target/corpus" "${seeds[@]}"
done
