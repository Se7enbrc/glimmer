//
//  Glimmer-Bridging-Header.h
//
//  The C the Swift engine still calls: Opus (audio decode) and our own inline shims (CHelpers.h).
//  The protocol, crypto and TLS are Swift on the platform frameworks (Glimmer/Stream/Native/*).

#ifndef Glimmer_Bridging_Header_h
#define Glimmer_Bridging_Header_h

// Inline C shims: FEC kernels, batched receive, audio-config bits and platform glue.
#import "Glimmer/Stream/CHelpers.h"

// Opus multistream decoder (audio path).
#import <opus/opus_multistream.h>

#endif
