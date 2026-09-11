import Foundation
import AppKit

// GUI を持たない CLI プロセスからの SCK ウィンドウ収録が
// CGS_REQUIRE_INIT で落ちるため、WindowServer 上で正規の (accessory) アプリとして初期化する
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"
let args = Args(Array(argv.dropFirst()))

switch cmd {
case "doctor": Doctor().run()
case "devices": DevicesCmd().run()
case "inspect": InspectCmd(args: args).run()
case "rec-system": RecSystemCmd(args: args).run()
case "rec-audio-only": RecAudioOnlyCmd(args: args).run()
case "rec-device": RecDeviceCmd(args: args).run()
case "rec-window": RecWindowCmd(args: args).run()
case "monitor": MonitorCmd(args: args).run()
default:
    print("""
    kilde M0 spike — DESIGN.md §11 の検証用ツール

    USAGE: spike <command> [options]

    commands:
      doctor                    権限と環境の診断 (S6)
      devices                   ディスプレイ / ウィンドウ / オーディオ機器の一覧
      inspect <file>            録画ファイルのトラック構成と音声レベルを表示
      rec-system  [opts]        ディスプレイ + システム音声の録画 (S1/S2/S3/S5)
          --duration <N[s|m]>   長さ (既定 6s)
          --output <path>       出力先
          --mic                 マイクも同時録音 (S2: PTS オフセット測定)
          --display <idx>       ディスプレイ番号
      rec-audio-only [opts]     SCK で音声のみ取得できるか (S8)
          --with-screen-output  .screen 出力も受ける比較モード
          --match <text>        ウィンドウ (アプリ) 単位の音声スコープ (S9)
      rec-device   [opts]       任意の入力デバイスから録音 (S4 の BlackHole 検証)
          --device <uid>        デバイス UID
      rec-window  [opts]        ウィンドウ収録と音声スコープの検証 (S9)
          --match <text>        ウィンドウの title / bundleID の部分一致
      monitor     <sub>         マルチ出力デバイスの作成/削除 (S4)
          status | setup | teardown
    """)
    if cmd != "help" { exit(64) }
}
