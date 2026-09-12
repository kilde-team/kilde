import Foundation
import CoreAudio

public struct AudioDeviceInfo {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int

    public var isBlackHole: Bool { name.contains("BlackHole") }

    public var kind: String {
        if isBlackHole { return "blackhole" }
        if inputChannels > 0 && outputChannels > 0 { return "in+out" }
        if inputChannels > 0 { return "input" }
        return "output"
    }
}

/// CoreAudio HAL のヘルパ (DESIGN.md §4 DeviceCatalog / §8 AudioRouter)
public enum AudioDeviceCatalog {

    public static var devices: [AudioDeviceInfo] {
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

    public static var defaultOutput: AudioDeviceInfo? {
        device(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static var defaultInput: AudioDeviceInfo? {
        device(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static var hasBlackHole: Bool {
        devices.contains { $0.isBlackHole }
    }

    /// 入力デバイスを名前 (部分一致) または UID で解決する
    public static func resolveInput(_ spec: String) throws -> AudioDeviceInfo {
        let inputs = devices.filter { $0.inputChannels > 0 }
        if let byUID = inputs.first(where: { $0.uid == spec }) {
            return byUID
        }
        if let byName = inputs.first(where: { $0.name.localizedCaseInsensitiveContains(spec) }) {
            return byName
        }
        let list = inputs.map { "  \($0.name) (uid=\($0.uid))" }.joined(separator: "\n")
        throw KilError.deviceNotFound("入力デバイス \"\(spec)\" が見つかりません。利用可能:\n\(list)")
    }

    // MARK: - 内部

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

    private static func info(_ id: AudioObjectID) -> AudioDeviceInfo? {
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

    private static func stringProperty(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        // CoreAudio の CFString プロパティは +1 (呼び出し側が解放責任を持つ) で返る。
        // ARC 管理の変数のアドレスに直接書き込ませると (a) +1 分が解放されず漏れる、
        // (b) ARC の解放と噛み合わず二重解放の恐れ、があるため Unmanaged で受けて
        // takeRetainedValue() で所有権を Swift に移す (issue #49。
        // 2026-09-12 に実測で +1 を確認 — 解放せずに読んだ retainCount は増えず、
        // takeRetainedValue を大量に呼んでも落ちない)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard err == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
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
            // AudioBufferList.mBuffers は可変長配列。先頭から AudioBuffer として数える
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

/// 「既定出力 + BlackHole」のマルチ出力 (multi-output) デバイス (DESIGN.md §8)
public enum MonitorDevice {
    public static let uid = "kilde-monitor"
    public static let name = "kilde Monitor"

    /// 既定出力と BlackHole でマルチ出力デバイスを作成し、既定出力に設定する。
    /// 元の既定出力を state に保存する (teardown で復元)。
    /// 既に kilde Monitor が存在する場合は解体してから作り直す (冪等)。
    public static func setup() throws -> AudioDeviceInfo {
        let recovery = "システム設定で既定出力を戻し、Audio MIDI 設定で \"kilde Monitor\" を削除してから再実行してください"
        // 復元できないまま作り直すと kilde Monitor 自身を子にした自己参照になるため中止する
        if try exists && !teardown() {
            throw KilError.failed("既存の kilde Monitor を解体できませんでした。\(recovery)")
        }
        guard let currentDefault = AudioDeviceCatalog.defaultOutput else {
            throw KilError.failed("既定出力デバイスを取得できません")
        }
        // CoreAudio の状態反映遅延などで自己参照が残っている場合も、安全に復旧できるまで作成しない
        guard currentDefault.uid != uid else {
            throw KilError.failed("既定出力が kilde Monitor のままです。\(recovery)")
        }
        guard let blackhole = AudioDeviceCatalog.devices.first(where: { $0.isBlackHole && $0.outputChannels > 0 })
        else {
            throw KilError.deviceNotFound(
                "BlackHole が見つかりません。`brew install --cask blackhole-2ch` で導入してください"
            )
        }
        destroy()
        let id = try create(masterUID: currentDefault.uid, memberUIDs: [currentDefault.uid, blackhole.uid])
        // 既定出力の切替に失敗したら復元を試み、復元できた場合のみデバイスを削除する
        guard setDefaultOutput(id) else {
            if setDefaultOutput(currentDefault.id) {
                destroy()
                throw KilError.failed("既定出力の切り替えに失敗しました")
            }
            throw KilError.failed(
                "既定出力の切り替えと復元の両方に失敗しました。kilde Monitor が既定のまま残っています — システム設定で手動確認してください"
            )
        }
        do {
            try saveState(originalDefaultUID: currentDefault.uid)
        } catch {
            if setDefaultOutput(currentDefault.id) {
                destroy()
                throw KilError.failed("状態の保存に失敗したためロールバックしました: \(error.localizedDescription)")
            }
            throw KilError.failed(
                "状態の保存と復元の両方に失敗しました — システム設定で手動確認してください"
            )
        }
        return AudioDeviceCatalog.devices.first { $0.uid == uid } ?? currentDefault
    }

    /// state から元の既定出力に戻し、マルチ出力デバイスを削除する。
    /// 復元や削除に失敗した場合は state を残す (再試行できるように)。
    /// KILDE_CONFIG_DIR が相対パスのときは、カレントディレクトリの state を
    /// 読み書きしてしまうためエラーにする (saveState と同じ基準)。
    @discardableResult
    public static func teardown() throws -> Bool {
        try ConfigStore.checkConfigDirectoryEnvironment()
        guard let original = try loadState() else { return false }
        guard let orig = AudioDeviceCatalog.devices.first(where: { $0.uid == original }) else {
            return false  // 元デバイスが消失 — 手動での復旧が必要
        }
        guard setDefaultOutput(orig.id) else { return false }
        let destroyed = destroy()
        if destroyed { try removeState() }
        return destroyed
    }

    public static var exists: Bool {
        AudioDeviceCatalog.devices.contains { $0.uid == uid }
    }

    // MARK: - 内部 (CoreAudio)

    /// Audio MIDI Setup の「複数出力装置」と同じく、非公開の stacked フラグで
    /// 全サブデバイスに同時出力する (SPIKE-NOTES F-C)
    private static func create(masterUID: String, memberUIDs: [String]) throws -> AudioObjectID {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            "stacked": true,
            kAudioAggregateDeviceSubDeviceListKey: memberUIDs.map { [kAudioSubDeviceUIDKey: $0] },
            kAudioAggregateDeviceMasterSubDeviceKey: masterUID,
        ]
        var newID = AudioObjectID(0)
        let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
        guard err == noErr else {
            throw KilError.failed("マルチ出力デバイスの作成に失敗 (OSStatus=\(err))")
        }
        return newID
    }

    @discardableResult
    private static func destroy() -> Bool {
        guard let existing = AudioDeviceCatalog.devices.first(where: { $0.uid == uid }) else { return false }
        return AudioHardwareDestroyAggregateDevice(existing.id) == noErr
    }

    @discardableResult
    private static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
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

    // MARK: - state (~/.kilde/monitor-state.json)

    /// state の保存先を設定と同じ規則で解決する。別々に解決すると config と state が
    /// 異なる場所へ分かれ得るため、ConfigStore の共通関数に委ねる。
    static func stateDirectory(environment: [String: String]) -> URL {
        ConfigStore.configDirectory(environment: environment)
    }

    /// state の保存先。単体テストでは実環境の state を壊さないよう差し替える。
    static var stateDirectory = stateDirectory(environment: ProcessInfo.processInfo.environment)

    private static var stateURL: URL { stateDirectory.appendingPathComponent("monitor-state.json") }

    private struct State: Codable { var originalDefaultOutputUID: String }

    static func saveState(originalDefaultUID: String) throws {
        // state も KILDE_CONFIG_DIR 由来なので、相対パスは設定と同じ理由で拒否する
        // (ConfigStore.checkConfigDirectoryEnvironment 経由)
        try ConfigStore.checkConfigDirectoryEnvironment()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let state = State(originalDefaultOutputUID: originalDefaultUID)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    static func loadState() throws -> String? {
        // 相対 KILDE_CONFIG_DIR の state を黙って「存在しない」と扱うと、teardown が
        // 何もせず成功したように見える — 環境の誤りはエラーとして扱う
        try ConfigStore.checkConfigDirectoryEnvironment()
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return state.originalDefaultOutputUID
    }

    static func removeState() throws {
        try ConfigStore.checkConfigDirectoryEnvironment()
        try? FileManager.default.removeItem(at: stateURL)
    }
}
