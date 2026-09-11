import Foundation

// MARK: - 設定ファイル (~/.kilde/config.json) — issue #14 / DESIGN.md §9
//
// CLI と GUI (M3) で出力先・既定ソースを共有するため KildeCore に置く。
// 値は JSON 上でも CLI 引数と同じ文字列表現で持つ (手で編集しやすく、
// `kilde rec --help` の説明がそのまま設定ファイルにも通じるようにするため)。

/// 設定ファイルの内容。すべて省略可能で、未設定の項目は既定値 (または CLI 引数) に委ねる。
public struct KildeConfig: Codable, Equatable, Sendable {
    /// 出力先パスを省略したときの保存先ディレクトリ (絶対パスまたは ~ 始まり)
    public var outputDirectory: String?
    /// `--audio` 省略時の音声ソース (例: ["system", "mic"]。["none"] で音声なし)
    public var defaultAudioSources: [String]?
    /// `--audio-tracks` 省略時の値 (mixed / separate)
    public var audioTracks: String?
    /// `--codec` 省略時の値 (h264 / hevc / prores)
    public var codec: String?
    /// `--fps` 省略時の上限フレームレート
    public var fps: Int?
    /// カーソルを写し込むか (`--cursor` / `--no-cursor` 省略時)
    public var showsCursor: Bool?
    /// グローバルホットキー。issue #10 で使う予定の予約項目で、現時点では保存するだけ
    public var hotkey: String?

    public init(outputDirectory: String? = nil, defaultAudioSources: [String]? = nil,
                audioTracks: String? = nil, codec: String? = nil, fps: Int? = nil,
                showsCursor: Bool? = nil, hotkey: String? = nil) {
        self.outputDirectory = outputDirectory
        self.defaultAudioSources = defaultAudioSources
        self.audioTracks = audioTracks
        self.codec = codec
        self.fps = fps
        self.showsCursor = showsCursor
        self.hotkey = hotkey
    }
}

/// 設定項目のキー。rawValue は JSON のキー名と `kilde config set <key>` の key を兼ねる
public enum ConfigKey: String, CaseIterable, Sendable {
    case outputDirectory
    case defaultAudioSources
    case audioTracks
    case codec
    case fps
    case showsCursor
    case hotkey

    /// 未設定のときに使われる値の説明 (`kilde config show` 用)
    public var defaultDescription: String {
        switch self {
        case .outputDirectory: return "カレントディレクトリ"
        case .defaultAudioSources: return "system"
        case .audioTracks: return "mixed"
        case .codec: return "h264"
        case .fps: return "ディスプレイのリフレッシュレートに追従"
        case .showsCursor: return "true"
        case .hotkey: return "なし (issue #10 で対応予定)"
        }
    }
}

extension KildeConfig {
    /// 文字列の値を検証して設定する (`kilde config set`)。
    /// defaultAudioSources はカンマ区切り (例: "system,mic")。
    public mutating func set(_ key: ConfigKey, _ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch key {
        case .outputDirectory:
            try Self.checkOutputDirectory(value)
            outputDirectory = value
        case .defaultAudioSources:
            let list = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            _ = try AudioSourceSpec.parseList(list)
            defaultAudioSources = list
        case .audioTracks:
            guard AudioTrackPolicy(name: value) != nil else {
                throw KilError.failed("audioTracks は mixed か separate を指定してください: \(value)")
            }
            audioTracks = value
        case .codec:
            guard VideoCodecKind(rawValue: value) != nil else {
                throw KilError.failed("codec は h264 / hevc / prores を指定してください: \(value)")
            }
            codec = value
        case .fps:
            guard let n = Int(value), n > 0 else {
                throw KilError.failed("fps は 1 以上の整数を指定してください: \(value)")
            }
            fps = n
        case .showsCursor:
            switch value.lowercased() {
            case "true", "yes", "1": showsCursor = true
            case "false", "no", "0": showsCursor = false
            default: throw KilError.failed("showsCursor は true か false を指定してください: \(value)")
            }
        case .hotkey:
            guard !value.isEmpty else { throw KilError.failed("hotkey が空です") }
            hotkey = value
        }
    }

    public mutating func unset(_ key: ConfigKey) {
        switch key {
        case .outputDirectory: outputDirectory = nil
        case .defaultAudioSources: defaultAudioSources = nil
        case .audioTracks: audioTracks = nil
        case .codec: codec = nil
        case .fps: fps = nil
        case .showsCursor: showsCursor = nil
        case .hotkey: hotkey = nil
        }
    }

    /// 設定値の文字列表現 (`kilde config show`)。未設定は nil
    public func value(for key: ConfigKey) -> String? {
        switch key {
        case .outputDirectory: return outputDirectory
        case .defaultAudioSources: return defaultAudioSources?.joined(separator: ",")
        case .audioTracks: return audioTracks
        case .codec: return codec
        case .fps: return fps.map(String.init)
        case .showsCursor: return showsCursor.map { $0 ? "true" : "false" }
        case .hotkey: return hotkey
        }
    }

    /// 手で編集された設定ファイルも `set` と同じ基準で検証する。
    /// 不正値を黙って既定値に倒すと「設定したのに効かない」原因が分からなくなるため、エラーにする
    public func validate() throws {
        for key in ConfigKey.allCases {
            if key == .defaultAudioSources, let list = defaultAudioSources {
                // デバイス名にカンマを含むこともあり得るので、join し直さず配列のまま検証する
                _ = try AudioSourceSpec.parseList(list)
            } else if let v = value(for: key) {
                var probe = KildeConfig()
                try probe.set(key, v)
            }
        }
    }

    /// 設定ファイルは GUI (カレントディレクトリが / になる) とも共有するため、相対パスを禁止する
    static func checkOutputDirectory(_ value: String) throws {
        guard !value.isEmpty else { throw KilError.failed("outputDirectory が空です") }
        guard NSString(string: value).expandingTildeInPath.hasPrefix("/") else {
            throw KilError.failed("outputDirectory は絶対パスか ~ 始まりで指定してください: \(value)")
        }
    }
}

// MARK: - 音声ソース・トラック方針の文字列表現 (CLI 引数と設定ファイルで共通)

extension AudioSourceSpec {
    /// "system" / "mic" / "device:<名前orUID>" を解釈する。"none" はリスト側 (`parseList`) で扱う
    public static func parse(_ s: String) -> AudioSourceSpec? {
        switch s {
        case "system": return .system
        case "mic": return .mic
        default:
            guard s.hasPrefix("device:") else { return nil }
            let name = String(s.dropFirst("device:".count))
            return name.isEmpty ? nil : .device(name)
        }
    }

    /// 音声ソースの並びを解釈する。["none"] は「音声なし」で空配列を返す。
    /// none と他のソースの併用・空の並びはエラー
    public static func parseList(_ list: [String]) throws -> [AudioSourceSpec] {
        guard !list.isEmpty else {
            throw KilError.failed("音声ソースが空です (音声なしは none を指定してください)")
        }
        if list.contains("none") {
            guard list.allSatisfy({ $0 == "none" }) else {
                throw KilError.failed("音声ソース none は他のソースと併用できません")
            }
            return []
        }
        return try list.map { s in
            guard let spec = parse(s) else {
                throw KilError.failed("音声ソースの値が不正: \(s) (system / mic / device:<名前> / none)")
            }
            return spec
        }
    }
}

extension AudioTrackPolicy {
    public init?(name: String) {
        switch name {
        case "mixed": self = .mixed
        case "separate": self = .separate
        default: return nil
        }
    }
}

// MARK: - 読み書き

public enum ConfigStore {
    /// 設定の保存先。monitor-state.json と同じ ~/.kilde を使う。
    /// 単体テストでは実環境の設定を壊さないよう一時ディレクトリに差し替える
    public static var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kilde", isDirectory: true)

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// 設定ファイルを読む。ファイルが無ければ空の設定 (すべて既定値)。
    /// 壊れた JSON・未知のキー・不正値はエラーにする (typo が黙って無視されるのを防ぐ)
    public static func load() throws -> KildeConfig {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return KildeConfig() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KilError.failed("設定ファイルを読み込めません: \(url.path) (\(error.localizedDescription))")
        }
        return try decode(data, path: url.path)
    }

    static func decode(_ data: Data, path: String) throws -> KildeConfig {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KilError.failed("設定ファイルが JSON として不正です: \(path)")
        }
        guard let dict = object as? [String: Any] else {
            throw KilError.failed("設定ファイルの最上位は JSON オブジェクトにしてください: \(path)")
        }
        let known = Set(ConfigKey.allCases.map(\.rawValue))
        if let unknown = dict.keys.sorted().first(where: { !known.contains($0) }) {
            throw KilError.failed("設定ファイルに未知のキーがあります: \(unknown) (\(path))。"
                + "有効なキー: \(ConfigKey.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let config: KildeConfig
        do {
            config = try JSONDecoder().decode(KildeConfig.self, from: data)
        } catch {
            throw KilError.failed("設定ファイルの値の型が不正です: \(path) (\(error))")
        }
        do {
            try config.validate()
        } catch let e as KilError {
            throw KilError.failed("設定ファイルの値が不正です (\(path)): \(e)")
        }
        return config
    }

    public static func save(_ config: KildeConfig) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            throw KilError.failed("設定ファイルを保存できません: \(fileURL.path) (\(error.localizedDescription))")
        }
    }
}

// MARK: - rec の既定値の解決

/// `kilde rec` で CLI 引数として明示された値。未指定は nil
public struct RecordOverrides: Sendable {
    public var outputPath: String?
    /// `--audio` の並び。空なら未指定
    public var audio: [String] = []
    public var audioTracks: String?
    public var codec: String?
    public var fps: Int?
    public var showsCursor: Bool?
    /// `--preset meeting` (system + mic をミックス)
    public var meetingPreset = false

    public init() {}
}

public enum RecordSettings {
    /// 出力先ディレクトリを上書きする環境変数 (issue #14 の「必要最小限」の環境変数)
    public static let outputDirectoryEnvironmentKey = "KILDE_OUTPUT_DIR"

    /// 優先順位 **CLI 引数 > プリセット > 環境変数 > 設定ファイル > 既定値** で
    /// 音声ソース・トラック方針・コーデック・fps・カーソル・出力先を決め、options に反映する。
    /// プリセットは CLI で明示的に選ぶものなので設定ファイルより強い。
    /// `options.wantsVideo` は拡張子 (.mov / .m4a) の決定に使うため、先に設定しておくこと
    public static func apply(_ o: RecordOverrides, config: KildeConfig,
                             environment: [String: String],
                             to options: inout RecordOptions) throws {
        if !o.audio.isEmpty {
            options.audioSources = try AudioSourceSpec.parseList(o.audio)
        } else if o.meetingPreset {
            options.audioSources = [.system, .mic]
        } else if let list = config.defaultAudioSources {
            options.audioSources = try AudioSourceSpec.parseList(list)
        } else {
            options.audioSources = [.system]
        }

        if let name = o.audioTracks ?? (o.meetingPreset ? "mixed" : config.audioTracks) {
            guard let policy = AudioTrackPolicy(name: name) else {
                throw KilError.failed("audioTracks は mixed か separate を指定してください: \(name)")
            }
            options.trackPolicy = policy
        } else {
            options.trackPolicy = .mixed
        }

        if let name = o.codec ?? config.codec {
            guard let codec = VideoCodecKind(rawValue: name) else {
                throw KilError.failed("codec は h264 / hevc / prores を指定してください: \(name)")
            }
            options.codec = codec
        } else {
            options.codec = .h264
        }

        options.fps = o.fps ?? config.fps
        options.showsCursor = o.showsCursor ?? config.showsCursor ?? true

        if !options.wantsVideo && options.audioSources.isEmpty {
            throw KilError.failed("映像なし (--no-video) で音声ソースも none のため、録れるものがありません")
        }

        let url = outputURL(explicitPath: o.outputPath, config: config,
                            environment: environment, wantsVideo: options.wantsVideo)
        if o.outputPath == nil {
            // 環境変数・設定ファイル由来の保存先は typo に気付きにくい。AVAssetWriter は存在しない
            // ディレクトリでも録画を始めてしまい、停止時に初めて失敗する (実測: 2 秒録った後に
            // "Cannot create file" で終了コード 1)。録画を始める前に弾く
            let dir = url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw KilError.failed("出力先ディレクトリが存在しません: \(dir.path) "
                    + "(\(outputDirectoryEnvironmentKey) または設定 outputDirectory を確認してください)")
            }
        }
        options.outputURL = url
    }

    /// 出力先を一度だけ解決する。表示と Recorder が同一 URL を使うため
    /// (defaultOutputName を別々に評価すると秒の境界で不一致になり得る)
    static func outputURL(explicitPath: String?, config: KildeConfig,
                          environment: [String: String], wantsVideo: Bool) -> URL {
        if let path = explicitPath {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        let name = defaultOutputName(ext: wantsVideo ? "mov" : "m4a")
        let envDir = environment[outputDirectoryEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        guard let dir = envDir ?? config.outputDirectory else {
            return URL(fileURLWithPath: name)
        }
        return URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(name)
    }
}
