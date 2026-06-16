# Security

## Reporting

**Security contact: GitHub Security Advisories.** Use the repository's
**Security → Report a vulnerability** flow (private vulnerability reporting) -
it is end-to-end private between you and the maintainer, needs no key exchange,
and is the channel that is actually monitored. Include a description of the
issue, reproduction steps, and the affected version (`Glimmer.app` → menu bar →
About, or
`defaults read /Applications/Glimmer.app/Contents/Info CFBundleShortVersionString`).

Public disclosure on GitHub Issues is acceptable for non-exploitable bugs (UI
glitches, build failures, etc.). Anything involving the client identity, the
pairing handshake, host-cert pinning, the stream-transport parsers, or the
sandbox / Hardened Runtime posture should go through a private advisory first.

## Threat model

Glimmer is a home-LAN game-streaming client. The audience is a user streaming
from their own gaming PC to their own Mac on their own network. The threat model
is sized to that.

**In scope:**

- **Same-LAN passive observer** - packet sniffer on the LAN. The control channel
  runs mutual TLS post-pairing; the video / audio / input streams are
  AES-128-GCM encrypted end-to-end under `EncryptionPreference.all`, which is
  the default (see `Glimmer/Stream/Types.swift`).
- **Same-LAN active MITM** - an attacker who can intercept or redirect traffic
  between the Mac and the host. Defended by RSA-validated pairing handshake +
  post-pairing cert pinning (see Pairing + Pinning sections below). Pre-pairing
  first contact is HTTP, which is acceptable because there's nothing to MITM yet
  - the pin is established by an out-of-band PIN the user types into the host's
    UI, which is what authenticates the cert we then pin.
- **Same-UID malware on the Mac** - partially defended. The App Sandbox +
  Hardened Runtime (enabled) means another app under the same user UID cannot
  read Glimmer's container by default. A TCC-allowlisted attacker with Full Disk
  Access still wins; that's an OS-level boundary, not a Glimmer-specific
  defence.
- **Hostile host** - a host that has somehow been compromised cannot escalate
  beyond producing bad video / audio / input echoes. The pinned-cert pairing
  limits a hostile host to one the user has explicitly trusted out-of-band.
- **Untrusted stream input - the in-tree Swift transport parsers.** The
  streaming engine is pure Swift (`Glimmer/Stream/Native/`): RTSP/SDP response
  parsing, the ENet-subset control channel, RTP video/audio depacketization,
  Reed-Solomon FEC reassembly, and AES-GCM decrypt all parse bytes that arrive
  over UDP/TCP from the network. Memory-safety bugs, parser confusion, and
  malformed-packet crashes in these parsers are **in scope and ours** - report
  them here, not upstream. (Earlier revisions delegated this surface to a linked
  `moonlight-common-c` C library; that library is gone - the parsing is
  Glimmer's own code now, ported from it.)

**Out of scope:**

- Nation-state attackers.
- Supply-chain compromise of the build toolchain (homebrew `openssl@3`, Xcode).
- Kernel-level attackers / a hostile macOS install.
- Local attacker with root. Nothing to defend; they already have everything.
- Protocol-design limitations fixed by GameStream / Sunshine (e.g. the 4-digit
  PIN, plain-HTTP pre-pairing rounds) - we implement the protocol's defenses
  faithfully but cannot change the wire contract. Bugs in
  [Sunshine](https://github.com/LizardByte/Sunshine) itself belong upstream.

## Identity

Per-machine RSA-2048 client identity, generated on first launch, 20-year
self-signed cert with CN `NVIDIA GameStream Client` (the standard GameStream
client identifier; moonlight-qt uses the same).

**Storage: mode-0600 files**, not the keychain. Three files:

- `client-cert.pem` - X.509 cert in PEM
- `client-key.pem` - RSA private key in PEM (PKCS#8 unencrypted)
- `client-uniqueid.txt` - 32-hex-char client unique ID

Post-sandbox (current state):
`~/Library/Containers/io.ugfugl.Glimmer/Data/Library/Application Support/Glimmer/Identity/`.

Pre-sandbox (legacy): `~/Library/Application Support/Glimmer/Identity/`.
Migration is **not** automatic - the sandboxed container cannot read the legacy
path, and adding a temporary-exception read would expand the path-traversal
surface for a same-UID attacker. Users on a pre-sandbox build re-pair each host
once after upgrading. 30-second task per host.

`FileIdentityStore.write` (`Identity.swift`):

- Atomic write via `Data.write(options: [.atomic])` so a crash mid-write cannot
  leave a torn PEM on disk.
- `setAttributes([.posixPermissions: 0o600])` then `stat`-verify the permission
  bits stuck. Some FUSE / NFS backends silently ignore `chmod`; if the
  verification fails, the partial file is deleted and the call throws.
  Half-written secrets on a too-permissive filesystem are worse than no file at
  all.
- Parent directory created at mode 0700.

**Future: Developer ID + data-protection keychain.** The `Identity.swift`
top-of-file comment documents the planned switch. The data-protection keychain
(per-bundle-id container, doesn't show in Keychain Access.app) doesn't have the
CDHash-ACL prompt that breaks adhoc-signed rebuilds - but it requires a stable
Team ID, which means a Developer ID-signed bundle. The current adhoc-signed
state can't use it without a "Glimmer wants to use its key" prompt on every
rebuild. Files for now.

**One-shot moonlight-qt migration.** On first launch, Glimmer reads the
`com.moonlight-stream.Moonlight` and `com.moonlight-stream.moonlight-qt`
preference domains (via the sandbox temporary-exception entitlement). If a
moonlight-qt install left a client identity + paired-host list, we adopt it so
the user doesn't have to re-pair. After successful migration the PEM material in
the foreign plist is wiped (it sat in a world-readable plist before -
moonlight-qt's storage is not 0600). Idempotent; dormant after the first run.

## Pairing

The GameStream PIN handshake. Protocol-fixed by GameStream / Sunshine; we don't
get to pick the primitives. Five HTTP rounds plus a final HTTPS liveness check
(`Glimmer/Stream/Pairing.swift`).

**Primitives:**

- AES-128-ECB on raw 16-byte buffers, no padding (the protocol pre-sizes
  everything to 16-byte multiples).
- Key derivation: `SHA-256(salt || PIN)[0..16]` for Gen 7+ (modern GFE and all
  Sunshine). SHA-1 for pre-Gen-7 GFE; sniffed from `appversion`. We don't expect
  to encounter SHA-1 on Sunshine.
- RSA-2048 signatures using the long-lived client cert / host cert for the MITM
  check and the PIN-correctness check.

**PIN entropy.** 4 digits, generated client-side via
`MoonlightManager.generatePairingPIN()` and shown to the user to type into the
host. ~13 bits. Brute-force isn't a worry: the host controls the retry rate and
a wrong PIN aborts the handshake mid-round (the host returns a hash that doesn't
match the one our PIN would have produced - see step 4 in `runPairingFlow`).

**Pin commit timing.** The host cert is pinned AFTER:

1. The host's RSA signature over its pairing-secret block verifies against the
   cert it sent us in step 1 - proves the host holds the private key matching
   the cert.
2. The PIN-correctness hash check passes - proves the host knew the PIN the user
   typed out-of-band.

Only then does `NetworkClient.setPinnedHostCert` get called. This is **not**
trust-on-first-use: `NetworkClient.fetchServerInfo` will NOT auto-pin on first
contact. The previous "auto-pin on first /serverinfo" behaviour was the
canonical same-LAN-attacker-rides-an-induced-TLS-error gap; closed in the same
refactor that moved the pin into the pairing flow (search for `SECURITY (C2)` in
`Network.swift`).

**Failure path.** Any deviation throws `StreamError.pairingFailed` with a
specific message at `.private` log privacy. The caller sees a uniform "pairing
failed" - the specific cause (wrong PIN, MITM detected, host mid-pair with
someone else) is recoverable from logs under our subsystem, not from the UI. We
send `/unpair` after a failure to clear the host's "Already pairing" state for
retry.

## Pinning

Host certs are pinned **after** successful pairing. The pin lives in a mode-0600
file under the sandbox container at
`~/Library/Containers/io.ugfugl.Glimmer/Data/Library/Application Support/Glimmer/PinnedHosts/<hostUUID>.pem`
(moved out of `UserDefaults` because `cfprefsd` is shared across same-UID
processes - any other process running as the user could rewrite a pin through
the preferences daemon). PEM, not raw `SecCertificate` - PEM survives keychain
wipes, OS migrations, and Time Machine restores in a way the `SecCertificate`
ref does not. The cert is public information; the threat addressed by
mode-0600 + container isolation is _write_, not _read_.

**Once pinned, ANY mismatch fails the connection.** The TLS delegate
(`Network.swift:TLSDelegate.urlSession(_:didReceive:completionHandler:)`)
refuses the handshake if the leaf cert doesn't byte-equal the pinned PEM. We do
NOT silently re-pin on TLS error. The previous auto-rebind-on-TLS-error path was
the gap a same-LAN attacker rode to pin their own cert - closed.

A real cert rotation (Sunshine reinstall, OS reset on the host) lands the user
on a loud `hostUnreachable` error directing them to **Settings → PCs → Compare
fingerprints...**. That action does **not** wipe the pin - it stages a
comparison.

**Fingerprint UX**. The `FingerprintCompareSheet` shows the OLD pinned cert's
SHA-256 fingerprint and the NEW cert's fingerprint side-by-side. Both are
formatted as lowercase hex with colon separators (`ab:cd:ef:...` - same shape as
`ssh-keygen -E sha256 -lf`). Each fingerprint has a copy button. The body text
explicitly directs the user to verify with the host owner via a secure channel
(phone call, in person) before continuing - if the fingerprints don't match and
the user can't reach the owner, the safe action is to cancel. The accept button
uses SwiftUI's `.destructive` role to visually signal the irreversible nature of
trusting a new key. While the new fingerprint is being fetched the row shows
`Probing...`; if the host is unreachable it shows `<could not reach host>` -
both states keep the accept button disabled so the user can't trust an empty
fingerprint. Bound through `MoonlightManager.pendingFingerprintCheckHost` /
`probedNewFingerprint`; staging/confirming/cancelling goes through
`stage/confirm/cancelTrustNewCertAndRepair`. The friction is deliberate - the
alternative is "the on-path attacker rotates the cert for them".

## Transport

- **Pre-pairing:** plain HTTP on **47989** for `/serverinfo` and the five
  pairing rounds. There's no TLS to validate yet; the out-of-band PIN
  authenticates the cert we then pin.
- **Post-pairing:** HTTPS on **47984** for `/serverinfo`, `/launch`, `/resume`,
  `/cancel`, `/applist`, and the final pairing-flow `/pair?phrase=pairchallenge`
  liveness check. Mutual TLS - our client identity authenticates us to the host,
  the pinned host cert authenticates the host to us. The system trust store is
  NOT consulted; the pinned PEM is the entire trust anchor.
- **Stream:** the Swift-native engine's RTP video/audio + ENet-subset control
  channels (`Glimmer/Stream/Native/`). AES-128-GCM, key derived from the launch
  response's `rikey` (or `gcmkey` on Sunshine). `EncryptionPreference.all` is
  the default - encrypts video, audio, and input. `.audioOnly` encrypts audio +
  input but leaves video plaintext (saves bandwidth on slower CPUs at the cost
  of clear-text frame data on the wire); `.none` is exposed for diagnostics, not
  recommended.

## Runtime hardening

Enabled.

- **App Sandbox** (`com.apple.security.app-sandbox = true`): process
  containment. Filesystem writes are confined to the container
  (`~/Library/Containers/io.ugfugl.Glimmer/`); arbitrary IPC is blocked; reads
  outside the container require user grants via NSOpenPanel.
- **Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES`): no JIT, strict library
  validation, no library injection. Xcode emits a note that the runtime is
  disabled under adhoc signing - that's expected for development; the setting
  persists so Developer ID signed Release builds get the full enforcement.

**Entitlements** (`Glimmer/Glimmer.entitlements`):

| Key                                                | Value                                           | Why                                                                                               |
| -------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `app-sandbox`                                      | true                                            | Process containment.                                                                              |
| `network.client`                                   | true                                            | LAN connection to GameStream / Sunshine hosts.                                                    |
| `network.server`                                   | true                                            | mDNS / Bonjour discovery (`_nvstream._tcp`).                                                      |
| `files.user-selected.read-write`                   | true                                            | Future config-import flows via NSOpenPanel. No pre-grant.                                         |
| `device.audio-input`                               | false                                           | Explicit no-mic posture.                                                                          |
| `cs.disable-library-validation`                    | false                                           | Strict - system libs + the embedded OpenSSL/Opus dylibs (re-signed with the app's identity) only. |
| `cs.allow-jit`                                     | false                                           | No JIT.                                                                                           |
| `temporary-exception.shared-preference.read-write` | `com.moonlight-stream.{Moonlight,moonlight-qt}` | One-shot identity migration + post-migration PEM wipe.                                            |

**NSWindow.sharingType** = `.none`. The stream window opts out of
ScreenCaptureKit, `screencapture(1)`, and Cmd-Shift-5. Third-party recording /
conferencing apps (QuickTime, OBS, Loom, Zoom, Teams) see a black surface where
the stream is - same posture as Apple TV+ and Netflix. Users who want to record
their session use the host PC's recording tools, not the Mac's.

## Sensitive material - what we don't log

- **Key characters from `keyDown` events.** Removed; previously logged at
  `.public`, leaked every keystroke (including passwords typed during a stream)
  into the unified log. We log `keyCode` (positional, non-PII) and the modifier
  mask only.
- **URLs containing `rikey`, `rikeyid`, `gcmkey`, `gcmkeyid`, host UUIDs.** The
  redaction helper in `Network.swift` strips them before logging.
- **Cert PEMs / fingerprints at `.public`.** The TLS delegate logs a
  pin-mismatch event but not the fingerprints - a hostile log scraper could
  otherwise read the pinned cert via `log show`.
- **PIN values, AES keys, signed pairing-secret bytes.**

## Sensitive material - what we do log

- Scan codes + modifier masks (positional, non-PII; needed for responder-chain
  debugging).
- Network errors with sanitized URLs (rikey/gcmkey stripped).
- VT decode errors and codec configuration ints (`videoFormat=0x...`, `bytes=N`,
  `idr=true/false`).
- Host addresses at `.private` privacy (default).
- Pin-mismatch events (no fingerprints).
- Pairing-step transitions (no payload data).

## Disclosure timeline

- **Day 0:** report received. Acknowledgement within 72 hours.
- **Day 7:** initial assessment and severity shared with reporter.
- **Day 30:** fix landed in `main`, or a written explanation of why it's taking
  longer.
- **Day 90:** public disclosure, whether or not a fix has shipped. Earlier if
  the reporter prefers and a fix is in place.

Credit in the release notes unless the reporter asks otherwise.
