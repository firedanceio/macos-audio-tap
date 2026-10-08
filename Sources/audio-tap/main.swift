// Copyright 2026 Firedance Multimedia LLC
// SPDX-License-Identifier: Apache-2.0
//
// audio-tap: prints the Mac's system audio level as one JSON object per line on stdout.
//
//   {"event":"ready"}
//   {"event":"level","timestampMs":<int>,"dbfs":<double>}     -- silence is reported as -120
//   {"event":"outputDeviceChanged","deviceName":"<string>"}
//   {"event":"error","message":"<string>"}                    -- setup failed; the process exits
//
// Usage: audio-tap [--emit-interval-ms N] [--silence-timeout-s N]

import Foundation
import SystemAudioTap

func emit(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let emitIntervalMs = option("--emit-interval-ms").flatMap(Int.init) ?? 100
let silenceTimeoutS = option("--silence-timeout-s").flatMap(Double.init) ?? 8

let tap = SystemAudioTap(emitIntervalMs: emitIntervalMs)
let deliveryQueue = DispatchQueue(label: "audio-tap.delivery")

var sawSignal = false
tap.onLevel = { sample in
    if sample.dbfs > -100 { sawSignal = true }
    emit(["event": "level", "timestampMs": sample.timestampMs, "dbfs": sample.dbfs.isFinite ? sample.dbfs : -120.0])
}
tap.onOutputDeviceChanged = { name in emit(["event": "outputDeviceChanged", "deviceName": name]) }
tap.startObservingOutputDeviceChanges()

do {
    try tap.prepare()
    try tap.start(on: deliveryQueue)
    emit(["event": "ready"])
} catch {
    emit(["event": "error", "message": String(describing: error)])
    exit(1)
}

// Stop cleanly on Ctrl-C or SIGTERM so the aggregate device and tap are destroyed.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        tap.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// A missing permission looks like silence, so this is a hint on stderr, not a protocol event.
DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeoutS) {
    if !sawSignal {
        FileHandle.standardError.write(Data(
            "audio-tap: nothing above -100 dBFS in \(Int(silenceTimeoutS)) s. Either nothing is playing or the app running audio-tap lacks the System Audio Recording permission (System Settings > Privacy & Security).\n".utf8
        ))
    }
}

RunLoop.main.run()
