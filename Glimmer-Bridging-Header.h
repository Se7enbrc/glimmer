//
//  Glimmer-Bridging-Header.h
//
//  Bridges the C libraries the Swift-native streaming engine depends on:
//  Opus (audio decode) and OpenSSL (Identity + Pairing + Network crypto),
//  plus our own inline C shims (CHelpers.h). Glimmer's streaming protocol
//  stack is pure Swift (Glimmer/Stream/Native/*).

#ifndef Glimmer_Bridging_Header_h
#define Glimmer_Bridging_Header_h

// Inline C shims (audio-config bit helpers + OpenSSL macro/variadic wrappers).
#import "Glimmer/Stream/CHelpers.h"

// Opus multistream decoder (audio path).
#import <opus/opus_multistream.h>

// OpenSSL primitives used by Identity + Pairing + Network.
#import <openssl/bio.h>
#import <openssl/x509.h>
#import <openssl/pem.h>
#import <openssl/rand.h>
#import <openssl/aes.h>
#import <openssl/evp.h>
#import <openssl/sha.h>
#import <openssl/bn.h>
#import <openssl/pkcs12.h>
#import <openssl/err.h>
#import <openssl/ssl.h>

#endif
