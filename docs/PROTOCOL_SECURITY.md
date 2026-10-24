# Protocol security

Review the trust boundaries before changing pairing, commands or transport.

Review these boundaries when changing pairing, transport or local commands.

## Threat model

Treat Glimmer as a client for your own PC, not an isolation boundary against a
compromised Mac or PC.

| Threat                                       | Protection or limit                                                                                                      |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Someone observing the network                | Input is encrypted; video is plaintext unless Sunshine requires encryption. Audio encryption has protocol limits below.  |
| Someone intercepting connections             | PIN-verified pairing establishes a certificate pin; later certificate mismatches fail. First contact is unauthenticated. |
| Malicious paired PC                          | Pairing proves identity, not safe data. Protocol-parser bugs belong to Glimmer and should be reported here.              |
| Software running as your Mac user            | Can read identity files, replace pins and send local commands. Owner-only permissions do not stop it.                    |
| Root, a compromised macOS or build toolchain | Outside the protection model. Nation-state attacks are also outside scope.                                               |

Sunshine protocol-design limits are documented below. Bugs in
[Sunshine itself](https://github.com/LizardByte/Sunshine) belong upstream.

## Local commands and links

Distinguish local automation from links that can arrive through a browser.

| Entry point           | Boundary                                                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local command channel | Distributed notifications are unauthenticated. Software running as you can start or end streams, quit PC apps and authorize takeover. CLI/UI confirmation happens before dispatch.     |
| `glimmer://` links    | Stream, wake, quit and stop for saved PCs; stop may omit the PC. Quit always asks; stream uses normal takeover checks. Stop ends the local stream and its PC app without confirmation. |
| Malformed links       | Unknown or duplicate parameters, empty/control-character values, paths, credentials, ports and fragments are rejected without logging their contents.                                  |

See [URL commands](COMMAND_LINE.md#url-commands). There is no pair URL action.

## Identity

Protect your Mac account and the files under
`~/Library/Application Support/Glimmer/Identity/`.

| File                  | Contents                                                     |
| --------------------- | ------------------------------------------------------------ |
| `client-cert.pem`     | Self-signed RSA-2048 client certificate, valid for 20 years. |
| `client-key.pem`      | Unencrypted PKCS#8 private key.                              |
| `client-uniqueid.txt` | 32-character hexadecimal client ID.                          |

Files use mode 0600 in a mode-0700 directory. Writes are atomic and verify
permissions; failures remove the partial file. The identity is file-backed, not
in the keychain, and software running as you can read it.

On first launch, Glimmer can import moonlight-qt's identity and pairings. It
never changes Moonlight's preferences or their permissions. The one-time import
does not create a stronger boundary around Moonlight's original copy.

## Pairing

Enter Glimmer's four-digit PIN in Sunshine only on a trusted network or
authenticated encrypted tunnel.

Do not expose Sunshine's pairing or streaming ports directly to the internet.
Four-digit PINs have about 13 bits of entropy; retry handling does not establish
resistance to offline guessing of a captured handshake.

Glimmer checks the PC's RSA signature and PIN proof before sending its own
pairing secret and committing the pin. Imported identities, pairing certificates
and pinned peers need RSA keys of at least 2048 bits. Rejected keys and
certificates are not silently replaced; fix them at the source and re-pair.

### Protocol limits

Use Sunshine's mandatory encryption mode for video, while recognizing what it
cannot fix.

| Mechanism           | Limit                                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Pairing AES-128-ECB | Protocol-required, unauthenticated cipher; signatures and challenge checks supplement it.                                               |
| Audio AES-128-CBC   | No authentication tag; IVs derived from the session value and 16-bit sequence repeat on wrap. Padding checks do not authenticate audio. |
| TLS 1.2 minimum     | Glimmer does not require an ephemeral key agreement suite, so forward secrecy is not guaranteed.                                        |
| GCM counters        | Direction/channel-specific deterministic IVs must stay unique under each fresh session key.                                             |

CryptoKit, CommonCrypto and Security provide the cryptography. Random keys,
salts and challenges use system cryptographic generators. See
[NIST's GCM IV guidance](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf#page=28).
These constraints are not a claim of a newly demonstrated Glimmer exploit.

## Pinning

Choose “Pair again…” after confirming a legitimate certificate change on the PC.

A mismatch fails the connection and shows “Trust needed”. Glimmer does not
silently replace a pin. TLS compares the PC's exact certificate bytes, with
session resumption disabled; the system certificate authorities are not the
trust anchor.

Pins live in `~/Library/Application Support/Glimmer/PinnedHosts/<hostID>.pem` at
mode 0600. IDs are sanitized to `[A-Za-z0-9-_.]`. The file wins; a missing or
unreadable file falls back to the legacy defaults pin and attempts migration. A
conflicting or unmigratable PC-record pin requires re-pairing.

Plain-HTTP discovery data cannot establish trust: `<PlainCert>` and
`<PairStatus>` from `/serverinfo` are ignored before pairing, and HTTPS without
a pin is refused.

## Transport

Use the table to see which parts of a session are encrypted.

| Path              | Protection                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------------ |
| Before pairing    | HTTP on 47989; four pairing rounds, then a final HTTPS liveness check.                                 |
| Paired requests   | Mutual TLS on 47984 for status, app lists, artwork, launch and cancellation; session keys travel here. |
| RTSP setup        | AES-128-GCM over TCP with `rtspenc://`; unencrypted replies are rejected.                              |
| Control and input | AES-128-GCM over ENet/UDP in both directions.                                                          |
| Video             | UDP, plaintext by default; AES-128-GCM when Sunshine requires encryption.                              |
| Audio             | UDP, AES-128-CBC whenever offered, as current Sunshine does.                                           |

Video and audio check the resolved PC's source IP, allowing varying source
ports. This rejects unrelated senders but does not authenticate plaintext
packets or prevent IP spoofing. Encryption cannot stop packets being dropped or
delayed.

### Network paths

Use this list for the connections outside the media stream.

| Path                      | Exposure and check                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Bonjour discovery         | Unauthenticated `_nvstream._tcp` and `_nvstream-tcp._tcp`; a discovered address is saved only after pinned HTTPS confirms the PC's ID. |
| Reachability probe        | TCP connect to the PC's HTTP port, no payload; status can be forged, trust cannot.                                                     |
| Stream keepalives         | Unencrypted UDP ping identifiers, no keys or input.                                                                                    |
| Wake on LAN               | Unauthenticated UDP magic packets, including ports 9 and 47009 and Sunshine ports; the PC's MAC address is visible.                    |
| Updates                   | HTTPS feed and GitHub downloads; each ZIP has an Ed25519 signature. The feed is unsigned.                                              |
| Optional metrics listener | HTTP port 9847 on loopback; a separate LAN opt-in allows anyone on the network to read metrics.                                        |

Glimmer makes no analytics or tracking calls. See [Privacy](PRIVACY.md).

## Runtime hardening

Approve the optional root helper knowing that Glimmer itself runs without App
Sandbox.

| Boundary             | What it does                                                                                                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Wi-Fi helper         | Root LaunchDaemon through `SMAppService.daemon`; pauses `awdl0` during a stream.                                         |
| Helper authorization | Requires the signed `io.ugfugl.Glimmer` app from Apple team `5T7M4RH3F8`, not just a claimed bundle ID.                  |
| Helper API           | Only `setAWDLDown(_:reason:)` changes state; status, ping and suppression count are read-only. No arbitrary-command API. |
| Release runtime      | Hardened Runtime, no JIT or library injection, library validation enabled.                                               |
| Distribution         | Developer ID signing, Apple notarization and a stapled ticket on the app.                                                |
| Parser checks        | Deterministic fuzz tests and coverage-guided fuzzing under AddressSanitizer; neither contains a successful exploit.      |

The current helper architecture is unsandboxed. USB access alone does not
require that choice; a sandboxed distribution would need a separate architecture
review. Debug builds relax library validation for unsigned instrumentation;
Release does not.

### Capabilities and capture

Check the separate app and helper grants when reviewing a signed build.

| Bundle       | Capabilities                                                                                                                  |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| App          | Head Pose and Spatial Audio Profile for system spatial playback; Enhanced Security for heap, platform and loader protections. |
| Root helper  | Network Topology Observation for routing-socket observation under macOS 27; does not grant root or replace approval.          |
| Login helper | Neither audio capability.                                                                                                     |

Enhanced Security version 1 remains selected while version 2's streaming costs
are unmeasured. It is a macOS 26 protection: on macOS 15 the same signed app
runs with the hardened runtime and library validation, but without the hardened
heap, read-only loader state or platform restrictions. Pinned TLS, the protocol
bounds checks and the root helper's approval model are identical on both.
Profiles are validated and embedded separately; see [Release](RELEASE.md).
Glimmer never reads or exports raw head-pose or profile data.

The stream window's legacy capture hint does not block ScreenCaptureKit. Your
stream can appear in screen recordings or shares; Glimmer provides no DRM
boundary.
