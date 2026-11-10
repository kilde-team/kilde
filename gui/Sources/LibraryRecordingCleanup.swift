import Foundation
import KildeCore

/// ライブラリから録画を «ゴミ箱へ移動» する整理の導線 (issue #523) のデータ層。
/// UI (LibraryWindow.swift) とセルフテスト (SelfTestLibraryDelete) から使う。
///
/// «消す» ではなく «ゴミ箱に入れる» を採る理由: Finder の «ゴミ箱に戻す» で
/// 復元できるため、誤操作に安全 (確認ダイアログと合わせて 2 重の安全装置)。
/// «壊れたファイルを残さない» の逆向き («消しすぎない») を守るため、録画本体が
/// 移せなかったときはサイドカーに触らず投げて戻す — «本体が残ってサイドカー
/// だけ消える» という半端な状態を作らない。**保存先フォルダが読めなかったときも
/// 何も移さない** — «サイドカーの候補が分からない» 状態で本体だけ移すと、
/// 残ったサイドカーが次の走査で «文字起こしの無い録画» に見えてしまう
/// (cubic レビュー指摘 — issue #523 の PR #524 レビュー)
///
/// UI 側 (LibraryView) は @MainActor だが、この enum は Pure 表示の
/// SpotlightItemFactory と同じ «グローバルアクター推論の無い» 素の enum でよい —
/// 中身は引数とファイルシステムだけで決まり、UI の状態に触れない
enum LibraryRecordingCleanup {

    /// ゴミ箱移動の失敗。UI は «保存先を読めなかった» を他の失敗と区別して
    /// 案内する (フォルダが消えた・権限が落ちた可能性を伝える)
    enum CleanupError: Error {
        /// 保存先フォルダの走査に失敗した (何も移さずに戻る)
        case directoryUnreadable
    }

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
    /// - 枝番サイドカー (`…-2.json` — 再文字起こしの退避。«-数字» だけを見る)
    ///
    /// ただし **別の録画が自分の stem で主張しているサイドカーは対象外** にする
    /// (CodeRabbit 指摘 — issue #523 の PR #524 レビュー)。ライブラリは
    /// `kilde-…-2.m4a` のような «枝番の stem を持つ別録画» も 1 録画として
    /// 一覧に載せる (`LibraryIndex.scan` は録画形式のファイルをすべて載せる) ため、
    /// `kilde-…-2.json` は «この録画の枝番サイドカー» と «その録画自身のサイドカー»
    /// の両方の候補になりうる。録画本体 (サイドカー形式でないファイル) の stem と
    /// 一致したらそちらのものとして残す — «消しすぎない» を優先し、削除側で
    /// あいまいさを解決する。同じ stem の録画が 2 つ (mov と取り込み音声の m4a 等)
    /// ある場合も同様で、exact-stem のサイドカーは «残っている方の録画» に
    /// 残る (両方消すなら 2 回に分けて消えるので、2 回目で主張が消えて回収される)
    ///
    /// 拡張子は **サイドカーの 5 形式** (TranscriptOutputFormat —
    /// `RecordingSetup.transcriptSidecarExtensions`) に絞る。絞らないと
    /// «同じ stem の別録画» (動画と取り込み音声のペア等) まで連れていかす。
    /// 要約込みの議事録 (.md) もこの 5 形式に含まれるため、«録画 + 文字起こし +
    /// 議事録» が一式で移る。ユーザーが同じフォルダに保存した書き出し
    /// (txt / srt / vtt) も同じ stem なら «この録画のもの» として一緒に移る
    ///
    /// 録画本体は戻り値に含めない (`moveToTrash` の `recording` と二重に渡すのを
    /// 避けるため)。呼び出し側のサンドボックス権限の取得は UI 側の責務 —
    /// この関数は与えられたディレクトリをそのまま読む
    ///
    /// - Throws: `CleanupError.directoryUnreadable` — フォルダの走査に失敗した
    ///   とき。空配列で «伴走なし» と誤認させない (本体だけ移す失敗を作らない)
    static func companionFiles(forRecording recordingURL: URL, in directory: URL) throws -> [URL] {
        let stem = recordingURL.deletingPathExtension().lastPathComponent
        let suffixSeparator = stem + "-"
        let transcriptExtensions = RecordingSetup.transcriptSidecarExtensions
        let all: [URL]
        do {
            all = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        } catch {
            // 生の NSError をそのまま投げると呼び出し側が «読めなかった» を
            // 区別できず、«Finder で削除してください» の案内に化ける
            // (CodeRabbit レビュー指摘、issue #525 の PR #526 レビュー) ので、
            // ここで CleanupError へ畳む
            throw CleanupError.directoryUnreadable
        }
        // «録画の stem» の集合 (この録画以外の、**一覧に載る録画形式** の通常ファイル)。
        // «別録画» の判定は LibraryStore.scan と同じ録画形式で絞る — 絞らないと
        // «kilde-a.log が kilde-a.json を主張する» ような、録画でないファイルに
        // サイドカーを守られて «一緒に移れない» ことがある (cubic レビュー指摘)。
        // キャンセル等で読めないファイルは仕方なく無視する (best-effort の絞り込み)
        let recordingStems = Set(all
            .filter { url in
                guard !isSameFile(url, recordingURL) else { return false }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return false }
                return LibraryStore.recordingExtensions.contains(url.pathExtension.lowercased())
            }
            .map { $0.deletingPathExtension().lastPathComponent })
        // «候補のサイドカーを、この録画以外の録画がライブラリの対応規則で
        // 自分のものにするか»。transcriptSidecar は «stem 完全一致» と
        // «stem-数字 の枝番» の両方で対応づけるので、守る対象もその両方:
        // - 候補の stem が別録画の stem と一致 (mov と取り込み音声 m4a の二重録画が
        //   同じサイドカーを一覧で共有するケース)
        // - 候補の stem が «別録画の stem-数字» (二重録画が枝番サイドカーを
        //   共有するケース — CodeRabbit レビュー指摘、issue #525 の PR #526 レビュー)
        // 守られたサイドカーは伴走に含めない — «消した録画の代わりに、残った
        // 録画が文字越しを失う» を起こさないため。
        // 判定は候補ごとに «末尾の -数字 を 1 回剥がした親 stem» を Set で照合する —
        // 候補ごとに全 stem を走査すると録画数に対して O(N²) になるため
        // (cubic レビュー指摘)。«R-数字» に一致する R は、候補の末尾の
        // -数字 を剥がしたものに限られる (R 自体は数字で終わらない)
        func isClaimedByOtherRecording(_ candidateStem: String) -> Bool {
            if recordingStems.contains(candidateStem) { return true }
            guard let range = candidateStem.range(of: "-[0-9]+$", options: .regularExpression)
            else { return false }
            let parentStem = String(candidateStem[..<range.lowerBound])
            return recordingStems.contains(parentStem)
        }
        return all.filter { url in
            guard !isSameFile(url, recordingURL) else { return false }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return false }
            guard transcriptExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            let candidate = url.deletingPathExtension().lastPathComponent
            if isClaimedByOtherRecording(candidate) { return false }
            if candidate == stem { return true }
            guard candidate.hasPrefix(suffixSeparator) else { return false }
            let digits = candidate.dropFirst(suffixSeparator.count)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 2 つの URL が同じファイルを指すか。**symlink を解決してから比べる** —
    /// temporaryDirectory (`/var/folders/…`) と contentsOfDirectory の返す表記
    /// (`/private/var/folders/…`) は URL 同士の等価で false になるため
    /// (LibraryView.isSameDirectory と同じ正規化。表記が混ざると «録画本体の除外»
    /// が効かず、録画自身が «自分の stem を主張する別録画» に見えてサイドカーを
    /// 1 件も集められなくなる)。«録画中・文字起こし中» の判定 (LibraryView と
    /// TranscriptionCoordinator.isQueuedOrRunningSameFile) でも同じ理由で使う
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
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
