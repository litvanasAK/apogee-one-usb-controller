# Operator Test Checklist

Use this checklist on the target Mac with the original Apogee ONE connected.
Run live checks outside the Codex sandbox.

## Build

```sh
make one-control
make app
make package
```

Expected results:

- `.build/one-control` exists.
- `.build/OneMaestro.app` exists.
- `.build/OneMaestro.zip` exists.

Last checked on May 4, 2026: `make package` completed and refreshed
`.build/OneMaestro.zip`.

## Device Status

```sh
.build/one-control status --json
.build/one-control output --json
.build/one-control input --json
.build/one-control monitor --json
```

Expected results:

- Core Audio device name is `ONE`.
- Manufacturer is `Apogee`.
- USB vendor is `0x0c60`.
- USB product is `0x0003`.
- Input sources include `int-mic`, `ext-mic`, `ext-48v-mic`, and `inst`.
- Output, input, and monitor JSON commands return `ok: true`.

## No-Op Write Safety

```sh
.build/one-control self-test
```

Expected result:

- Every line reports `ok`.
- Final line is `self-test: passed`.

Last checked on May 4, 2026: self-test passed with main output at `-20 dB`,
input selector `3`, and input gains `17`, `33`, `33`, and `0 dB` for features
`5`, `11`, `13`, and `9`.

## Input Controls

Pick the source you can safely test:

```sh
.build/one-control input --source ext-48v-mic
.build/one-control input --gain-db 58
```

Expected results:

- Recording through the selected ONE input still works.
- `status --json` reports the selected source and gain.

## Direct Monitor Volume

Keep headphone/speaker level conservative. For the currently selected external
mic source:

```sh
.build/one-control monitor --volume-db -63
.build/one-control monitor --volume-db -54
.build/one-control monitor --volume-db -36
.build/one-control monitor --volume-db -18
.build/one-control monitor --volume-db 0
```

Expected results:

- `-63 dB` is silent or near-silent.
- `-54 dB`, `-36 dB`, and `-18 dB` increase in audible level.
- `-54 dB` is quiet-audible.
- `0 dB` is loud.
- Recording remains unaffected.

## App Smoke Test

```sh
open .build/OneMaestro.app
```

Expected results:

- The window shows `ONE`.
- Refresh works.
- Output mute and sliders remain responsive.
- Input source and gain controls update the device.
- Monitor volume slider and presets update direct monitoring.
- Diagnostics disclosure shows USB IDs, Core Audio UID, UAC entity IDs, and
  monitor request status.

## Reconnect

With the app open:

1. Unplug the ONE.
2. Wait at least four seconds.
3. Reconnect the ONE.

Expected results:

- The app shows a disconnected state after unplug.
- The app returns to ready state after reconnect.
- Previously selected UI values remain visible from persisted app state.


## macOS System Output Volume

With the ONE selected as macOS's default system output:

```sh
.build/one-control output --system-volume-db -24
```

Expected results:

- The command changes the default system output device's Core Audio volume control.
- The app's output slider follows the Core Audio level when the ONE is the default system output.
- If the ONE is not the default system output, the app's output slider controls the ONE's USB hardware output instead.
- If the current default system output exposes no writable Core Audio volume control, the command fails clearly rather than changing the ONE's unrelated output level.

## Physical Encoder Discovery

The encoder/button event and LED-mode protocol is not implemented yet. Do not send guessed vendor requests. Capture USB interface/endpoint descriptors and a USB event trace while pressing/turning the knob, then map the report or endpoint before adding input handling.
