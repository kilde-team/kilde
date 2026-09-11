import Foundation
import ArgumentParser
import KildeCore

extension ConfigKey: ExpressibleByArgument {}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "設定ファイル (~/.kilde/config.json) の表示・変更",
        discussion: """
        設定値は kilde rec の既定値になります。優先順位は
        CLI 引数 > --preset > 環境変数 (KILDE_OUTPUT_DIR) > 設定ファイル > 既定値 です。
        """,
        subcommands: [Show.self, SetValue.self, Unset.self, Path.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "現在の設定と既定値を表示")

        func run() {
            let config: KildeConfig
            do {
                config = try ConfigStore.load()
            } catch {
                cliError(error)
            }
            print("# \(ConfigStore.fileURL.path)")
            for key in ConfigKey.allCases {
                if let v = config.value(for: key) {
                    print("\(key.rawValue) = \(v)")
                } else {
                    print("\(key.rawValue) = (未設定 — 既定: \(key.defaultDescription))")
                }
            }
            if let dir = ProcessInfo.processInfo.environment[RecordSettings.outputDirectoryEnvironmentKey],
               !dir.isEmpty {
                print("# 環境変数 \(RecordSettings.outputDirectoryEnvironmentKey)=\(dir) が outputDirectory より優先されます")
            }
        }
    }

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "設定値を変更 (defaultAudioSources はカンマ区切り。例: system,mic)"
        )

        @Argument(help: "設定キー")
        var key: ConfigKey

        @Argument(help: "値")
        var value: String

        // 不正値は引数検証エラー (終了コード 64) として、ファイルを書き換える前に弾く
        func validate() throws {
            var probe = KildeConfig()
            do {
                try probe.set(key, value)
            } catch {
                throw ValidationError("\(error)")
            }
        }

        func run() {
            do {
                var config = try ConfigStore.load()
                try config.set(key, value)
                try ConfigStore.save(config)
                print("\(key.rawValue) = \(config.value(for: key) ?? "")")
            } catch {
                cliError(error)
            }
        }
    }

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "設定値を削除して既定値に戻す")

        @Argument(help: "設定キー")
        var key: ConfigKey

        func run() {
            do {
                var config = try ConfigStore.load()
                config.unset(key)
                try ConfigStore.save(config)
                print("\(key.rawValue) = (未設定 — 既定: \(key.defaultDescription))")
            } catch {
                cliError(error)
            }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "設定ファイルのパスを表示")

        func run() {
            print(ConfigStore.fileURL.path)
        }
    }
}
