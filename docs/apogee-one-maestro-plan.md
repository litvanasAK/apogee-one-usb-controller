# Apogee ONE Maestro Replacement Plan

## Goal

Build a small macOS utility that replaces the useful parts of Apogee Maestro for
the original Apogee ONE USB: output level/mute, input source selection, and input
gain, including direct monitoring volume. Use the existing AppleUSBAudio/Core
Audio path for audio streaming and talk directly to the device only for
Maestro-style hardware controls.

## Current Findings

The connected device is `Apogee ONE` (`0x0c60:0x0003`, release `0x0113`). It is
a USB Audio Class 1 device with 24-bit PCM streams at 44.1 kHz and 48 kHz:

- output stream: interface 1, 2 channels, endpoint `0x01`
- input stream: interface 2, 1 channel, endpoint `0x82`
- audio-control interface: interface 0

Tahoe creates `IOUSBHostInterface` services for interfaces 0, 1, and 2, and
`usbaudiod` owns them. An outside-sandbox Core Audio API probe sees `ONE` as an
Apogee USB audio device:

- Core Audio device name: `ONE`
- manufacturer: `Apogee`
- UID: `AppleUSBAudioEngine:Apogee:ONE:2420000:2,1`
- transport: USB
- channels: 1 input, 2 output
- current default role: default output and default system output

The Codex sandbox can hide all Core Audio devices from `system_profiler` and
from normal Core Audio enumeration. Do not use those sandboxed results as device
truth.

The device has one descriptor quirk worth tracking: its configuration advertises
4 interfaces, but the descriptor stream contains only interface numbers 0, 1,
and 2. Since Core Audio does publish the device outside the sandbox, this is a
diagnostic detail rather than a current blocker.

## Control Model

Read-only USB Audio Class requests already work from user space through
`IOUSBHostDevice`. Current control values from the attached unit:

- selector unit `7`: input source pin `3`
- feature unit `2`: main output mute off, volume `-20 dB`, range `-64..0 dB`
- feature unit `22`: headphone mute off
- feature unit `5`: input gain `17 dB`, range `0..45 dB`
- feature unit `9`: input gain `0 dB`, range `0..45 dB`
- feature unit `11`: input gain `58 dB`, range `10..63 dB`
- feature unit `13`: input gain `58 dB`, range `10..63 dB`

The four selector sources are `[5, 11, 13, 9]`. Core Audio selector item-name
queries on the live ONE map those pins to Maestro labels:

- pin `1`, feature `5`: `Int Mic`
- pin `2`, feature `11`: `Ext Mic`
- pin `3`, feature `13`: `Ext 48V Mic`
- pin `4`, feature `9`: `Inst`

For the product UI, phantom power and Hi-Z are currently represented as source
mode semantics: `Ext 48V Mic` means 48V external microphone mode, and `Inst`
means Hi-Z instrument mode. They are not exposed as independent toggles until a
separate hardware control is verified.

Monitoring volume is a v1 target. The standard UAC descriptor dump shows output
volume and input gain controls; it does not name a monitor volume control
directly. The installed Apogee plug-in includes Maestro monitor/mixer concepts
such as `kMaestroPropertyMonitorOutput`, `kMaestroPropertyMonitorDevice`, mixer
meters, and mixer level ranges. `one-control monitor` also confirms that Core
Audio play-through volume is not exposed on this ONE as global, input, or output
scope. Core Audio does expose five ordinary controls for the ONE:

- input data source: current item `3`, available items `[1,2,3,4]`
- input volume: `58 dB`, range `10..63 dB`
- output mute: off
- output volume: Core Audio reports a separate `-64..0 dB` control; recent
  live reads have shown values such as `-39 dB` and `-26 dB` while direct UAC
  feature unit `2` still read `-20 dB`
- output boolean class `evis`: off, currently unidentified

The selected Apogee/Maestro selectors from Maestro's resource plist, including
monitor output/device, mixer level/range, main output, Hi-Z, phantom, and ONE
channel selection, are not exposed as readable properties on the live Core Audio
device object.

Live listening tests confirmed that the practical direct monitoring volume is
the legacy `ONEUSB::UpdateLLM()` direct-input monitor mix path. It uses the
TAS1020 remote-I2C vendor write helper with `bRequest=0x02`,
`wValue=0x2b50`, `wIndex=<ext_mic_raw>`, and a single payload byte
`0x40 | <inst_or_int_raw>`. Raw values are inverted: `0` is loud, `63` is
silent or near-silent. `one-control monitor --volume-db <db>` and
`--attenuation-db <db>` now use this confirmed path for the current input
source.

Reverse engineering also found the low-latency monitor output attenuation path:
`ONEUSB::SetLLMOutAtt(signed char)` sends a device-recipient vendor OUT request
with `bRequest=0x06`, `wIndex=0`, and `wValue=-attenuation`. The device accepts
that request, but live tests at `0`, `-24`, and `-96 dB` did not change audible
monitoring once the direct mix send was audible. `one-control` keeps this path
as `--legacy-volume-db` and `--legacy-attenuation-db` for further research.

The legacy daemon/private-property transport is installed but not active on this
Tahoe machine. The old ONE HAL plug-in references
`/var/run/com.apogee.soloDaemon/Socket`, but that directory and socket are
absent, and `ONEDaemon` is not accepting Maestro private-property traffic.

## Current Implementation

- `.build/one-control status`: read-only Core Audio and UAC status.
- `.build/one-control status --json`: parseable app-facing status with Core
  Audio role, UAC control values/ranges, input-source mapping, and monitor
  request metadata. It also includes the Core Audio control list so UAC and
  Core Audio volume/mute state can be compared.
  Input source metadata marks 48V and Hi-Z source modes.
- `.build/one-control output`: read-only output status.
- `.build/one-control output --json`: structured app-facing output command
  result, including refreshed main-output and headphone state.
- `.build/one-control output --volume-db <db>`: guarded UAC `SET_CUR` for main
  output level.
- `.build/one-control output --mute on|off`: guarded UAC `SET_CUR` for main
  output mute.
- `.build/one-control output --headphone-mute on|off`: guarded UAC `SET_CUR`
  for headphone mute.
- `.build/one-control input`: read-only source/gain status.
- `.build/one-control input --json`: structured app-facing input command
  result, including source metadata and current gain state.
- `.build/one-control input --source <int-mic|ext-mic|ext-48v-mic|inst>`:
  guarded UAC `SET_CUR` for the input selector by Maestro source name.
- `.build/one-control input --source-pin <1..4>`: guarded UAC `SET_CUR` for the
  input selector.
- `.build/one-control input --source-unit <5|9|11|13>`: same selector write by
  feature unit.
- `.build/one-control input --gain-db <db>`: guarded UAC `SET_CUR` for the
  current selected input gain, or for the selected source if paired with
  `--source-pin`/`--source-unit`.
- `.build/one-control monitor`: monitor-volume discovery status.
- `.build/one-control monitor --json`: structured app-facing monitor status or
  command result.
- `.build/one-control monitor --volume-db <db> --dry-run`: prints the
  current-source direct monitor send value without sending it.
- `.build/one-control monitor --volume-db <db>`: confirmed direct-input monitor
  mix send write for the current source, accepting `-63..0 dB`.
- `.build/one-control monitor --attenuation-db <db>`: same confirmed write using
  raw attenuation form, accepting `0..63 dB`.
- `.build/one-control monitor --legacy-volume-db <db>`: accepted but not
  audibly effective legacy request `0x06`, accepting `-96..0 dB`.
- `.build/one-control monitor --mix-dry-run --ext-mic-level <0..63>
  --inst-int-level <0..63>`: prints explicit direct input monitor mix vendor
  fields without sending them.
- `.build/one-control monitor --mix-levels --ext-mic-level <0..63>
  --inst-int-level <0..63>`: sends explicit raw direct input monitor mix fields.
- `.build/one-control self-test`: no-op write/readback verification for main
  output mute/volume, headphone mute, input selector, and all four input gain
  feature units.
- `.build/OneMaestro.app`: first SwiftUI wrapper built by `make app`. It uses
  bundled `one-control` for status, output volume/mute, input source/gain, and
  monitor volume commands.
- The app/helper boundary now uses JSON for reads, writes, and monitor dry-runs:
  `status --json`, `output --json`, `input --json`, and `monitor --json`.
- App-side persistence stores monitor volume, input source/gain, output
  mute/level, and last seen Core Audio UID in `UserDefaults`.
- When the app changes input source, it reapplies the current monitor volume so
  the source-dependent direct-input mix send follows the selected source.
- The monitor UI includes conservative preset points at `-63`, `-54`, `-48`,
  and `-36 dB` for repeatable curve checks while the final taper is calibrated.
- The app polls status every four seconds and shows a disconnected state when
  the bundled helper cannot read the device.
- Polling skips refreshes while a user command is running so write-result
  messages and serialized helper access are not disturbed by background reloads.
- The app serializes all bundled helper invocations so polling and user writes
  do not collide with the ONE's exclusive `IOUSBHost` user client.
- The app includes a compact diagnostics disclosure with USB IDs, Core Audio
  UID/roles, UAC entity IDs, monitor request status, and legacy request status.
- Diagnostics show both direct UAC main output volume and Core Audio output
  volume so the known output discrepancy is visible instead of hidden.
- The Output section also shows a concise hardware-vs-macOS volume line when
  the direct UAC value and Core Audio output value differ by at least `1 dB`.
- `make package` ad-hoc signs the app bundle and creates `.build/OneMaestro.zip`.
- [Operator Test Checklist](operator-test-checklist.md) captures the live smoke
  test sequence.

The CLI opens the ONE through `IOUSBHost`; run one instance at a time because
the user client is exclusive.

Verified write behavior:

- `self-test` passed on the connected unit.
- The test wrote current values back to the same controls, then confirmed
  readback for main output mute, main output volume, headphone mute, input
  selector, and input gain feature units 5, 9, 11, and 13.
- No intentional level/source change was made during verification.
- Source labels were verified from the live Core Audio data-source item names.
- Direct monitor mix sends were audibly verified on the selected `Ext 48V Mic`
  path: raw `0` was loud, raw `63` was silent, and raw `48` was quiet-audible.
- Legacy request `0x06` was accepted but did not change audible monitoring at
  tested values.
- The app bundle builds, its Info.plist validates, and its bundled
  `one-control status --json` reads the connected ONE outside the sandbox.
- Structured helper result checks passed for `output --json`, `input --json`,
  `monitor --json --volume-db -48 --dry-run`, and a no-op
  `output --json --volume-db -20`.
- May 4, 2026 verification: `make package` completed, `self-test` passed, and
  `status --json`, `output --json`, `input --json`, and
  `monitor --json --volume-db -48 --dry-run` returned valid JSON on the
  connected ONE. The current source was `Ext 48V Mic`, current input gain was
  `33 dB`, direct UAC main output was `-20 dB`, and Core Audio output volume
  was `-26 dB`.

One behavior to track: direct UAC reads and Core Audio control reads can disagree
for output volume. Current JSON exposes both values; recent live reads showed
direct UAC main output at `-20 dB` and Core Audio output volume at `-26 dB`.
Treat those as separate observed values until we confirm which one corresponds
to Maestro's Main Out level versus macOS output volume.

## Architecture

1. `ControlCore`
   - Match `IOUSBHostDevice` vendor `0x0c60`, product `0x0003`.
   - Parse the UAC descriptors into a device model.
   - Implement `GET_CUR`, `GET_MIN`, `GET_MAX`, `GET_RES`, and guarded
     `SET_CUR` for UAC controls.
   - Poll state and recover from unplug/replug.

2. CLI first
   - `one-control status`
   - `one-control output --volume-db -24`
   - `one-control output --mute on|off`
   - `one-control input --source <name-or-pin>`
   - `one-control input --gain-db <value>`
   - `one-control monitor --volume-db <value>`

3. SwiftUI app
   - Device status at the top.
   - Output section: level slider and mute.
   - Input section: source segmented control and gain slider.
   - Monitor section: direct monitoring volume, and monitoring source/mix if the
     hardware exposes them.
   - Advanced section: raw entity IDs and descriptor diagnostics.

4. Core Audio integration
   - Detect the live `ONE` Core Audio device by UID/name/manufacturer.
   - Show whether it is current default input/output/system output.
   - Avoid seizing streaming interfaces; use Core Audio for streams and
     device-level USB Audio Class requests for controls.

## Risks

- Direct UAC control writes work for no-op self-test coverage. Direct monitor
  mix writes are audibly verified but have no readback path, so the app must
  keep its own last-set monitor value and recover gracefully after unplug/replug.
- The `0x06` low-latency monitor attenuation request is accepted but did not
  change audible monitoring in live tests. Keep it as a legacy diagnostic, not
  as the product-facing monitoring volume control.
- Phantom power and Hi-Z/instrument mode are represented as input source modes.
  They should not be presented as independent controls unless a separate
  hardware control is verified.
- The current SwiftUI app shells out to the CLI. That is acceptable for a local
  prototype, but the product should move shared control logic into a reusable
  library or XPC/helper boundary.
- A sandboxed App Store-style app is unlikely to be the right distribution model
  for direct `IOUSBHost` access. Start with an unsigned/developer-signed local
  utility.
- The Codex sandbox can hide Core Audio devices, so automated tests that inspect
  the live audio system need to run outside the sandbox.

## Next Milestone

Turn the working prototype into a usable local product:

1. Move the current shell-out implementation to a shared `ControlCore` module
   or XPC/helper boundary. The interim stricter JSON command/result contract is
   implemented.
2. Run the operator test checklist end-to-end from the app UI, including
   unplug/replug behavior.
3. Calibrate the monitor volume curve using the app presets/checklist points
   plus `0 dB`; the UI now exposes repeatable intermediate points, but the
   final taper still needs listening or loopback confirmation.
4. Resolve the direct UAC output volume versus Core Audio output volume
   discrepancy. It is now observable in JSON/app diagnostics but not yet
   semantically resolved.
5. Decide whether additional reverse engineering is needed for independent
   phantom power or Hi-Z controls. Current product behavior treats them as
   source modes.
