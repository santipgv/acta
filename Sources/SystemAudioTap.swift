import Foundation
import CoreAudio
import AVFoundation

/// Captura el audio que suena en el Mac (Zoom, Meet, Teams…) con Core Audio Process Taps.
/// No necesita BlackHole ni drivers virtuales. Requiere macOS 14.2 o superior.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "acta.systemtap", qos: .userInitiated)

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // 1. Tap global de todo el audio de salida, sin silenciarlo.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw ActaError.coreAudio("crear el tap de audio", err) }

        // 2. Formato del tap
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw ActaError.coreAudio("leer el formato del tap", err)
        }

        // 3. Dispositivo agregado privado que contiene el tap
        let outputUID = try Self.defaultOutputUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Acta-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard err == noErr else {
            stop()
            throw ActaError.coreAudio("crear el dispositivo agregado", err)
        }

        // 4. Callback de audio: los buffers van directos al transcriptor, nunca a disco.
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inInputData,
                                                deallocator: nil) else { return }
            onBuffer(buffer)
        }
        guard err == noErr else {
            stop()
            throw ActaError.coreAudio("registrar el callback de audio", err)
        }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            stop()
            throw ActaError.coreAudio("arrancar la captura del sistema", err)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard err == noErr else { throw ActaError.coreAudio("leer la salida de audio", err) }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw ActaError.coreAudio("leer el UID de la salida", err) }
        return uid as String
    }
}
