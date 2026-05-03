# Legacy ONE Reverse-Engineering Notes

These notes capture the Maestro/ONEDaemon findings that are specific enough to
drive the replacement utility. They intentionally separate confirmed UAC
controls from candidate private/vendor controls.

## Installed Legacy Components

Observed local paths:

- `/Applications/Apogee Maestro 2.app`
- `/Library/Audio/Plug-Ins/HAL/Apogee/ONE/ONEPlugIn.bundle`
- `/Library/Application Support/Apogee/ApogeePopup.bundle`

The original ONE HAL bundle contains `ONEDaemon` and `ONEPlugIn` binaries. The
legacy private socket path referenced by the plug-in is:

```text
/var/run/com.apogee.soloDaemon/Socket
```

On the Tahoe test machine, that socket directory is absent and ONEDaemon is not
accepting the old Maestro private-property transport.

## Maestro Property Keys

`CoreAudioPropertyKeys.plist` in the legacy Maestro resources maps user-facing
Maestro concepts to private four-character Core Audio selectors. The useful
selectors for the original ONE work are:

| Concept | Selector |
| --- | --- |
| Main output level | `AEl3` |
| Main output mute | `AEm3` |
| Headphone 1 level | `AEl1` |
| Headphone 1 mute | `AEm1` |
| Microphone gain | `AEmg` |
| Gain range | `AEgr` |
| Phantom power | `AEph` |
| Hi-Z | `AEhi` |
| ONE channel selection | `AEOC` |
| Monitor device | `AEmd` |
| Monitor output | `AEmo` |
| Mixer level | `AEMl` |
| Mixer range | `AEMR` |
| Mixer mute | `AEMm` |
| Mixer solo | `AEMs` |
| Mixer pan | `AEMp` |
| Mixer model data | `APG1` |

The current Tahoe Core Audio device object for `ONE` does not expose these
private selectors, so the replacement utility should not depend on that old
transport.

## Confirmed Standard UAC Controls

The attached ONE exposes useful USB Audio Class controls directly:

| Function | Entity | Control |
| --- | --- | --- |
| Main output volume | Feature unit `2` | Volume |
| Main output mute | Feature unit `2` | Mute |
| Headphone mute | Feature unit `22` | Mute |
| Input source | Selector unit `7` | Selector |
| Int Mic gain | Feature unit `5` | Volume |
| Inst gain | Feature unit `9` | Volume |
| Ext Mic gain | Feature unit `11` | Volume |
| Ext 48V Mic gain | Feature unit `13` | Volume |

Selector unit `7` source pins map to Maestro labels as:

| Pin | Feature unit | Label | CLI name |
| --- | --- | --- | --- |
| `1` | `5` | Int Mic | `int-mic` |
| `2` | `11` | Ext Mic | `ext-mic` |
| `3` | `13` | Ext 48V Mic | `ext-48v-mic` |
| `4` | `9` | Inst | `inst` |

These controls have readback, so write support can be guarded by range reads and
verified with no-op write/readback tests.

## Low-Latency Monitor Output Attenuation

The legacy `ONEDaemon` symbol `ONEUSB::SetLLMOutAtt(signed char)` maps monitor
output attenuation to a vendor request:

| Field | Value |
| --- | --- |
| `bmRequestType` | `0x40` vendor OUT, device recipient |
| `bRequest` | `0x06` |
| `wValue` | `-attenuation_db` as a signed 16-bit value |
| `wIndex` | `0` |
| `wLength` | `0` |

There is no known readback request for this path. Live tests showed the device
accepts the request, but tested values did not change audible direct monitoring
once the direct-input mix send was audible. `one-control` keeps this path as
`monitor --legacy-volume-db <db>` and `--legacy-attenuation-db <db>` for further
research.

## Direct Input Monitor Mix Candidates

The old daemon contains `SetMixLevelInstOrIntMic`, `SetMixLevelExtMic`, and
`UpdateLLM` paths. Disassembly shows the two input monitor mix levels are
clamped to `0..0x3f`, then `UpdateLLM` writes both values through a TAS1020
remote-I2C helper. The observed call shape is:

```text
RemoteI2C(0x50, ext_mic_level, 0x2b, &[0x40 | inst_or_int_mic_level], 1)
```

The TAS1020 helper formats the write request as:

| Field | Value |
| --- | --- |
| `bmRequestType` | `0x40` vendor OUT, device recipient |
| `bRequest` | `0x02` |
| `wValue` | `((0x2b & 0x3f) << 8) | 0x50`, currently `0x2b50` |
| `wIndex` | `ext_mic_level` |
| `wLength` | `1` |
| payload byte | `0x40 | inst_or_int_mic_level` |

Live tests confirmed this request controls audible direct monitoring volume.
The raw values are inverted: `0` is loud, `63` is silent or near-silent, and
`48` was quiet-audible on the connected unit's `Ext 48V Mic` source.

`one-control monitor --volume-db <db>` now maps the current input source to this
request using a conventional `-63..0 dB` range. `one-control monitor
--mix-dry-run --ext-mic-level <0..63> --inst-int-level <0..63>` prints the raw
request fields, and `--mix-levels` sends explicit raw fields.
