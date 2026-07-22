# Luna power controls — handoff spec

Give Glimmer host tiles power controls (wake / shutdown / sleep / reboot /
status) for Sunshine hosts that are managed by UpSnap, by shelling out to the
`luna` CLI. **Hard gate: the controls exist in the UI only when (a) a usable
`luna` binary is found and (b) the host's MAC matches an UpSnap device luna can
see. If either is false, no power UI is drawn anywhere — no settings, no
disabled buttons, zero footprint.**

Upstream context (whaleyshire-infra repo):

- `dev/luna/` — the CLI, ~150 lines of stdlib Go; the reference client
- `k8s-solo/apps/upsnap/README.md` — server side: UpSnap app, auth model, device
  config

## Why luna-as-subprocess (not a Swift port of the API client)

luna owns the UpSnap endpoint, credentials (macOS keychain item `upsnap-power`),
permission scoping, and the synchronous-confirmation semantics. Glimmer stays
credential-free and config-free: if the machine has luna set up, Glimmer
inherits a working power backend; if not, the feature does not exist. That is
the whole gate philosophy.

## The gate

Evaluate lazily per host (and cache — see below). Both checks must pass.

### 1. luna is present and usable

GUI apps do **not** inherit the login shell's PATH (`~/.local/bin` will not be
in a launchd PATH), so do not rely on `PATH` alone. Probe in order:

1. `~/.local/bin/luna` (the `make install` target — the common case)
2. `/opt/homebrew/bin/luna`, `/usr/local/bin/luna`
3. entries of the process `PATH`

A candidate is usable iff it is executable and `luna version` exits 0 and prints
a calver **≥ 2026.7.1** (the first version with `devices --json`; 2026.7.0 lacks
it and must fail the gate).

### 2. MAC match

- Glimmer side: the host's MAC comes from Sunshine's `serverinfo` (`<mac>` field
  — stock Moonlight uses the same field for its WoL). It is only learnable while
  the host is **online**, so persist it in the host store at pair time and
  refresh it on every successful `serverinfo`. A host with no stored MAC fails
  the gate (until its next online session backfills it).
- luna side: `luna devices --json` prints the UpSnap devices the configured user
  is permitted to see (the permission model is the allowlist — a client can only
  ever match hosts it has been granted).
- Match: compare normalized MACs (lowercase, colon-separated, strip leading
  zeros consistently). On match, bind `host → device.id` and persist the
  binding; re-resolve if a later `devices --json` no longer contains it.
- **Fail closed**: Sunshine sometimes reports a zeroed MAC (`00:00:00:00:00:00`)
  on some NIC configs. Zeroed or absent MAC on either side = no match = no
  controls. No IP fallback, no manual binding in v1 — per the product rule, we
  never draw unless the MAC genuinely matches.

## luna CLI contract (v2026.7.1)

| command                      | behavior                                                    | notes                             |
| ---------------------------- | ----------------------------------------------------------- | --------------------------------- |
| `luna version`               | prints calver, exit 0                                       | gate + minimum-version check      |
| `luna devices --json`        | JSON array `[{"id","name","mac","ip","status"}]`, exit 0    | permission-scoped; used for match |
| `luna on`                    | **blocks until the device is confirmed awake**, then exit 0 | measured ~36s cold; cap 200s      |
| `luna off`                   | blocks until confirmed down, exit 0                         | measured ~9s                      |
| `luna sleep` / `luna reboot` | same shape as `off`                                         | only if UpSnap device has the cmd |
| `luna status`                | prints `online` / `offline` / `pending`, exit 0             | UpSnap ping loop, ~5m cadence     |

- Target device: set `UPSNAP_DEVICE=<matched device.id>` in the subprocess
  environment for every power call. Never rely on luna's baked-in default.
- Exit non-zero ⇒ the action failed; stderr has a one-line reason (`luna: …`).
  Surface it and re-evaluate the gate.
- UpSnap's power routes are **synchronous** — they keep pinging until the device
  state actually flips before responding. luna exit 0 is therefore a
  _confirmation_, not an acknowledgement. Do not add client-side "did it work"
  polling on top of `on`/`off` themselves.
- Auth is luna's problem (keychain item `upsnap-power` via `security`, or
  `UPSNAP_PASSWORD`). Glimmer must not read, store, or pass credentials.

## UX

Gate passed, host **offline**:

- Tile shows an accurate offline state plus **Wake & Connect** (primary action)
  and a plain **Wake**.
- Wake & Connect: run `luna on` off the main thread (progress state on the tile:
  "Waking…"); on exit 0, poll `serverinfo` until Sunshine answers, then start
  the session as if the user had tapped the host. Expect the host's encoder to
  be ragged for ~15s after cold boot (known Sunshine ramp) — do not treat early
  jitter as failure.

Gate passed, host **online**:

- Overflow/context menu on the tile gains a Power section: Shut Down, Sleep,
  Restart (with confirmation for Shut Down/Restart while a session is active).
  Optional later: auto-offer "shut down host?" on stream quit — out of scope v1.

Gate failed: none of the above exists. No menu items, no empty sections, no
preferences toggle.

## Caching & re-evaluation

- luna discovery + version: on app launch and on each app-foreground.
- `devices --json`: cache per app session with a short TTL (~60s); refresh on
  any power-action failure and on host-store changes.
- The `host → device.id` binding persists in the host store; it is invalidated
  when a refreshed devices list no longer contains the id or the MAC stops
  matching.

## Acceptance checklist

- [ ] Machine without luna: pixel-identical UI to today, zero subprocess spawns
      beyond the initial probe.
- [ ] luna 2026.7.0 (no `devices --json`): gate fails cleanly, no UI.
- [ ] Host never seen online (no stored MAC): no power UI until first successful
      serverinfo, then controls appear without restart.
- [ ] MAC match with device offline: Wake & Connect wakes ((~36s), connects
      after Sunshine answers.
- [ ] `luna off` from the tile menu shuts the box down (~9s) and the tile
      returns to the offline+wake state.
- [ ] Revoking the UpSnap permission (device disappears from `devices --json`):
      controls vanish on next re-evaluation.
- [ ] All luna calls off the main thread; UI stays responsive during the ~36s
      wake.
