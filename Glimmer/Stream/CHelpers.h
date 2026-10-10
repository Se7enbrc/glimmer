// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Swift cannot catch Objective-C exceptions raised during audio device changes.
// Callers report the failed operation without logging exception payloads.

#ifndef Glimmer_Stream_CHelpers_h
#define Glimmer_Stream_CHelpers_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>
static inline BOOL gl_objc_try(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException * __unused exception) {
        return NO;
    }
}
#endif

#endif
