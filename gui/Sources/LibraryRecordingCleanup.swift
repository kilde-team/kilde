import Foundation
import KildeCore

/// ライブラリから録画を «ゴミ箱へ移動» する整理の導線 (issue #523) のデータ層。
/// UI (LibraryWindow.swift) とセルフテスト (SelfTestLibraryDelete) から使う。
///
/// «消す» ではなく «ゴミ箱に入れる» を採る理由: Finder の «ゴミ箱に戻す» で
/// 復元できるため、誤操作に安全 (確認ダイアログと合わせて 2 重の安全装置)。
/// «壊れたファイルを残さない» の逆向き («消しすぎない») を守るため、録画本体が
/// 移せなかったときはサイドカーに触らず投げて戻す — «本体が残ってサイドカー
/// だけ消える» という半端な状態を作らない。
///
/// UI 側 (LibraryView) は @MainActor だが、この enum は Pure 表示の
/// SpotlightItemFactory と同じ «グローバルアクター推論の無い» 素の enum でよい —
/// 中身は引数とファイルシステムだけで決まり、UI の状態に触れない
enum LibraryRecordingCleanup {

    /// ゴミ箱移動 1 件の実行者。`FileManager.trashItem` の差し替えポイント —
    /// セルフテストは **実環境のゴミ箱を汚さない** よう、移動先を一時ディレクトリに
    /// 変えた実装を注入する (UI は既定の `systemTrasher` を使う)。
    /// 戻り値は «ゴミ箱に入った後の URL» (現状の呼び出し側では使わないが、
    /// «どこへ行ったか» をテストで確かめるために返す)
    typealias Trasher = (URL) throws -> URL

    /// 既定のゴミ箱移動 (Finder の «ゴミ箱に入れる» と同じ)。
    /// サンドボックス下でも、アプリに書き込み権限のあるファイル
    /// (~/Movies は `movies.read-write`、カスタム保存先は security-scoped
    /// bookmark の有効中) ならシステムが移動を仲介する。権限が無い・
    /// ネットワークボリューム等で失敗したときは throw し、呼び出し側が
    /// «Finder で削除してください» の案内を出す (黙って失敗しない)
    static let systemTrasher: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL? ?? url
    }

    /// «この録画のもの» である伴走ファイル (録画本体を除く) を収集する。
    ///
    /// 対応規則は `RecordingSetup.transcriptSidecar` と同じ:
    /// - stem が一致するサイドカー (`kilde-20261110-090000.json` ↔ `.mov`)
    /// - 枝番サイドカー (`…-2.json` — 再文字越しの退避。«-数字» だけを見る)
    ///
    /// 拡張子は **サイドカーの 5 形式** (TranscriptOutputFormat —
    /// `RecordingSetup.transcriptSidecarExtensions`) に絞る。絞らないと
    /// «同じ stem の別録画» (動画と取り込み音声のペア等) まで連れていかす。
    /// 要約込みの議事録 (.md) もこの 5 形式に含まれるため、«録画 + 文字越し +
    /// 議事録» が一式で移る。ユーザーが同じフォルダに保存した書き出し
    /// (txt / srt / vtt) も同じ stem なら «この録画のもの» として一緒に移る
    ///
    /// 録画本体は戻り値に含めない (`moveToTrash` の `recording` と二重に渡すのを
    /// 避けるため)。呼び出し側のサンドボックス権限の取得は UI 側の責務 —
    /// この関数は与えられたディレクトリをそのまま読む
    static func companionFiles(forRecording recordingURL: URL, in directory: URL) -> [URL] {
        let stem = recordingURL.deletingPathExtension().lastPathComponent
        let suffixSeparator = stem + "-"
        let transcriptExtensions = RecordingSetup.transcriptSidecarExtensions
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return all.filter { url in
            guard url != recordingURL else { return false }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return false }
            guard transcriptExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            let candidate = url.deletingPathExtension().lastPathComponent
            if candidate == stem { return true }
            guard candidate.hasPrefix(suffixSeparator) else { return false }
            let digits = candidate.dropFirst(suffixSeparator.count)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 録画と伴走ファイルをゴミ箱へ移す。
    ///
    /// **録画本体を最初に移し**、これが失敗したら (書き込み権限が無い、
    /// ファイルが既に無い等) 何も移さずに throw する。成功したら伴走ファイルを
    /// 順に移す — こちらは 1 件の失敗で打ち切らず最後まで試す
    /// («本体は消えたので残ったサイドカーだけ案内する» のが、録画の再試行で
    /// «-2» の重複サイドカーが生えるよりまし、という判断)
    ///
    /// - Returns: ゴミ箱へ移せなかった伴走ファイル (空配列 = 全件移動完了)。
    ///   録画本体の失敗は throw で返るため、戻り値に録画本体は含まれない
    static func moveToTrash(
        recording: URL, companionFiles: [URL], trasher: Trasher
    ) throws -> [URL] {
        _ = try trasher(recording)
        var leftovers: [URL] = []
        for companion in companionFiles {
            do {
                _ = try trasher(companion)
            } catch {
                leftovers.append(companion)
            }
        }
        return leftovers
    }
}
