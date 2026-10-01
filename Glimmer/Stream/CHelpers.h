//
//  CHelpers.h
//
//  The one shim Swift can't express: catching an Objective-C exception. Imported
//  via the bridging header.

#ifndef Glimmer_Stream_CHelpers_h
#define Glimmer_Stream_CHelpers_h

// MARK: - ObjC exception guard (AV-call crash shield)
// AVFAudio raises NSException from calls like -[AVAudioPlayerNode play] when
// the engine stopped underneath it - system sleep tears the audio hardware
// down mid-stream, so a resume-edge play() 9s after wake met a stopped engine
// and the exception, uncatchable from Swift, aborted the whole process
// (SIGABRT via std::terminate - the 2026-08-17 post-wake crash). This shim
// runs a block under @try so the caller gets a Bool instead of a corpse; the
// caught exception is logged here (name + reason) since it cannot cross the
// boundary. ObjC-only (the bridging header compiles as ObjC; pure-C includes
// of this header skip it).
#ifdef __OBJC__
#import <Foundation/Foundation.h>
static inline BOOL gl_objc_try(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"gl_objc_try caught %@: %@", exception.name, exception.reason);
        return NO;
    }
}
#endif

#endif
