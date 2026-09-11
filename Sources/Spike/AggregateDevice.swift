import Foundation
import CoreAudio

// S4: 「既定出力 + BlackHole」のマルチ出力 (aggregate) デバイスの作成/破棄/既定切替

enum MonitorDevice {
    static let uid = "kilde-spike-monitor-001"
    static let name = "kilde Monitor (spike)"

    /// 既存の kilde Monitor を破棄してから作り直す
    static func create(masterUID: String, memberUIDs: [String]) throws -> AudioObjectID {
        destroy()
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            // Audio MIDI Setup の「複数出力装置」と同じく、非公開の stacked フラグで
            // 全サブデバイスに同時出力するマルチ出力デバイスにする
            "stacked": true,
            kAudioAggregateDeviceSubDeviceListKey: memberUIDs.map { [kAudioSubDeviceUIDKey: $0] },
            kAudioAggregateDeviceMasterSubDeviceKey: masterUID,
        ]
        var newID = AudioObjectID(0)
        let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
        guard err == noErr else {
            throw SpikeError("マルチ出力デバイス作成失敗 (OSStatus=\(err))")
        }
        return newID
    }

    @discardableResult
    static func destroy() -> Bool {
        guard let existing = AudioHAL.devices.first(where: { $0.uid == uid }) else { return false }
        return AudioHardwareDestroyAggregateDevice(existing.id) == noErr
    }

    static var exists: Bool {
        AudioHAL.devices.contains { $0.uid == uid }
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &v
        ) == noErr
    }
}
