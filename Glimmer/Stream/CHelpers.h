//
//  CHelpers.h
//
//  Tiny C shims that Swift can't express directly: audio-configuration bit
//  helpers and OpenSSL macro/variadic wrappers. Imported via the bridging
//  header so all Swift sources can call these.

#ifndef Glimmer_Stream_CHelpers_h
#define Glimmer_Stream_CHelpers_h

#include <stdint.h>
#include <arm_neon.h>
#include <time.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <netdb.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <openssl/bio.h>
#include <openssl/pkcs12.h>
#include <openssl/ssl.h>

// MARK: - GF(256) shard arithmetic
// Split-nibble tables keep field multiplication in registers while recovery
// runs on the receive thread. The tail handles unpadded audio and video shards.
static inline void gl_gf256_mul_add(uint8_t * _Nonnull dst, const uint8_t * _Nonnull src,
                                    size_t n, const uint8_t * _Nonnull lo, const uint8_t * _Nonnull hi) {
    uint8x16_t low = vld1q_u8(lo);
    uint8x16_t high = vld1q_u8(hi);
    uint8x16_t mask = vdupq_n_u8(15);
    size_t i = 0;
    for (; n - i >= 16; i += 16) {
        uint8x16_t value = vld1q_u8(src + i);
        uint8x16_t product = veorq_u8(vqtbl1q_u8(low, vandq_u8(value, mask)),
                                     vqtbl1q_u8(high, vshrq_n_u8(value, 4)));
        vst1q_u8(dst + i, veorq_u8(vld1q_u8(dst + i), product));
    }
    for (; i < n; i++) {
        uint8_t value = src[i];
        dst[i] ^= lo[value & 15] ^ hi[value >> 4];
    }
}

static inline void gl_gf256_mul(uint8_t * _Nonnull dst, size_t n,
                                const uint8_t * _Nonnull lo, const uint8_t * _Nonnull hi) {
    uint8x16_t low = vld1q_u8(lo);
    uint8x16_t high = vld1q_u8(hi);
    uint8x16_t mask = vdupq_n_u8(15);
    size_t i = 0;
    for (; n - i >= 16; i += 16) {
        uint8x16_t value = vld1q_u8(dst + i);
        vst1q_u8(dst + i, veorq_u8(vqtbl1q_u8(low, vandq_u8(value, mask)),
                                  vqtbl1q_u8(high, vshrq_n_u8(value, 4))));
    }
    for (; i < n; i++) {
        uint8_t value = dst[i];
        dst[i] = lo[value & 15] ^ hi[value >> 4];
    }
}

// MARK: - Batched UDP receive (recvmsg_x)
// `recvmsg_x` is Darwin's batched datagram receive (the macOS analogue of
// Linux's recvmmsg; used internally for QUIC). It reads MANY datagrams in one
// syscall - at 4K240 the video socket sees ~14k packets/s, and one recvfrom per
// packet is a large share of process CPU (issue #24). The public SDK ships only
// the syscall NUMBER, not a prototype or `struct msghdr_x`, so we declare both
// here. We use a gl_-prefixed struct name so a future SDK that exposes the real
// `struct msghdr_x` can't collide; the kernel only cares about the byte layout,
// which mirrors xnu's bsd/sys/socket.h exactly.
// Nullability is spelled out on every pointer in this header: once one
// declaration carries an annotation (gl_objc_try's block) clang audits the rest
// and warns on each unannotated pointer, and the project builds warning-free.
struct gl_msghdr_x {
    void * _Nullable          msg_name;        /* optional address */
    socklen_t                 msg_namelen;     /* size of address */
    struct iovec * _Nonnull   msg_iov;         /* scatter/gather array */
    int                       msg_iovlen;      /* # elements in msg_iov */
    void * _Nullable          msg_control;     /* ancillary data */
    socklen_t                 msg_controllen;  /* ancillary data buffer len */
    int                       msg_flags;       /* flags on received message */
    size_t                    msg_datalen;     /* byte length of buffer in msg_iov */
};
extern ssize_t recvmsg_x(int s, const struct gl_msghdr_x * _Nonnull msgp, unsigned int cnt, int flags);

/// Read up to `count` (<=64) datagrams from `fd` in one `recvmsg_x` syscall into
/// `storage` (count * stride bytes), writing each datagram's length into
/// `lengths[i]`. Returns the number of datagrams received, or -1 with errno set
/// (EAGAIN/EWOULDBLOCK on timeout, like recvfrom). All `msghdr_x` plumbing stays
/// in C so the layout is correct by construction; Swift sees a flat API.
static inline int gl_recvmsg_x_batch(int fd, uint8_t * _Nonnull storage, int stride,
                                     int count, int * _Nonnull lengths) {
    if (count > 64) count = 64;
    struct gl_msghdr_x msgs[64];
    struct iovec iovs[64];
    for (int i = 0; i < count; i++) {
        iovs[i].iov_base = storage + (size_t)i * (size_t)stride;
        iovs[i].iov_len = (size_t)stride;
        msgs[i].msg_name = NULL;    msgs[i].msg_namelen = 0;
        msgs[i].msg_iov = &iovs[i]; msgs[i].msg_iovlen = 1;
        msgs[i].msg_control = NULL; msgs[i].msg_controllen = 0;
        msgs[i].msg_flags = 0;      msgs[i].msg_datalen = 0;
    }
    int n = (int)recvmsg_x(fd, msgs, (unsigned int)count, 0);
    for (int i = 0; i < n; i++) lengths[i] = (int)msgs[i].msg_datalen;
    return n;
}

// MARK: - Main-thread identity
// libpthread exports this (CoreFoundation uses it) but the public SDK header
// doesn't declare it. ResourceTelemetry uses it to label the main thread.
#include <pthread.h>
extern pthread_t _Nonnull pthread_main_thread_np(void);

// MARK: - Audio-configuration bit helpers
// The GameStream/Sunshine audio configuration is a packed int (channelMask <<
// 16 | channelCount << 8 | 0xCA). These mirror the function-style macros the
// protocol uses; exposed as static inlines so the Swift bridge can call them.

static inline int gl_make_audio_configuration(int channelCount, int channelMask) {
    return ((channelMask) << 16) | (channelCount << 8) | 0xCA;
}

static inline int gl_channel_count_from_audio_configuration(int x) {
    return (x >> 8) & 0xFF;
}

static inline int gl_channel_mask_from_audio_configuration(int x) {
    return (x >> 16) & 0xFFFF;
}

static inline int gl_surround_audio_info_from_audio_configuration(int x) {
    return (gl_channel_mask_from_audio_configuration(x) << 16) |
            gl_channel_count_from_audio_configuration(x);
}

// MARK: - OpenSSL BIO helpers

/// Returns the length of memory-buffered data in `bio` and writes the pointer
/// into `*out_data`. Equivalent to the `BIO_get_mem_data` macro.
static inline long gl_bio_get_mem_data(BIO * _Nonnull bio, char * _Nullable * _Nonnull out_data) {
    return BIO_ctrl(bio, BIO_CTRL_INFO, 0, (char *)out_data);
}

// MARK: - TLS minimum-version floor (control channel)
// SSL_CTX_set_min_proto_version is a macro, so Swift can't call it. Exact-DER
// cert PINNING is the security guarantee (see ControlTransport); flooring at
// TLS 1.2 just keeps the handshake off legacy protocol versions - cheap defense
// in depth. Returns 1 on success.
static inline int gl_ssl_ctx_set_min_tls12(SSL_CTX * _Nonnull ctx) {
    return SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
}

// MARK: - OpenSSL keygen wrapper
// EVP_PKEY_Q_keygen is variadic in C, which Swift refuses to import. Wrap
// the proper non-variadic RSA keygen path here.

#include <openssl/rsa.h>

static inline EVP_PKEY * _Nullable gl_rsa_keygen(int bits) {
    EVP_PKEY *pkey = NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    if (!ctx) return NULL;
    if (EVP_PKEY_keygen_init(ctx) <= 0)            goto cleanup;
    if (EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) <= 0) goto cleanup;
    EVP_PKEY_keygen(ctx, &pkey);
cleanup:
    EVP_PKEY_CTX_free(ctx);
    return pkey;
}

// MARK: - TCP connect with timeout (control channel)

static inline int64_t gl_monotonic_ms(void) {
    return (int64_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000);
}

// Connect one address, polling only until the shared deadline.
// Returns the connected non-blocking fd or -1.
static inline int gl_tcp_connect_address(const struct addrinfo * _Nonnull ai, int64_t deadline) {
    int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
    int connect_errno = errno;
    if (rc == 0) return fd;
    if (rc < 0 && connect_errno == EINPROGRESS) {
        int64_t remaining_ms = deadline - gl_monotonic_ms();
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        if (remaining_ms > 0 && poll(&pfd, 1, (int)remaining_ms) > 0 && (pfd.revents & POLLOUT)) {
            int soerr = 0;
            socklen_t slen = sizeof(soerr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0 && soerr == 0) return fd;
        }
    }
    close(fd);
    return -1;
}

// Non-blocking connect, IPv4 first (Sunshine binds IPv4 by default), within one deadline.
// Returns a blocking SO_NOSIGPIPE fd or -1. Its timeouts are the full budget, only a backstop:
// the caller cancels the request, shutting the socket down, at its own deadline.
static inline int gl_tcp_connect(const char * _Nonnull host, const char * _Nonnull port, int timeout_ms) {
    int64_t deadline = gl_monotonic_ms() + timeout_ms;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) return -1;

    int fd = -1;
    for (int pass = 0; pass < 2 && fd < 0 && gl_monotonic_ms() < deadline; pass++) {
        for (struct addrinfo *ai = res; ai && gl_monotonic_ms() < deadline; ai = ai->ai_next) {
            if ((ai->ai_family == AF_INET) != (pass == 0)) continue;
            fd = gl_tcp_connect_address(ai, deadline);
            if (fd >= 0) break;
        }
    }
    freeaddrinfo(res);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
    struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return fd;
}

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

// MARK: - CoreAudio property listener with a stable block identity
// Swift bridges a closure to a NEW block on every call, so a Swift-side remove
// never matches the added block (yet returns noErr) and the listener leaks.
// Copy once here; the returned block is the token the remove must be given.
#import <CoreAudio/CoreAudio.h>
static inline id _Nullable gl_audio_listener_add(AudioObjectID object,
                                                 const AudioObjectPropertyAddress * _Nonnull address,
                                                 dispatch_queue_t _Nullable queue,
                                                 AudioObjectPropertyListenerBlock _Nonnull block,
                                                 OSStatus * _Nonnull status) {
    AudioObjectPropertyListenerBlock held = [block copy];
    *status = AudioObjectAddPropertyListenerBlock(object, address, queue, held);
    return *status == noErr ? held : nil;
}

static inline OSStatus gl_audio_listener_remove(AudioObjectID object,
                                                const AudioObjectPropertyAddress * _Nonnull address,
                                                dispatch_queue_t _Nullable queue,
                                                id _Nonnull token) {
    return AudioObjectRemovePropertyListenerBlock(object, address, queue,
                                                  (AudioObjectPropertyListenerBlock)token);
}
#endif

// MARK: - Global mouse pointer-acceleration (relative-aim linearization)
// macOS runs even relative (associate-false) HID deltas through its pointer-
// acceleration curve before they reach kCGMouseEventDeltaX/Y, so a streamed game
// sees the Mac's acceleration STACKED on top of its own in-game sensitivity.
// Flooring the global mouse acceleration to linear while the stream window is
// focused removes the Mac curve so only the host's sensitivity shapes aim;
// MouseAccelerationControl (InputForwarder+Capture.swift) saves the prior value
// and restores it on blur/teardown. The IOHID*AccelerationWithKey pair is the
// long-standing (if deprecated) control surface; a NEGATIVE value (-1.0) is the
// "disabled / linear" sentinel - the same one `com.apple.mouse.scaling -1`
// writes. Affects MICE only (kIOHIDMouseAccelerationType); the trackpad has its
// own acceleration type and is left untouched.
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <IOKit/hidsystem/event_status_driver.h>
#include <IOKit/hid/IOHIDEventServiceKeys.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/// Read the current global mouse acceleration. Returns the value on success
/// (>= -1.0; -1.0 means the user already runs linear), or -2.0 on failure - a
/// value the API never produces, so it is an unambiguous error sentinel.
static inline double gl_get_mouse_acceleration(void) {
    NXEventHandle handle = NXOpenEventStatus();
    if (!handle) return -2.0;
    double value = -2.0;
    if (IOHIDGetAccelerationWithKey(handle, CFSTR(kIOHIDMouseAccelerationType), &value)
        != KERN_SUCCESS) {
        value = -2.0;
    }
    NXCloseEventStatus(handle);
    return value;
}

/// Set the global mouse acceleration. A negative value (e.g. -1.0) disables
/// acceleration entirely (linear 1:1). Returns 1 on success, 0 on failure.
static inline int gl_set_mouse_acceleration(double value) {
    NXEventHandle handle = NXOpenEventStatus();
    if (!handle) return 0;
    int ok = (IOHIDSetAccelerationWithKey(handle, CFSTR(kIOHIDMouseAccelerationType), value)
              == KERN_SUCCESS);
    NXCloseEventStatus(handle);
    return ok;
}
/* HIDUseLinearScalingMouseAcceleration: the System Settings "Pointer acceleration"
   switch. On = no velocity curve, Tracking Speed kept. Returns 1/0, or -1 on failure. */
static inline int gl_get_linear_mouse_scaling(void) {
    NXEventHandle handle = NXOpenEventStatus();
    if (!handle) return -1;
    CFTypeRef value = NULL;
    int result = -1;
    if (IOHIDCopyCFTypeParameter(handle, CFSTR(kIOHIDUseLinearScalingMouseAccelerationKey), &value)
        == KERN_SUCCESS && value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
            result = number != 0 ? 1 : 0;
        }
    }
    if (value) CFRelease(value);
    NXCloseEventStatus(handle);
    return result;
}
static inline int gl_set_linear_mouse_scaling(int on) {
    NXEventHandle handle = NXOpenEventStatus();
    if (!handle) return 0;
    int ok = (IOHIDSetCFTypeParameter(handle, CFSTR(kIOHIDUseLinearScalingMouseAccelerationKey),
                                      on ? kCFBooleanTrue : kCFBooleanFalse) == KERN_SUCCESS);
    NXCloseEventStatus(handle);
    return ok;
}

#pragma clang diagnostic pop

#endif
