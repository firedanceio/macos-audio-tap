# macos-audio-tap

Read the level of everything playing on a Mac, from Swift or from any language that can run a
process and read lines.

It uses Core Audio process taps (macOS 14.4+) to tap the system output, computes the RMS level of
each buffer, and reports it in dBFS a few times a second. Audio itself never leaves the process.

## Command line

```sh
swift build -c release
.build/release/audio-tap --emit-interval-ms 100
```

```json
{"event":"ready"}
{"dbfs":-18.4,"event":"level","timestampMs":1791419046720}
{"deviceName":"MacBook Pro Speakers","event":"outputDeviceChanged"}
```

| Event | Fields | When |
|---|---|---|
| `ready` | | Capture started |
| `level` | `timestampMs`, `dbfs` | Every `--emit-interval-ms` (default 100). Silence is `-120` |
| `outputDeviceChanged` | `deviceName` | The default output device changed |
| `error` | `message` | Setup failed; the process exits with status 1 |

Options: `--emit-interval-ms N` (default 100), `--silence-timeout-s N` (default 8; see Permission).
Ctrl-C or SIGTERM stops capture and removes the tap.

## Swift

```swift
.package(url: "https://github.com/firedanceio/macos-audio-tap", from: "0.1.0")
```

```swift
import SystemAudioTap

let tap = SystemAudioTap(emitIntervalMs: 100)
tap.onLevel = { print($0.dbfs) }
tap.onOutputDeviceChanged = { print("now playing on \($0)") }
tap.startObservingOutputDeviceChanges()
try tap.prepare()
try tap.start(on: DispatchQueue(label: "levels"))
```

## Permission

The app that runs `audio-tap` needs the **System Audio Recording** permission (System Settings >
Privacy & Security). Add `NSAudioCaptureUsageDescription` to your app's Info.plist.

Without the permission, macOS does not return an error: setup succeeds and the tap delivers
silence. `audio-tap` prints a hint on stderr if nothing above -100 dBFS arrives within
`--silence-timeout-s`, but it can't tell a missing permission from a quiet room.

The permission is tied to the app's code signature. Re-signing with a different identity (for
example ad-hoc builds) can reset it.

## How it works

1. A `CATapDescription` with an empty process list and `isExclusive = true` taps every process.
2. A private aggregate device uses the default output device as its sub-device and lists the tap
   in its creation dictionary. (An empty sub-device list, or adding the tap after creation, can fail
   at `AudioDeviceStart` with `'nope'` on some machines.)
3. An IOProc computes RMS on the real-time thread without allocating; only the throttled sample is
   dispatched to your queue.

## Acknowledgements

Built on patterns from [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo and
[AudioTee](https://github.com/makeusabrew/audiotee) by Nick Payne. See [NOTICE](NOTICE).

## Licence

Apache-2.0. Made by [Firedance](https://firedance.io).
