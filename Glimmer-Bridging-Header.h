//
//  Glimmer-Bridging-Header.h
//
//  The only C the Swift engine calls: our own inline shims (CHelpers.h). The protocol, crypto, TLS
//  and audio decode are Swift on the platform frameworks (Glimmer/Stream/Native/*).

#ifndef Glimmer_Bridging_Header_h
#define Glimmer_Bridging_Header_h

// The Objective-C exception guard.
#import "Glimmer/Stream/CHelpers.h"

#endif
