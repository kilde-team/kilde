import Foundation
import CoreAudio

// CoreAudio HAL の最小ヘルパ (S4: マルチ出力デバイス検証の土台)

struct AudioDeviceInfo {
    let id: AudioObjectID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int

    var isBlackHole: Bool {
        name.contains("BlackHole")
    }

    var kind: String {
        if isBlackHole { return "blackhole" }
        if inputChannels > 0 && outputChannels > 0 { return "aggregate?" }
        if inputChannels > 0 { return "input" }
        return "output"
    }
}

enum AudioHAL {
    static var devices: [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(info)
    }

    static func info(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let name = stringProperty(kAudioDevicePropertyDeviceNameCFString, id),
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, id) else { return nil }
        return AudioDeviceInfo(
            id: id,
            name: name,
            uid: uid,
            inputChannels: streamChannels(id, input: true),
            outputChannels: streamChannels(id, input: false)
        )
    }

    static var defaultOutput: AudioDeviceInfo? {
        device(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static var defaultInput: AudioDeviceInfo? {
        device(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return info(id)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard err == noErr else { return nil }
        return cf as String
    }

    private static func streamChannels(_ id: AudioObjectID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &buf) == noErr else { return 0 }
        return buf.withUnsafeBytes { raw -> Int in
            let list = raw.bindMemory(to: AudioBufferList.self)
            guard let abl = list.baseAddress else { return 0 }
            // AudioBufferList.mBuffers は可変長配列。先頭アドレスから AudioBuffer として数える
            let buffersPtr = UnsafeRawPointer(abl)
                + MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
            let ab = buffersPtr.assumingMemoryBound(to: AudioBuffer.self)
            var n = 0
            for i in 0..<Int(abl.pointee.mNumberBuffers) {
                n += Int(ab[i].mNumberChannels)
            }
            return n
        }
    }
}
