import CoreAudio

/// 入力デバイス（マイク）。
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        let system = AudioHardwareSystem.shared
        guard let devices = try? system.devices else { return [] }
        return devices.compactMap { device in
            let hasInput = ((try? device.streams) ?? []).contains { (try? $0.direction) == .input }
            guard hasInput, let uid = try? device.uid else { return nil }
            return AudioInputDevice(id: device.id, uid: uid, name: (try? device.name) ?? uid)
        }
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let device = try? AudioHardwareSystem.shared.defaultInputDevice, let uid = try? device.uid else {
            return nil
        }
        return AudioInputDevice(id: device.id, uid: uid, name: (try? device.name) ?? uid)
    }

    static func device(uid: String) -> AudioObjectID? {
        (try? AudioHardwareSystem.shared.device(forUID: uid))?.id
    }

    static func defaultOutputDeviceUID() -> String? {
        try? AudioHardwareSystem.shared.defaultOutputDevice?.uid
    }
}
