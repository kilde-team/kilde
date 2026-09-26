import AVFoundation
import Foundation
import KildeCore

/// 文字起こしの断続的な失敗の «自動再試行» の判定規則のセルフテスト
/// (KILDE_GUI_SELFTEST_TRANSCRIBE_RETRY=1、issue #221)。
///
///     KILDE_GUI_SELFTEST_TRANSCRIBE_RETRY=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画・実文字起こしを伴わない** (録画のスロットを占有しない)。-12203 の発生は
/// 断続的で外から引き起こせないため、このテストは «どのエラーを自動再試行の対象に
/// するか» の規則 (`TranscriptionCoordinator.isTransientRetryable`) を合成エラーで
/// 機械的に縛る:
/// - 観測されたシグネチャ (NSOSStatusErrorDomain の -12203。直接と underlying 経由の
///   両方) は再試行する
/// - よく似た未観測のコード、キャンセル、TranscriptionError、他ドメインのエラーは
///   再試行しない
///
/// 全ケースが通れば終了コード 0、1 件でも外れれば 1 (SelfTestMeeting と同じ合否)。
extension SelfTest {
    @MainActor
    static func reportTranscriptionRetryRules() -> Never {
        struct RuleCase {
            let name: String
            let error: Error
            let expected: Bool
        }
        // 観測の中心: «操作を完了できませんでした。（OSStatusエラー-12203）»
        // (issue #221) のNSError。NSOSStatusErrorDomain の生の形を想定している
        let osStatus = NSError(domain: NSOSStatusErrorDomain, code: -12203)
        // describe() は _underlyingError を掘って見せるため、観測された文言が
        // «ラッパーの underlying» 由来の可能性もある — どちらの形でも再試行する規約
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: osStatus])
        let cases: [RuleCase] = [
            RuleCase(name: "観測された -12203 (直接) は再試行する",
                     error: osStatus, expected: true),
            RuleCase(name: "underlying に -12203 を持つエラーも再試行する",
                     error: wrapped, expected: true),
            RuleCase(name: "よく似た未観測のコード (-12204) は再試行しない",
                     error: NSError(domain: NSOSStatusErrorDomain, code: -12204),
                     expected: false),
            RuleCase(name: "他ドメインの同じコードは再試行しない",
                     error: NSError(domain: NSPOSIXErrorDomain, code: -12203),
                     expected: false),
            RuleCase(name: "AVFoundation のエラーは再試行しない",
                     error: NSError(domain: AVFoundationErrorDomain, code: -11800),
                     expected: false),
            RuleCase(name: "ファイル I/O の Cocoa エラーは再試行しない",
                     error: NSError(domain: NSCocoaErrorDomain,
                                    code: NSFileWriteUnknownError),
                     expected: false),
            RuleCase(name: "CancellationError («中止») は再試行しない",
                     error: CancellationError(), expected: false),
            RuleCase(name: "TranscriptionError.cancelled も再試行しない",
                     error: TranscriptionError.cancelled(partialSegments: []),
                     expected: false),
            RuleCase(name: "TranscriptionError の決定的な失敗は再試行しない",
                     error: TranscriptionError.failed("テスト用のエンジン失敗"),
                     expected: false),
            RuleCase(name: "モデル未取得も再試行しない (ダウンロードの再実行は手動)",
                     error: TranscriptionError.modelNotInstalled("ja-JP"),
                     expected: false),
        ]
        var failures = 0
        for ruleCase in cases {
            let actual = TranscriptionCoordinator.isTransientRetryable(ruleCase.error)
            let mark = actual == ruleCase.expected ? "ok" : "FAIL"
            print("selftest: retry-rule[\(mark)] \(ruleCase.name) → \(actual)")
            if actual != ruleCase.expected { failures += 1 }
        }
        print("selftest: retry-rule failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
