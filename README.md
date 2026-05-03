# Apogee ONE Exploration

This repository is currently a feasibility workspace for replacing the legacy
Apogee Maestro control path for the original Apogee ONE USB interface on modern
macOS.

Current observed device:

- USB vendor: Apogee (`0x0c60`)
- USB product: ONE (`0x0003`)
- Local macOS: Tahoe 26.3.1
- USB Audio Class: UAC1, full-speed USB, 24-bit PCM at 44.1/48 kHz
- Streams advertised by descriptors: 2-channel output, 1-channel input

Current status:

- The USB device and its audio interfaces enumerate under `IOUSBHost`.
- Core Audio exposes `ONE` as an Apogee USB audio device. On this Mac, an
  outside-sandbox Core Audio probe sees it as the default output/system output
  with 1 input channel and 2 output channels.
- The device accepts read-only USB Audio Class control requests from user space.
- This gives us a practical path for a Maestro-style control app that controls
  hardware state while Core Audio continues to handle audio streaming.
- In the Codex sandbox, `system_profiler SPAudioDataType` and Core Audio device
  enumeration can report an empty device list. Use the Core Audio probe outside
  the sandbox for authoritative local device state.

Initial feature targets:

- Main output level and mute
- Input source and input gain, with source names mapped to `int-mic`,
  `ext-mic`, `ext-48v-mic`, and `inst`
- Direct monitoring volume through the confirmed direct-input monitor mix send
- Phantom power and Hi-Z/instrument mode after their exact control mapping is
  confirmed

Useful command:

```sh
make probe
.build/apogee-one-probe --read-controls
make coreaudio-probe
.build/coreaudio-probe
make one-control
make app
make package
.build/one-control status
.build/one-control status --json
.build/one-control output
.build/one-control input
.build/one-control monitor
.build/one-control monitor --volume-db -48 --dry-run
.build/one-control monitor --mix-dry-run --ext-mic-level 48 --inst-int-level 63
.build/one-control self-test
```

Examples that change hardware state:

```sh
.build/one-control input --source inst
.build/one-control monitor --volume-db -48
```

`one-control` opens the ONE through `IOUSBHost`, so run one instance at a time.
Parallel invocations can collide because the USBHost user client is exclusive.
`self-test` performs no-op writes: it writes current values back to the same
controls, then verifies readback.
`status --json` is the app-facing read API for the current prototype.
`make app` builds a first SwiftUI wrapper at `.build/OneMaestro.app`; the app
bundles `one-control` and uses the JSON status/control CLI internally.

`monitor --volume-db` uses the audible, confirmed direct-input monitor mix send
from the legacy `ONEUSB::UpdateLLM()` path. Raw hardware values are inverted:
`0` is loud and `63` is silent or near-silent, so the CLI exposes a conventional
`-63..0 dB` user range. The older `bRequest=0x06` attenuation path is still
available as `--legacy-volume-db`/`--legacy-attenuation-db`; it is accepted by
the device but did not change audible monitoring in live tests.

Project plan: [Apogee ONE Maestro Replacement](docs/apogee-one-maestro-plan.md).
Reverse-engineering notes: [Legacy ONE Findings](docs/legacy-one-reverse-engineering.md).
Operator test checklist: [Operator Test Checklist](docs/operator-test-checklist.md).
