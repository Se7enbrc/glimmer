# Security

## Reporting

**Security contact: GitHub Security Advisories.** Use the repository's
**Security → Report a vulnerability** flow. GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately)
shares the report privately with repository maintainers. This is the monitored
channel. Include a description of the issue, reproduction steps, and the
affected version (**Glimmer → About Glimmer**, or
`defaults read /Applications/Glimmer.app/Contents/Info CFBundleShortVersionString`).

Public disclosure on GitHub Issues is acceptable for non-exploitable bugs (UI
glitches, build failures, etc.). Anything involving the client identity, the
pairing handshake, host-cert pinning, the stream-transport parsers, the
privileged AWDL helper, or the Hardened Runtime posture should go through a
private advisory first.

## Threat model

Glimmer is a home-LAN game-streaming client. The audience is a user streaming
from their own gaming PC to their own Mac on their own network. The threat model
is sized to that.

**In scope:**

- **Same-LAN passive observer:** a packet sniffer on the LAN. The HTTP control
  requests run mutual TLS once paired. In the stream itself, the ENet control
  channel, which also carries keyboard, mouse and controller input, is
  AES-128-GCM encrypted, and audio is AES-128-CBC encrypted whenever the PC
  offers it (Sunshine always does). Video travels unencrypted unless the PC is
  set to require encryption, and then it is AES-128-GCM too.
- **Same-LAN active MITM:** an attacker who can intercept or redirect traffic
  between the Mac and the host. Defended by RSA-validated pairing handshake +
  post-pairing cert pinning (see Pairing + Pinning sections below). Pre-pairing
  first contact is HTTP, which is acceptable because there's nothing to MITM
  yet: the pin is established by an out-of-band PIN the user types into the
  host's UI, which is what authenticates the cert we then pin.
- **Same-UID malware on the Mac:** not defended. Glimmer is unsandboxed (see
  Runtime hardening below for why), so the identity and pinned-cert files live
  in the home directory at mode 0600 / parent dir 0700 rather than inside a
  sandbox container. Mode 0600 keeps other users on the Mac out, but any process
  running as you can read the client key, impersonate this Mac to every paired
  PC, and rewrite the pinned host certificates. This is an accepted risk that
  moonlight-qt shares.
- **Local control surface:** the running app takes `glimmer` requests over
  distributed notifications (`CommandChannel`, `AppModel+Commands.swift`), with
  no authentication. Any process running as you can post one: start a stream
  from a paired PC, end Glimmer's own stream, or post `stream` with takeover
  set, which quits the app running on the PC without asking. There is no URL
  scheme, so a web page can't reach it. This falls under the same-UID risk
  above.
- **Hostile host:** pairing authenticates the PC, not the safety of its data. A
  compromised paired PC can attack the parsers below. Pinning limits which PC is
  trusted; it does not contain a successful parser exploit.
- **Untrusted stream input: the in-tree Swift transport parsers.** The streaming
  engine is pure Swift (`Glimmer/Stream/Native/`): RTSP/SDP response parsing,
  the ENet-subset control channel, RTP video/audio depacketization, Reed-Solomon
  FEC reassembly, and the AES-GCM control and AES-CBC audio decrypts all parse
  bytes that arrive over UDP/TCP from the network. Memory-safety bugs, parser
  confusion, and malformed-packet crashes in these parsers are **in scope and
  ours**: report them here, not upstream.

**Out of scope:**

- Nation-state attackers.
- Supply-chain compromise of the build toolchain (Xcode).
- Kernel-level attackers / a hostile macOS install.
- Local attacker with root. Nothing to defend; they already have everything.
- Protocol-design limitations fixed by GameStream / Sunshine (e.g. the 4-digit
  PIN, plain-HTTP pre-pairing rounds). We implement the protocol's defenses
  faithfully but cannot change the wire contract. Bugs in
  [Sunshine](https://github.com/LizardByte/Sunshine) itself belong upstream.

## Identity

Per-machine RSA-2048 client identity, generated on first launch, 20-year
self-signed cert with CN `NVIDIA GameStream Client` (the standard GameStream
client identifier).

**Storage: mode-0600 files**, not the keychain. Three files:

- `client-cert.pem`: X.509 cert in PEM
- `client-key.pem`: RSA private key in PEM (PKCS#8 unencrypted)
- `client-uniqueid.txt`: 32-hex-char client unique ID

Stored at `~/Library/Application Support/Glimmer/Identity/`.

`FileIdentityStore.write` (`Identity.swift`):

- Atomic write via `Data.write(options: [.atomic])` so a crash mid-write cannot
  leave a torn PEM on disk.
- `setAttributes([.posixPermissions: 0o600])` then `stat`-verify the permission
  bits stuck. Some FUSE / NFS backends silently ignore `chmod`; if the
  verification fails, the partial file is deleted and the call throws.
  Half-written secrets on a too-permissive filesystem are worse than no file at
  all.
- Parent directory created at mode 0700.

**Why files, not the keychain (a deliberate call).** We evaluated moving to the
keychain once builds became Developer ID signed, and stayed on files:

- The **data-protection keychain** needs profile-authorized access groups.
  Earlier builds did not carry provisioning profiles. The audio and hardening
  capabilities now require profiles, removing that historical packaging
  obstacle; they do not migrate the pairing identity or authorize keychain
  groups by themselves.
- The **login keychain** works without a profile and, now that signing is stable
  (Developer ID), no longer hits the per-rebuild ACL prompt that drove us off it
  before. But it only adds encryption-at-rest for a narrow gain on a LAN
  streaming identity, and the project already tried it once and retreated.
- The reference implementation (**moonlight-qt**) stores the same RSA key as
  **plaintext PEM in a mode-0644 QSettings plist** under
  `~/Library/Preferences`, no keychain at all. Glimmer's mode-0600 home files
  are already stricter: only the owning UID can read them, and 0600 beats 0644.

The residual exposure is any process running as the same user: 0600 does not
stop it from copying the key or rewriting a pin. Only a sandbox or the
data-protection keychain would, and both are ruled out above. The reference
implementation has the same exposure.

**One-shot moonlight-qt migration.** On first launch, Glimmer reads the
`com.moonlight-stream.Moonlight` preference domain. If a moonlight-qt install
left a client identity and a paired-host list there, we adopt both so the user
doesn't have to re-pair. The copy is one-way and read-only: Glimmer never writes
to the foreign plist, so moonlight-qt keeps its own identity and its own
pairings. Moonlight's storage is not 0600 and Glimmer cannot change that on its
behalf; what Glimmer controls is its own copy, which lands in the mode-0600 file
store described above. Idempotent, version-gated, and dormant after the first
run. See `Identity+Loading.swift` and `HostsStore.swift`.

## Pairing

The GameStream PIN handshake. Protocol-fixed by GameStream / Sunshine; we don't
get to pick the primitives. Four HTTP rounds plus a final HTTPS `pairchallenge`
liveness check (`Glimmer/Stream/Pairing.swift`).

**Primitives:**

- AES-128-ECB on raw 16-byte buffers, no padding (the protocol pre-sizes
  everything to 16-byte multiples).
- Key derivation: `SHA-256(salt || PIN)[0..16]`, and SHA-256 for the challenge
  hashes, as every Sunshine build uses. A GameStream PC is refused before the
  handshake starts.
- RSA signatures using the long-lived client cert / host cert for the MITM check
  and the PIN-correctness check. Both keys must be RSA with at least 2048 bits.
  Glimmer checks imported identities, pairing certificates and pinned TLS peers;
  a valid signature alone does not make a weak key acceptable.

**PIN entropy.** 4 digits, generated client-side via
`AppModel.generatePairingPIN()` and shown to the user to type into the host. ~13
bits. A wrong PIN aborts the handshake, and the host controls online retries.
Neither fact makes a four-digit PIN a high-entropy secret or establishes
resistance to offline guessing of a captured handshake. Pair on a trusted
network, or carry the connection through an authenticated encrypted tunnel. Do
not expose Sunshine's pairing or streaming ports directly to the internet.

**Protocol limits.** Current Sunshine requires AES-128-ECB for pairing and
AES-128-CBC for encrypted audio. Glimmer cannot replace those modes without
changing the host protocol. ECB reveals repeated plaintext blocks; it is not
authenticated encryption. The pairing handshake adds signature and challenge
checks, but those do not turn ECB into an authenticated cipher.

Audio CBC has no authentication tag. Its protocol IV is derived from a session
value and the 16-bit RTP sequence number, so IVs repeat when that sequence wraps
under the same session key. Rejecting malformed packets and invalid padding does
not authenticate audio. A trusted network or authenticated encrypted tunnel
reduces exposure to observation and packet injection. Sunshine's mandatory
encryption mode protects video too, but does not upgrade pairing ECB or audio
CBC. These limitations are not claims of a newly demonstrated exploit in
Glimmer.

Glimmer delegates RSA to Security, AES-CBC/ECB to CommonCrypto, and AES-GCM to
CryptoKit. Random key material, pairing salt and challenges use the system's
cryptographically secure generators. GCM uses the protocol's deterministic
counter IVs with separate direction/channel identifiers, as permitted by
[NIST SP 800-38D, section 8.2.1](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf).
Unique IVs under each fresh session key are required; they need not be random.
Fresh session keys do not by themselves establish forward secrecy. Glimmer sets
a TLS 1.2 minimum but does not require an ephemeral key agreement suite.

Rejected identities and certificates are not replaced automatically. An
unsupported imported identity stays in its original store, and a rejected PC
certificate does not overwrite an existing pin. Resolve weak keys on the
originating client or PC and re-pair deliberately.

**Pin commit timing.** The host cert is pinned AFTER:

1. The host's RSA signature over its pairing-secret block verifies against the
   cert it sent us in step 1. This proves the host holds the private key
   matching the cert.
2. The PIN-correctness hash check passes. This proves the host knew the PIN the
   user typed out-of-band.

Only then does `NetworkClient.setPinnedHostCert` get called. This is **not**
trust-on-first-use: first contact never pins. `NetworkClient.fetchServerInfo`
ignores the `<PlainCert>` and `<PairStatus>` a plain-HTTP `/serverinfo` returns,
so a device answering port 47989 can neither plant a pin nor skip the PIN, and
every pairing runs the full handshake. `NetworkClient` also refuses any HTTPS
request that has no pin to check (search for `SECURITY (C2)` in
`NetworkClient+Endpoints.swift`).

**Failure path.** Any deviation throws `StreamError.pairingFailed` with a
specific message at `.private` log privacy. The caller sees a uniform “pairing
failed”; the specific cause (wrong PIN, MITM detected, host mid-pair with
someone else) is recoverable from logs under our subsystem, not from the UI. The
causes the UI does name reveal nothing about the handshake: a PIN nobody entered
in time (our five-minute wait, or Sunshine's status 408), and a PC busy with
another open pairing request (409 or 503). Sunshine has no `/unpair` route, so
an open request ends only when it completes, fails or expires.

## Pinning

Host certs are pinned **after** successful pairing. The pin lives in a file at
`~/Library/Application Support/Glimmer/PinnedHosts/<hostID>.pem`, where `hostID`
is the host's UUID (or its hostname, when that is all we have) with anything
outside `[A-Za-z0-9-_.]` replaced by `_`. `PinnedCertStore` (`Types+Cert.swift`)
owns it.

That file is the only pin source because our pairing flow is what writes it,
after the RSA-verified handshake, not because of its file mode: mode 0600 keeps
other users out, but any process running as the same user can write it, just as
it can rewrite `UserDefaults`. The copy older builds kept in `UserDefaults`
(`hosts.N.srvcert`) is only a one-way migration hint, and if the two ever
disagree the connection is refused and the PC must be paired again. Pins are
stored as PEM rather than a raw `SecCertificate`, because PEM survives keychain
wipes, OS migrations, and Time Machine restores in a way the `SecCertificate`
ref does not. The cert is public information, so a pin needs integrity, not
secrecy.

**Once pinned, ANY mismatch fails the connection.** Enforcement lives in
`ControlTransport.swift`: the Network.framework TLS verify block compares the
leaf's DER to the pinned PEM's (no `URLSession`, no CA trust evaluation) and
fails the handshake unless they are byte-equal. We do NOT silently re-pin on TLS
error. The previous auto-rebind-on-TLS-error path was the gap a same-LAN
attacker rode to pin their own cert, and it is closed.

**Rotation UX.** A real cert rotation (Sunshine reinstall, OS reset on the PC)
fails `ControlTransport`'s pin check, and `NetworkClient` maps that to
`StreamError.hostCertChanged` (“Den PC's certificate changed. Choose Pair Again…
to trust the new one.”). `HostStatusPoller` turns that error into a
`certMismatch` host state, and the launcher's readiness chip goes amber and
reads **Trust needed**. Clicking the chip opens the pairing sheet for that PC.

There is no “accept the new certificate” button anywhere. Re-pairing is the only
path, which means the user has to enter a fresh PIN from Glimmer in Sunshine to
replace the pin. The friction is the point: an on-path attacker who can rotate
the cert cannot also produce the PIN.

## Transport

- **Pre-pairing:** plain HTTP on **47989** for `/serverinfo` and the four HTTP
  pairing rounds. There's no TLS to validate yet; the out-of-band PIN
  authenticates the cert we then pin.
- **Post-pairing:** HTTPS on **47984** for `/serverinfo`, `/launch`, `/cancel`,
  `/applist`, and the final pairing-flow `/pair?phrase=pairchallenge` liveness
  check. Mutual TLS: our client identity authenticates us to the host, and the
  pinned host cert authenticates the host to us. The system trust store is NOT
  consulted; the pinned PEM is the entire trust anchor.
- **Stream:** the Swift-native engine's RTP video/audio + ENet-subset control
  channels (`Glimmer/Stream/Native/`). Both ciphers use the per-session key
  exchanged over mutual TLS at `/launch`. The RTSP handshake is AES-128-GCM
  (`/launch` asks for `rtspenc://`), as is the control channel, input included.
  RTP audio is AES-128-CBC whenever the PC offers it, which Sunshine always
  does. RTP video is plaintext unless the PC requires encryption (Sunshine's
  mandatory mode), and then it is AES-128-GCM.

  Both video receive paths (batched and fallback) and audio check the resolved
  PC's source IP, accepting any source port because Sunshine can vary it. This
  rejects unrelated senders; it does not authenticate plaintext video or defeat
  an attacker capable of spoofing the PC's IP address.

## Runtime hardening

**Glimmer runs UNSANDBOXED.** This is a deliberate trade, not an oversight.

**Current distribution.** Glimmer manages a root LaunchDaemon through
`SMAppService.daemon`; the helper needs root to run `ifconfig awdl0 down`. This
Developer ID distribution uses an unsandboxed app and does not offer a sandboxed
configuration. USB access alone is not a reason to reject a sandboxed design:
Apple provides a supported
[`com.apple.security.device.usb` entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb).
A sandboxed distribution would require a separate architecture and permission
review rather than simply adding hardware entitlements.

**Compensating controls that remain:**

- **Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES`): no JIT, library
  validation, no library injection. Xcode emits a note that the runtime is
  disabled under ad hoc signing. That's expected for development; the setting
  persists so Developer ID signed Release builds get the full enforcement.
- **Developer ID signing + notarization + stapling.** Release builds are signed
  with the team Developer ID and notarized by Apple, and the ticket is stapled
  to the app that the DMG carries.
- **Minimal-attack-surface helper.** The root daemon's XPC protocol is four
  methods (`helper/Protocol.swift`), and exactly one of them changes anything:
  `setAWDLDown(_:reason:)`. The other three (`currentStatus`, `ping`,
  `reSuppressCount`) are read-only. It is not a run-anything-as-root backdoor.
  It accepts a connection only from the signed Glimmer app, not a process that
  merely claims the bundle id: the caller's code signature must satisfy the
  designated requirement in `helper/HelperService.swift`,
  `identifier "io.ugfugl.Glimmer" and anchor apple generic and certificate leaf[subject.OU] = "5T7M4RH3F8"`.

**The defense-in-depth the sandbox used to provide** was containment of a
memory-safety exploit in the streaming-protocol parsers reachable from a
malicious host. With the sandbox gone, that is addressed by hardening the
parsers directly instead:

- **Fuzz the host-reachable parsers.** A deterministic swift-testing suite
  (`GlimmerTests/FuzzTests.swift` and `FuzzTests+Stream.swift`) hammers the
  Annex-B, RTSP, SDP, ENet, AES-GCM and HTTP control parsers, the Reed-Solomon
  kernels, the whole video RTP queue (`RtpVideoQueue.addRawDatagram` through FEC
  reassembly and the depacketizer, for H.264, HEVC and AV1), the audio RTP queue
  and the AV1 sequence header with random + mutated-valid input, asserting they
  reject rather than trap and that no assembled frame passes
  `VideoDepacketizer.maxFrameBytes`. It found and fixed an out-of-bounds read in
  the Reed-Solomon FEC decoders (a shard shorter than the block size) and a
  first packet shorter than its frame header reaching the decoder as video.
- **Hardened Runtime library validation is ON for Release.** Sparkle is the only
  third-party framework, signed inside out with Glimmer's identity. The Release
  entitlements omit `disable-library-validation`. Ad hoc / Debug builds keep it
  via `Glimmer-Debug.entitlements`: an ad hoc binary has no team id for
  validation to match.

This is a LAN client connecting to the **user's own PC**, so that exploit path
is low-likelihood to begin with.

**Entitlements** (`Glimmer/Glimmer.entitlements`, Release):

| Key            | Value | Why                                                           |
| -------------- | ----- | ------------------------------------------------------------- |
| `app-sandbox`  | false | Unsandboxed for the current Developer ID helper architecture. |
| `cs.allow-jit` | false | No JIT.                                                       |

The app also carries `com.apple.developer.coremotion.head-pose` and
`com.apple.developer.spatial-audio.profile-access`, both true. These allow
AVAudioEngine to apply AirPods head tracking and the person's spatial audio
profile. Glimmer does not request raw motion updates or read, store or export
profile data. The login helper and root helper receive neither entitlement. See
Apple's
[head-tracking and personalization requirements](https://developer.apple.com/documentation/phase/personalizing-spatial-audio-in-your-app).

The app also opts into Enhanced Security: hardened heap, platform restrictions
and read-only loader state, with the corresponding compiler protections.
Security version 1 is pinned while version 2's automatic guard-object costs
remain unmeasured on streaming workloads. Legacy integer and current string
version keys preserve support for macOS 26.0 and 26.4 or later. These
protections need functional and performance validation; they do not replace
input validation or imply that all memory-safety bugs are prevented.

The root helper separately carries
`com.apple.developer.networking.topology-observation`. Apple documents this
capability for routing-socket observation under macOS 27's privacy rules. It
grants neither root privileges nor an exemption from helper approval. The helper
keeps its existing signing identifier inside an app-like bundle with its own
profile. See
[Apple's routing-socket guidance](https://developer.apple.com/forums/thread/734338).

Both bundles embed explicitly supplied Developer ID profiles before signing. The
build validates identity, team, distribution scope, expiry and requested grants,
then exercises AMFI launch authorization after notarization. No profile contents
or certificates are logged. See RELEASE.md for setup.

Unsandboxed builds carry no `device.*` exceptions: those are sandbox
capabilities, and raw-HID, networking, and file access all work without them
once unsandboxed. The Debug variant (`Glimmer/Glimmer-Debug.entitlements`) adds
`cs.disable-library-validation` = true for unsigned development instrumentation;
Release omits it (validation enforced). Installed builds require Developer ID
profiles; unsigned compile checks and hostless tests do not.

**Screen capture is not prevented.** The stream window sets
`NSWindow.sharingType = .none` for legacy capture clients, but modern
ScreenCaptureKit can still capture it. Apple describes
[`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
as a legacy value that must not be used to prevent capture. Glimmer does not
provide DRM or a screen-recording privacy boundary.

## Sensitive material: what we don't log

- **Key characters, scan codes and per-key modifier masks.** Physical key
  positions can reveal typed content too, so they do not belong in logs.
- **URLs containing `rikey`, `rikeyid`, `gcmkey`, `gcmkeyid`, `uuid`,
  `uniqueid`, and the `sessionUrl0` tag.** `NetworkClient.sensitiveQueryKeys`
  (`Network.swift`) is the key set; the launch-URL redaction that consumes it
  lives in `NetworkClient+Endpoints.swift`, and `dumpXMLRedacted` covers the
  response bodies, where `sessionUrl0` carries the PC's address and port.
- **Cert PEMs / fingerprints at `.public`.** `ControlTransport` logs a
  pin-mismatch event but not the fingerprints; a hostile log scraper could
  otherwise read the pinned cert via `log show`.
- **PIN values, AES keys, signed pairing-secret bytes.**

## Sensitive material: what we do log

- Input lifecycle events, such as releasing held input on focus loss, and counts
  of released keys and buttons, without their identities.
- Network errors with sanitized URLs (rikey/gcmkey stripped).
- VT decode errors and codec configuration ints (`videoFormat=0x...`, `bytes=N`,
  `idr=true/false`).
- `Diag` lines, which take Logger's `privacy:` argument (`LogStore.swift`).
  Private values (PC names and addresses, uniqueids, error text) reach only the
  in-app log viewer. Copied logs, the unified log and session files show
  `<private>` instead. Keys, PINs and certificates stay out of the message
  entirely.
- Telemetry files, which name the PC and the Mac only by pseudonyms keyed to a
  random per-install salt.
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
