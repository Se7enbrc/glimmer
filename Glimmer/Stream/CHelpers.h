//
//  CHelpers.h
//
//  Tiny C shims that Swift can't express directly: audio-configuration bit
//  helpers and OpenSSL macro/variadic wrappers. Imported via the bridging
//  header so all Swift sources can call these.

#ifndef Glimmer_Stream_CHelpers_h
#define Glimmer_Stream_CHelpers_h

#include <stdint.h>
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

// MARK: - Batched UDP receive (recvmsg_x)
// `recvmsg_x` is Darwin's batched datagram receive (the macOS analogue of
// Linux's recvmmsg; used internally for QUIC). It reads MANY datagrams in one
// syscall - at 4K240 the video socket sees ~14k packets/s, and one recvfrom per
// packet is a large share of process CPU (issue #24). The public SDK ships only
// the syscall NUMBER, not a prototype or `struct msghdr_x`, so we declare both
// here. We use a gl_-prefixed struct name so a future SDK that exposes the real
// `struct msghdr_x` can't collide; the kernel only cares about the byte layout,
// which mirrors xnu's bsd/sys/socket.h exactly.
struct gl_msghdr_x {
    void          *msg_name;        /* optional address */
    socklen_t      msg_namelen;     /* size of address */
    struct iovec  *msg_iov;         /* scatter/gather array */
    int            msg_iovlen;      /* # elements in msg_iov */
    void          *msg_control;     /* ancillary data */
    socklen_t      msg_controllen;  /* ancillary data buffer len */
    int            msg_flags;       /* flags on received message */
    size_t         msg_datalen;     /* byte length of buffer in msg_iov */
};
extern ssize_t recvmsg_x(int s, const struct gl_msghdr_x *msgp, unsigned int cnt, int flags);

/// Read up to `count` (<=64) datagrams from `fd` in one `recvmsg_x` syscall into
/// `storage` (count * stride bytes), writing each datagram's length into
/// `lengths[i]`. Returns the number of datagrams received, or -1 with errno set
/// (EAGAIN/EWOULDBLOCK on timeout, like recvfrom). All `msghdr_x` plumbing stays
/// in C so the layout is correct by construction; Swift sees a flat API.
static inline int gl_recvmsg_x_batch(int fd, uint8_t *storage, int stride,
                                     int count, int *lengths) {
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
static inline long gl_bio_get_mem_data(BIO *bio, char **out_data) {
    return BIO_ctrl(bio, BIO_CTRL_INFO, 0, (char *)out_data);
}

// MARK: - OpenSSL keygen wrapper
// EVP_PKEY_Q_keygen is variadic in C, which Swift refuses to import. Wrap
// the proper non-variadic RSA keygen path here.

#include <openssl/rsa.h>

static inline EVP_PKEY *gl_rsa_keygen(int bits) {
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
// Plain connect() has no timeout knob, so a dead host would hang the control
// request until the OS default (~75s). We do a non-blocking connect + poll so it
// fails fast. On success the socket is returned in BLOCKING mode with
// SO_RCVTIMEO/SO_SNDTIMEO set to the same deadline, so the TLS handshake and HTTP
// read/write that follow on this fd inherit the bound. Returns the fd, or -1.
// `host` may be a hostname or a numeric IP; `port` is the decimal string.
static inline int gl_tcp_connect(const char *host, const char *port, int timeout_ms) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) return -1;

    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) goto connected;
        if (rc < 0 && errno == EINPROGRESS) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
            if (poll(&pfd, 1, timeout_ms) > 0 && (pfd.revents & POLLOUT)) {
                int soerr = 0;
                socklen_t slen = sizeof(soerr);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0 && soerr == 0) goto connected;
            }
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return -1;

connected:
    freeaddrinfo(res);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
    struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return fd;
}

#endif
