//
//  MicrophoneManager.swift
//  LoopMac
//
//  Enumerates CoreAudio input devices and lets the user pin Loop to a
//  specific one (mirroring how System Settings ▸ Sound ▸ Input picks a mic).
//  Persists the user's choice by device UID (stable across reboots, unlike
//  the runtime AudioDeviceID), and applies that choice to AVAudioEngine
//  before each recording starts.
//

import AppKit
import AVFoundation
import CoreAudio

/// Lightweight projection of a CoreAudio input device — UID + name + the
/// runtime AudioDeviceID needed to point AVAudioEngine at it.
struct MicrophoneDevice: Equatable {
    /// Stable across reboots — what we persist. CoreAudio's "device UID"
    /// (often vendor:product:serial). Used to look the device back up after
    /// an unplug/replug.
    let uid: String
    /// Human-readable name shown in the Mic settings window. Matches what
    /// macOS displays in System Settings.
    let name: String
    /// CoreAudio runtime id — unstable across reboots; only valid for this
    /// app session. Captured at enumeration time so the audio unit
    /// `CurrentDevice` property can be set without a second lookup.
    let deviceID: AudioDeviceID
}

extension Notification.Name {
    /// Posted whenever the user picks a different input device (or reverts to
    /// system default). The Mic settings window observes this so a second
    /// instance of the window stays in sync; VoiceLoopCoordinator reads the
    /// latest value on the next `beginEngine` so an in-flight recording
    /// finishes on the previous device but the next one starts on the new
    /// one.
    static let microphoneSelectionChanged = Notification.Name("loop.audio.microphoneSelectionChanged")
}

final class MicrophoneManager {

    static let shared = MicrophoneManager()

    /// UserDefaults key for the persisted device UID. Nil = "follow the
    /// system default", which is the same behavior as before this feature
    /// existed.
    private let defaultsKey = "loop.audio.selectedInputUID"

    private init() {}

    // MARK: - Persisted selection

    /// The UID the user has pinned, if any. Setting to nil reverts to the
    /// system default; broadcasts `microphoneSelectionChanged` on every
    /// change so listeners can refresh.
    var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            NotificationCenter.default.post(name: .microphoneSelectionChanged, object: nil)
        }
    }

    // MARK: - Enumeration

    /// All currently-attached input-capable devices, ordered the same way
    /// CoreAudio reports them (which roughly tracks the order they show up
    /// in System Settings).
    func inputDevices() -> [MicrophoneDevice] {
        var deviceIDs: [AudioDeviceID] = []
        var size: UInt32 = 0

        var devicesProp = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // First pass: how many devices.
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProp,
            0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        deviceIDs = Array(repeating: AudioDeviceID(), count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProp,
            0, nil, &size,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var results: [MicrophoneDevice] = []
        for id in deviceIDs {
            guard deviceHasInputStreams(id) else { continue }
            guard let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: id, selector: kAudioObjectPropertyName) else {
                continue
            }
            // Hide macOS-internal aggregate devices. CoreAudio auto-creates
            // a transient "CADefaultDeviceAggregate-<pid>-<n>" whenever
            // multiple processes are using the default mic; it shows up in
            // the device list but isn't something the user picked or would
            // recognize. Filtering by the well-known name prefix is safer
            // than blanket-dropping all aggregates, since the user might
            // have intentionally created an aggregate device in Audio MIDI
            // Setup that they want to use.
            if name.hasPrefix("CADefaultDeviceAggregate") { continue }
            results.append(MicrophoneDevice(uid: uid, name: name, deviceID: id))
        }
        return results
    }

    /// Returns the device CoreAudio currently considers the default input.
    /// Used by the settings UI to label which row "System default" maps to.
    func systemDefaultInput() -> MicrophoneDevice? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &prop,
            0, nil, &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        guard let uid = stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(of: deviceID, selector: kAudioObjectPropertyName) else {
            return nil
        }
        return MicrophoneDevice(uid: uid, name: name, deviceID: deviceID)
    }

    /// The device that the next recording will actually use — either the
    /// user-pinned one (if it's still attached) or the system default.
    func effectiveInput() -> MicrophoneDevice? {
        if let pinned = selectedUID {
            if let match = inputDevices().first(where: { $0.uid == pinned }) {
                return match
            }
            // Pinned device disappeared (unplugged / sleep race). Fall
            // through to system default rather than silently failing.
        }
        return systemDefaultInput()
    }

    // MARK: - Apply to AVAudioEngine

    /// Point the audio engine's input node at the user-pinned device. Must
    /// be called *before* `engine.prepare()` / `engine.start()` — once the
    /// engine is running, CoreAudio rejects the property change.
    ///
    /// No-op when the user hasn't pinned anything: AVAudioEngine inherits
    /// the system default, which is what we want.
    func applySelectedInput(to engine: AVAudioEngine) {
        guard let uid = selectedUID else { return }
        guard let device = inputDevices().first(where: { $0.uid == uid }) else {
            print("⚠️ Microphone: pinned device \(uid) not found — using system default.")
            return
        }
        var deviceID = device.deviceID
        // `inputNode.audioUnit` is force-unwrapped in Apple's own samples;
        // it's nil only if the engine has never been touched, which can't
        // be the case by the time we reach here.
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("⚠️ Microphone: failed to set input device (status=\(status)).")
        }
    }

    // MARK: - CoreAudio helpers

    /// Returns true if the device exposes at least one input stream — i.e.
    /// it can record. Filters out headphones, speakers, virtual outputs.
    private func deviceHasInputStreams(_ device: AudioDeviceID) -> Bool {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }

        let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufList.deallocate() }
        status = AudioObjectGetPropertyData(device, &prop, 0, nil, &size, bufList)
        guard status == noErr else { return false }

        let abl = bufList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        for buf in bufs where buf.mNumberChannels > 0 {
            return true
        }
        return false
    }

    /// Read a CoreAudio string property (CFString) and bridge it back. Used
    /// for `kAudioDevicePropertyDeviceUID` and `kAudioObjectPropertyName`.
    private func stringProperty(of device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var prop = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(device, &prop, 0, nil, &size, ptr)
        }
        guard status == noErr, let str = cfString else { return nil }
        return str as String
    }
}
