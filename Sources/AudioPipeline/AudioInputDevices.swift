import Foundation

// The input-device picker is macOS-only (docs/15 step 36 remainder): iOS
// routes input through the system audio session, and Linux/CI compile none
// of CoreAudio.
#if os(macOS)
import CoreAudio

/// One selectable capture device, identified by its stable hardware UID —
/// `AudioDeviceID`s are session-scoped and must never be persisted.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public var uid: String
    public var name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// CoreAudio enumeration for the Settings picker, and UID → device
/// resolution for the capture engine. Every failure degrades to "no
/// devices" / nil — the system default keeps working regardless.
public enum AudioInputDevices {

    /// All devices that can capture audio, in system order.
    public static func available() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// The live `AudioDeviceID` for a persisted UID, if that device is
    /// currently connected and can capture.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceID in
            hasInputStreams(deviceID)
                && stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
#endif
