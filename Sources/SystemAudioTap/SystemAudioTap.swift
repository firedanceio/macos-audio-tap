// Copyright 2026 Firedance Multimedia LLC
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreAudio
import Foundation

public enum SystemAudioTapError: Error, CustomStringConvertible {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case propertyReadFailed(OSStatus)

    public var description: String {
        switch self {
        case .tapCreationFailed(let s): return "tap creation failed (OSStatus \(s))"
        case .aggregateDeviceCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
        case .ioProcCreationFailed(let s): return "IOProc creation failed (OSStatus \(s))"
        case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
        case .propertyReadFailed(let s): return "property read failed (OSStatus \(s))"
        }
    }
}

/// One level sample: wall-clock time and RMS level in dBFS.
public struct AudioLevelSample: Sendable {
    public let timestampMs: Int64
    public let dbfs: Double
}

/// Taps everything playing through the default output device and reports its level.
///
/// The tap is a whole-system Core Audio process tap (empty process list, exclusive) wrapped in a
/// private aggregate device backed by the default output device. RMS is computed on every buffer on
/// the real-time thread without allocating; only the throttled `onLevel` delivery leaves it.
/// Raw audio never leaves this class.
///
/// Permission: capture needs the "System Audio Recording" (audio capture) privacy grant. Without
/// it, setup still succeeds and the tap delivers silent buffers, so a caller cannot tell denial
/// from a quiet room by API result alone.
public final class SystemAudioTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()

    private let emitInterval: TimeInterval
    private var lastEmitTime: TimeInterval = 0
    private var deliveryQueue: DispatchQueue = .main

    /// Throttled level samples, delivered on the queue passed to `start(on:)`. Do not block.
    public var onLevel: ((AudioLevelSample) -> Void)?

    /// The new default output device's name, delivered on the queue passed to
    /// `startObservingOutputDeviceChanges(on:)`. Works without the tap running and without the
    /// audio-capture grant, since it reads device metadata only.
    public var onOutputDeviceChanged: ((String) -> Void)?

    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputDeviceListenerQueue: DispatchQueue?

    /// - Parameter emitIntervalMs: minimum time between `onLevel` calls.
    public init(emitIntervalMs: Int = 100) {
        self.emitInterval = Double(emitIntervalMs) / 1000.0
    }

    deinit {
        stop()
        stopObservingOutputDeviceChanges()
    }

    // MARK: Output device changes

    public func startObservingOutputDeviceChanges(on queue: DispatchQueue = .main) {
        // Core Audio removes a listener by block identity, so register at most one.
        guard outputDeviceListenerBlock == nil else { return }
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  let deviceID = try? Self.readDefaultSystemOutputDevice(),
                  let name = try? Self.readStringProperty(deviceID, kAudioObjectPropertyName) else { return }
            self.onOutputDeviceChanged?(name)
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr else { return }
        outputDeviceListenerBlock = block
        outputDeviceListenerQueue = queue
    }

    public func stopObservingOutputDeviceChanges() {
        guard let block = outputDeviceListenerBlock else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, outputDeviceListenerQueue ?? .main, block)
        outputDeviceListenerBlock = nil
        outputDeviceListenerQueue = nil
    }

    // MARK: Tap lifecycle

    /// Creates the tap and its aggregate device. Call before `start(on:)`.
    public func prepare() throws {
        let description = CATapDescription()
        description.name = "macos-audio-tap"
        description.uuid = UUID()
        // Empty process list + exclusive = every process playing through the default output.
        description.processes = []
        description.isExclusive = true
        description.isPrivate = true
        description.isMixdown = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw SystemAudioTapError.tapCreationFailed(status) }
        tapID = newTapID

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapFormat)
        guard status == noErr else { throw SystemAudioTapError.propertyReadFailed(status) }

        // Back the aggregate with the real output device and hand it the tap at creation time.
        // An aggregate with an empty sub-device list, or a tap list set after creation, can fail at
        // AudioDeviceStart with kAudioHardwareIllegalOperationError ('nope') on some hosts.
        let outputUID = try Self.readStringProperty(try Self.readDefaultSystemOutputDevice(), kAudioDevicePropertyDeviceUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "macos-audio-tap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: description.uuid.uuidString,
            ]],
        ]
        var newAggregateID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else { throw SystemAudioTapError.aggregateDeviceCreationFailed(status) }
        aggregateDeviceID = newAggregateID
    }

    /// Starts capture. `onLevel` is delivered on `queue`.
    public func start(on queue: DispatchQueue) throws {
        deliveryQueue = queue
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            { _, _, inInputData, _, _, _, inClientData -> OSStatus in
                guard let inClientData else { return noErr }
                Unmanaged<SystemAudioTap>.fromOpaque(inClientData).takeUnretainedValue().handleIOProc(inInputData)
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &procID
        )
        guard status == noErr, let procID else { throw SystemAudioTapError.ioProcCreationFailed(status) }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else { throw SystemAudioTapError.deviceStartFailed(startStatus) }
    }

    /// Stops capture and destroys the aggregate device and tap. Safe to call more than once.
    public func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: Real-time path

    private func handleIOProc(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffer = inputData.pointee.mBuffers
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        let samples = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float32.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        )
        let dbfs = Self.dbfs(of: samples)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEmitTime >= emitInterval else { return }
        lastEmitTime = now
        let sample = AudioLevelSample(timestampMs: Int64(Date().timeIntervalSince1970 * 1000), dbfs: dbfs)
        deliveryQueue.async { [weak self] in self?.onLevel?(sample) }
    }

    /// RMS level of 32-bit float PCM (the format process taps deliver) in dBFS; `-infinity` for silence.
    public static func dbfs(of samples: UnsafeBufferPointer<Float32>) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var sumOfSquares = 0.0
        for s in samples { sumOfSquares += Double(s) * Double(s) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    // MARK: Property helpers

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        var address = defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw SystemAudioTapError.propertyReadFailed(status) }
        return deviceID
    }

    private static func readStringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw SystemAudioTapError.propertyReadFailed(status) }
        return value as String
    }
}
