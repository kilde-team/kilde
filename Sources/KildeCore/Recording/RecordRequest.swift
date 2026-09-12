import Foundation

/// GUI などが「何をどこへ録るか」を組み立てるための入力 (issue #18)。
///
/// 音声ソース・トラック方針・コーデック等の解決は CLI と同じ `RecordSettings.apply()` に通すので、
/// GUI から始めた録画も CLI と同じ規則で `RecordOptions` になり、同じ `Recorder` で録られる。
/// 選択 → オプションの変換をここ (KildeCore) に置くのは、GUI 側に録画のロジックを持たせない
/// ため (CLAUDE.md §3 のレイヤ規約) と、単体テストで検証できるようにするため
public struct RecordRequest: Equatable {
    public enum Target: Hashable {
        /// `kilde devices` のディスプレイ番号
        case display(index: Int)
        /// SCWindow の windowID
        case window(id: UInt32)
        /// 録音 (音声のみ)
        case audioOnly
    }

    public var target: Target = .display(index: 0)
    public var captureSystemAudio = true
    public var captureMic = false
    /// 追加で録る入力デバイス (`--audio device:<spec>` の spec。UID の完全一致か名前の部分一致)
    public var inputDevices: [String] = []
    public var trackPolicy: AudioTrackPolicy = .mixed
    /// 保存先ディレクトリ。GUI はカレントディレクトリが / になるので、CLI と違って必ず明示する
    public var outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    public var wantsVideo: Bool { target != .audioOnly }

    /// `--audio` と同じ表現の音声ソース列。何も選ばれていなければ ["none"]
    public var audioSourceStrings: [String] {
        var list: [String] = []
        if captureSystemAudio { list.append("system") }
        if captureMic { list.append("mic") }
        list += inputDevices.map { "device:\($0)" }
        return list.isEmpty ? ["none"] : list
    }

    /// 選ばれている音声ソースの数 (トラック方針の選択が意味を持つのは 2 つ以上のとき)
    public var audioSourceCount: Int {
        (captureSystemAudio ? 1 : 0) + (captureMic ? 1 : 0) + inputDevices.count
    }

    /// 設定ファイルの既定値から初期状態を作る。設定に保存先が無い・存在しない場合は fallbackDirectory
    public static func initial(config: KildeConfig, fallbackDirectory: URL) -> RecordRequest {
        var request = RecordRequest(outputDirectory: fallbackDirectory)
        if let list = config.defaultAudioSources {
            request.captureSystemAudio = list.contains("system")
            request.captureMic = list.contains("mic")
            request.inputDevices = list.compactMap { source in
                source.hasPrefix("device:") ? String(source.dropFirst("device:".count)) : nil
            }
        }
        if let name = config.audioTracks, let policy = AudioTrackPolicy(name: name) {
            request.trackPolicy = policy
        }
        if let dir = config.outputDirectory {
            let url = URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
            if isDirectory(url) {
                request.outputDirectory = url
            }
        }
        return request
    }

    /// 録画オプションを組み立てる。設定ファイルの codec / fps / showsCursor もここで反映される
    public func makeOptions(config: KildeConfig) throws -> RecordOptions {
        var options = RecordOptions()
        switch target {
        case .display(let index):
            options.displayIndex = index
        case .window(let id):
            // DisplayCatalog.resolveWindow は windowID の完全一致を最優先するので、
            // タイトルに同じ数字を含む別ウィンドウに取り違えられない
            options.windowMatch = String(id)
        case .audioOnly:
            break
        }
        options.wantsVideo = wantsVideo
        // 出力パスを明示すると RecordSettings.apply は保存先の存在を確認しないので、ここで確認する
        guard Self.isDirectory(outputDirectory) else {
            throw KilError.failed("保存先ディレクトリが存在しません: \(outputDirectory.path)")
        }
        var overrides = RecordOverrides()
        overrides.audio = audioSourceStrings
        overrides.audioTracks = trackPolicy.name
        overrides.outputPath = Self.availableOutputURL(
            in: outputDirectory, ext: wantsVideo ? "mov" : "m4a").path
        // GUI を起動元の環境変数に依存させない (KILDE_OUTPUT_DIR は CLI 用)
        try RecordSettings.apply(overrides, config: config, environment: [:], to: &options)
        return options
    }

    /// 空いている出力名を選ぶ。既定名は秒までしか持たないので、短い録画を止めてすぐ録り直すと
    /// 同じ名前になり、`MovieWriter` が既存ファイルを消してしまう (直前の録画が失われる)。
    /// 衝突したら `kilde-….mov` → `kilde-…-2.mov` のように連番を付ける
    static func availableOutputURL(in directory: URL, ext: String) -> URL {
        let base = defaultOutputName(ext: ext)
        let first = directory.appendingPathComponent(base)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let stem = (base as NSString).deletingPathExtension
        for suffix in 2...999 {
            let candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    /// 現在の選択 (音声ソース・トラック方針・保存先) を既定値として書き込んだ設定を返す。
    /// 保存は呼び出し側で `ConfigStore.save()` する。codec 等の他の項目は触らない
    public func savingDefaults(into config: KildeConfig) throws -> KildeConfig {
        var updated = config
        updated.defaultAudioSources = audioSourceStrings
        updated.audioTracks = trackPolicy.name
        updated.outputDirectory = outputDirectory.path
        // 存在しないディレクトリを既定に書くと、`KildeConfig.validate()` は形式しか見ないので保存でき、
        // 次回の `initial()` が黙って fallback に戻す (「保存したのに効かない」)。書く前に弾く
        guard Self.isDirectory(outputDirectory) else {
            throw KilError.failed("保存先ディレクトリが存在しません: \(outputDirectory.path)")
        }
        try updated.validate()
        return updated
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

extension AudioTrackPolicy: Hashable {
    /// 設定ファイル・`--audio-tracks` と同じ表現
    public var name: String {
        switch self {
        case .mixed: return "mixed"
        case .separate: return "separate"
        }
    }
}
