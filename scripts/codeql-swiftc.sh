#!/bin/bash
set -euo pipefail

# Trace the compiler without injecting into Xcode or SwiftPM's package sandbox.
# CodeQL init supplies the rest of its indirect tracing environment unchanged.
: "${GLIMMER_SWIFTC:?Set the real Xcode Swift compiler before CodeQL initialization}"
: "${SEMMLE_PRELOAD_libtrace:?CodeQL indirect tracing must be initialized}"
test -x "$GLIMMER_SWIFTC"
test -f "$SEMMLE_PRELOAD_libtrace"
export DYLD_INSERT_LIBRARIES="$SEMMLE_PRELOAD_libtrace"
exec "$GLIMMER_SWIFTC" "$@"
