import AppKit
import ServiceManagement
import KildeCore

/// ポップオーバーの選択状態と、選択肢 (ディスプレイ・ウィンドウ・入力デバイス) の列挙 (issue #18)。
/// 選択 → 録画オプションの変換は KildeCore の `RecordRequest` に任せる (CLI と同じ解決規則)
@MainActor
final class RecordingSetup: ObservableObject {
    @Published var request: RecordRequest
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    /// 操作の結果 (保存しました / 開始できません 等) を一時的に出す
    @Published var notice: String?
    /// 保存先にある直近の録画 (issue #20)。新しい順
    @Published private(set) var recentRecordings: [URL] = []

    /// 一覧に出す件数。メニューを縦に伸ばさない範囲に留める
    private static let recentLimit = 5
    /// 最近の録画の走査の世代。遅れて返った古い走査で新しい一覧を上書きしないために使う
    private var recentGeneration = 0
    /// 最新の走査が完了したか。0 件のディレクトリと «まだ終わっていない» を区別する
    @Published private(set) var recentScanFinished = false

    /// ホットキー入力欄の編集中の値 (issue #20)。適用するまで config には書かない —
    /// 入力途中の "cmd+" のような不完全な文字列で登録を試みないため
    @Published var hotkeyDraft = ""

    /// 設定ファイル (~/.kilde/config.json) の内容。CLI と共有する (issue #14)
    private(set) var config = KildeConfig()

    /// 列挙の多重実行を防ぐ。UI の読み込み表示 (loading) はタイムアウトで解除して再試行を
    /// 許すが、SCShareableContent の列挙自体は止められない (権限プロンプト保留中は返らない
    /// こともある)。実列挙の完了まで次を始めず、その間の要求は記録して完了後に 1 回だけ再実行する
    /// (PR #45 で ContentView に入れた対策をモデルへ移したもの)
    private var enumerationInFlight = false
    private var needsReload = false
    private var hasLoadedOnce = false
    /// 列挙の世代。タイムアウト後に遅れて返ってきた古い結果 (一覧・サムネイル) を捨てるために使う
    private var generation = 0
    /// 実際に走っている列挙の数。タイムアウトしても SCShareableContent の列挙自体は止められないので、
    /// 上限を設けて「応答しない環境で更新を連打するとタスクが無限に積み上がる」のを防ぐ
    @Published private(set) var enumerationsRunning = 0
    private static let maxConcurrentEnumerations = 3
    /// 入力デバイスの列挙も、返らないことがある (デバイス構成の変更中)。1 本だけ走らせる
    private var audioEnumerationInFlight = false
    /// 入力デバイス列挙の世代。タイムアウト後に始めた新しい列挙の結果を、古い列挙が
    /// 上書きしないようにする (画面の列挙とは独立した世代で数える)
    private var audioGeneration = 0
    /// 実際に走っている入力デバイス列挙の数。タイムアウトでフラグを解放する以上、
    /// 上限を設けないと返らない環境でタスクが積み上がる (画面側と同じ扱い)
    private var audioEnumerationsRunning = 0

    private static let enumerationTimeout: TimeInterval = 10
    /// サムネイルを撮るウィンドウ数の上限 (1 枚ごとに SCScreenshotManager の撮影が走るため)
    private static let thumbnailLimit = 24
    private static let ownBundleID = Bundle.main.bundleIdentifier

    init() {
#if APPSTORE
        // **ConfigStore に触るより先に**設定の保存先をコンテナ内へ退避させる (issue #126)。
        // 既定の ~/.kilde はサンドボックス下で読み書きできないため
        SandboxSupport.redirectConfigStoreIntoContainer()
        // サンドボックス下の .moviesDirectory は **コンテナ内の** Movies を返す。
        // そのまま持ち回ると録画がコンテナに落ち、保存先の表示も通知の「Finder で表示」も
        // ユーザーがアクセスできないパスになり、App Store 審査で
        // Guideline 2.4.5(i) としてリジェクトされる (2026-09-17)。
        // 詳細は SandboxSupport.userVisibleMoviesDirectory()
        let fallback = SandboxSupport.userVisibleMoviesDirectory()
#else
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
#endif
        request = RecordRequest(outputDirectory: fallback)
        do {
            config = try ConfigStore.load()
        } catch {
            // 壊れた設定でも GUI 自体は開けるようにし、録画開始時に CLI と同じエラーを出す
            notice = "設定ファイルを読めません (既定値で表示します): \(error)"
        }
        request = RecordRequest.initial(config: config, fallbackDirectory: fallback)
#if APPSTORE
        // config.json に «コンテナ内のパス» が残っていることがある (リジェクトされた
        // 版で「既定にする」を押した場合)。ユーザーから見えるパスへ正規化してから
        // bookmark の復元にかける
        request.outputDirectory = SandboxSupport.userVisible(request.outputDirectory)
        // 前回 NSOpenPanel で選んだ保存先を bookmark から復元する (issue #126)。
        // サンドボックスでは設定ファイルで知ったパスにはアクセスできないため、
        // 選択で得たディレクトリだけを security-scoped bookmark で持ち越す。
        // **最後の request 再作成より後で行う** — 先に復元すると initial(config:) が
        // request を作り直して復元結果を上書きする (CodeRabbit レビュー指摘)
        if let restored = SandboxOutputDirectory.restore() {
            request.outputDirectory = restored
        } else if !FileManager.default.isWritableFile(atPath: request.outputDirectory.path) {
            // bookmark が無い・復元できない (外付けを外した等) とき、config に残った
            // 保存先はサンドボックスから開けないことがある。そのままだと録画のたびに
            // 開始前で失敗し、既定へ戻る手段もユーザーに見えない (cubic レビュー指摘)。
            // `isWritableFile` はサンドボックスの権限を反映する — movies エンタイトルメント
            // だけのとき ~/Movies=true, ~/Desktop=false になることを実測 (2026-09-18)
            request.outputDirectory = fallback
        }
#endif
        hotkeyDraft = config.hotkey ?? ""
    }

    // MARK: - 開始できるか (issue #20)

    /// 今の選択で録画を開始できない理由。`nil` なら開始できる。
    ///
    /// **開始ボタンとグローバルホットキーの両方がここを通る。** 判定を UI 側
    /// (`disabled` 修飾子) に置くと、ホットキーのようにボタンを経由しない経路が
    /// 素通りしてしまう — 実際 issue #20 の最初の実装がそうなっていて、
    /// **列挙中でも録画を始められる状態を作っていた**。issue #70 で実測したとおり、
    /// `SCShareableContent` の列挙と録画開始が競合すると両方が無期限にブロックするので、
    /// これは «行儀の悪い操作» ではなく実害のある経路になる。
    ///
    /// 文字列を返すのは、ホットキー経路が «なぜ始まらないか» を出す必要があるため
    /// (ボタンは押せないことで伝わるが、他アプリ前面で押したキーには何も見えない)
    func startBlockReason(permissions: PermissionsModel) -> String? {
        // SCK を使う構成でだけ列挙との競合を避ける (音声のみ + システム音声オフは競合しない)。
        // 判定は RecordRequest が持つ — ここに書き写すと Recorder 側とずれる (issue #72)
        let usesScreenCapture = request.usesScreenCapture
        // loading も列挙の状態なので SCK を使う構成にだけ効かせる。
        // 無条件に塞ぐと、**SCK を一切使わないマイクのみの録音まで画面列挙の完了待ちに
        // なる** — Recorder はその構成で SCK に触れないので、待たせる理由が無い
        if usesScreenCapture && loading {
            return "画面/ウィンドウの一覧を読み込み中です"
        }
        if usesScreenCapture && enumerationsRunning > 0 {
            return "画面/ウィンドウの列挙中です (録画開始と同時に行うと両方が止まります)"
        }
        if request.target == .audioOnly && request.audioSourceCount == 0 {
            return "音声ソースが選ばれていません (録れるものがありません)"
        }
        if !permissions.missing(for: request).isEmpty {
            return "権限が足りないため開始できません"
        }
        return nil
    }

    // MARK: - 録画オプション

    /// 現在の選択から録画オプションを作る。設定ファイルは CLI で変更されている可能性があるので
    /// 開始のたびに読み直す (壊れていれば CLI と同じく開始しない)
    func makeOptions() throws -> RecordOptions {
        config = try ConfigStore.load()
        return try request.makeOptions(config: config)
    }

    /// 選択中の音声ソース・トラック方針・保存先を設定ファイルの既定値にする (CLI の既定も変わる)
    func saveAsDefaults() {
        do {
            let updated = try request.savingDefaults(into: try ConfigStore.load())
            try ConfigStore.save(updated)
            config = updated
            notice = "既定値として保存しました (\(ConfigStore.fileURL.path))"
        } catch {
            notice = "既定値を保存できません: \(error)"
        }
    }

    /// ホットキーを設定ファイルに保存する (issue #20)。CLI の `hotkey` と同じキーなので、
    /// ここで設定すると `kilde rec` も待機モードで起動する。
    /// 空文字は «無効» として unset 相当にする。
    /// 保存前に `HotkeyParser` で検証する — 不正な値を書くと CLI 側が起動時に
    /// エラーになり、GUI から直せない状態に陥る
    /// 戻り値は保存できたか。**失敗したら呼び出し元は登録処理へ進んではいけない** —
    /// 進むと、旧ホットキーの解除だけが行われて何も登録されない状態になりうる
    /// 戻り値は `(保存できたか, 保存直前にファイルにあった hotkey)`。
    /// **巻き戻しには «保存直前の実際の値» を使う** — `setup.config.hotkey` は GUI 起動時に
    /// 読んだ値なので、その間に CLI (`kilde config set hotkey`) が変更していると、
    /// 巻き戻しで CLI の設定を古い値に上書きしてしまう
    func saveHotkey() -> (saved: Bool, previous: String?) {
        let trimmed = hotkeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var onDisk: String?
        do {
            if !trimmed.isEmpty {
                _ = try HotkeyParser.parse(trimmed)
            }
            var updated = try ConfigStore.load()
            onDisk = updated.hotkey
            updated.hotkey = trimmed.isEmpty ? nil : trimmed
            try ConfigStore.save(updated)
            config = updated
            hotkeyDraft = trimmed
            notice = trimmed.isEmpty
                ? "ホットキーを無効にしました"
                : "ホットキーを \(trimmed) に設定しました"
            return (true, onDisk)
        } catch {
            notice = "ホットキーを保存できません: \(error)"
            return (false, onDisk)
        }
    }

    /// 設定ファイルのホットキーを元の値へ戻す (登録に失敗したときの巻き戻し)。
    /// 設定だけ新しい値が残ると、次回の起動で **CLI も GUI も登録できない値**を読む
    func restoreHotkey(_ previous: String?) {
        do {
            var updated = try ConfigStore.load()
            updated.hotkey = previous
            try ConfigStore.save(updated)
            config = updated
            hotkeyDraft = previous ?? ""
        } catch {
            notice = "ホットキーの設定を元に戻せません: \(error)"
        }
    }

    // MARK: - ログイン時に起動 (issue #20)

    /// ログイン項目に登録されているか。`SMAppService` は状態を同期で返す。
    ///
    /// `.requiresApproval` も**登録済み**として扱う — 登録は成功していて、ユーザーの
    /// 承認待ちなだけ。false にすると登録直後に Toggle が未チェックへ戻り、
    /// 「押したのに効かない」ように見える (承認が要ることは notice で案内する)
    var launchesAtLogin: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// ログイン時起動の切り替え。
    ///
    /// **自動テストでは実行しない** — 登録は利用者のシステム設定 (ログイン項目) を
    /// 実際に書き換える副作用があり、検証のために環境を変えるのは筋が悪い。
    /// `.requiresApproval` はユーザーがシステム設定で承認するまで有効にならないので、
    /// «登録したのに起動しない» と見えないよう案内を出す
    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                notice = SMAppService.mainApp.status == .requiresApproval
                    ? "ログイン項目の承認が必要です (システム設定 → 一般 → ログイン項目 で許可してください)"
                    : "ログイン時に起動します"
            } else {
                try SMAppService.mainApp.unregister()
                notice = "ログイン時の起動を解除しました"
            }
            objectWillChange.send()
        } catch {
            notice = "ログイン項目を変更できません: \(error)"
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = request.outputDirectory
        panel.prompt = "選択"
        // LSUIElement のアプリはアクティブでないとパネルが他のウィンドウの後ろに出る
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
#if APPSTORE
            // 選択を bookmark に永続化して再起動後も使えるようにする (issue #126)。
            // 保存しないと、選んだ保存先が次回起動時には既定 (~/Movies) へ戻ってしまう。
            // **パネル由来の URL のアクセス可否はここで判定しない** — powerbox が
            // 開始済みで、重ねて start すると extension がリークする
            // (SandboxSupport.persist の説明。Codex レビュー指摘)
            SandboxOutputDirectory.persist(url)
#endif
            request.outputDirectory = url
            // 「最近の録画」は保存先を走査して作るので、変更したら取り直す。
            // 忘れると変更前のディレクトリの一覧が残り、クリックすると別の場所が開く
            reloadRecentRecordings()
        }
    }

    /// 設定ファイル・CLI の `device:<spec>` と同じ照合 (UID の完全一致、または名前の部分一致・
    /// 大文字小文字無視)。`AudioDeviceCatalog.resolveInput` と揃えないと、`device:BlackHole` が
    /// 実デバイス "BlackHole 2ch" に解決されているのに未選択と表示され、クリックすると元の指定を
    /// 残したまま UID を足して同じデバイスを二重に録ってしまう
    private func matches(_ spec: String, _ device: AudioDeviceInfo) -> Bool {
        spec == device.uid || device.name.localizedCaseInsensitiveContains(spec)
    }

    func isSelected(device: AudioDeviceInfo) -> Bool {
        request.inputDevices.contains { matches($0, device) }
    }

    func setSelected(_ selected: Bool, device: AudioDeviceInfo) {
        request.inputDevices.removeAll { matches($0, device) }
        if selected {
            // 追加は UID (完全一致) で入れるので、同名のデバイスがあっても取り違えない
            request.inputDevices.append(device.uid)
        }
    }

    // MARK: - 最近の録画 (issue #20)

    /// 保存先ディレクトリを走査して直近の録画を集める。
    ///
    /// セッションの履歴を別に持たずファイル名で拾うのは、**CLI で録ったファイルも
    /// 同じ一覧に出る**ため。kilde の既定名 (`defaultOutputName`) は
    /// `kilde-yyyyMMdd-HHmmss.{mov,mp4,m4a}` なので、この接頭辞と拡張子で絞る。
    /// `-o` で別名を付けた録画は拾えないが、一覧は補助表示なので取りこぼしを許容する
    /// (取り違えて無関係なファイルを出すより良い)
    func reloadRecentRecordings() {
        let directory = request.outputDirectory
        let extensions: Set<String> = ["mov", "mp4", "m4a"]
        // 画面の列挙と同じ理由で世代を数える — 保存先を変えて開き直したとき、
        // 前のディレクトリ (件数が多い・遅いボリューム) の走査が後から返ってきて
        // 新しい結果を古い一覧で上書きするのを防ぐ
        recentGeneration += 1
        let generation = recentGeneration
        // ファイル走査はディレクトリの中身が多いと待たされるので UI を止めない。
        // 失敗 (権限・存在しない) は空の一覧として扱う — 補助表示なのでエラーにしない
        let scan = Task.detached { [limit = Self.recentLimit] () -> [URL] in
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { return [] }
            return entries
                .filter { url in
                    url.lastPathComponent.hasPrefix("kilde-")
                        && extensions.contains(url.pathExtension.lowercased())
                        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return da > db
                }
                .prefix(limit)
                .map { $0 }
        }
        // 走査を始める前に一覧を空にする。**残したままだと、保存先を変えた直後の
        // 走査中に旧ディレクトリのファイルが操作可能なまま表示され、クリックすると
        // 旧ディレクトリが開く。** 画面の列挙 (apply) が古い一覧を残さないのと同じ理由
        recentRecordings = []
        recentScanFinished = false
        Task { [weak self] in
            let urls = await scan.value
            guard let self, generation == self.recentGeneration else { return }
            self.recentRecordings = urls
            // 走査が終わったことを «結果が空でないこと» で代用しない — 本当に 0 件の
            // ディレクトリと区別できず、検証側が無駄に待つことになる
            self.recentScanFinished = true
        }
    }

    // MARK: - 列挙

    func reload() {
        guard !enumerationInFlight else {
            // 初回ロード中の要求 (onAppear とポップオーバー表示通知の同時発火) は同じ結果になるので捨てる
            if hasLoadedOnce { needsReload = true }
            return
        }
        guard enumerationsRunning < Self.maxConcurrentEnumerations else {
            // 前の列挙が返ってこないまま上限に達した (権限プロンプト保留中など)。
            // enumerationsRunning は 0 に戻らないので、録画開始もこの間は止まる
            loadError = "画面/ウィンドウの列挙が応答しません。画面収録の権限確認が保留になっていないか確認してください"
            return
        }
        enumerationInFlight = true
        enumerationsRunning += 1
        loading = true
        generation += 1
        let generation = self.generation
        // 入力デバイスの列挙 (CoreAudio) は権限不要で普通は速いが、デバイス構成の変更中などに
        // ブロックすることがある。メニューバーの UI を止めないよう detached で回し、結果だけ反映する
        if !audioEnumerationInFlight, audioEnumerationsRunning < Self.maxConcurrentEnumerations {
            audioEnumerationInFlight = true
            audioEnumerationsRunning += 1
            audioGeneration += 1
            let audioGeneration = self.audioGeneration
            let audioTask = Task.detached { () -> [AudioDeviceInfo] in
                AudioDeviceCatalog.devices.filter { $0.inputChannels > 0 }
            }
            // 画面側と同じく、止められない列挙が実際に終わった時点で本数を戻す
            Task { [weak self] in
                _ = await audioTask.value
                self?.audioEnumerationsRunning -= 1
            }
            Task { [weak self] in
                let devices = await Self.value(of: audioTask, timeout: Self.enumerationTimeout)
                guard let self, audioGeneration == self.audioGeneration else { return }
                // タイムアウトでもフラグは解放する — 解放しないと、CoreAudio が返らない環境で
                // 入力デバイス一覧がアプリ再起動まで二度と更新されなくなる。
                // 世代で判定しているので、古い列挙が新しい結果を上書きすることはない
                self.audioEnumerationInFlight = false
                if let devices { self.inputDevices = devices }
            }
        }

        let enumerate = Task.detached { () -> Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error> in
            do { return .success(try await DisplayCatalog.snapshot()) }
            catch { return .failure(error) }
        }
        // タイムアウトしても列挙は止められないので、実際に完了した時点で本数を戻す
        Task { [weak self] in
            _ = await enumerate.value
            self?.enumerationsRunning -= 1
        }
        Task { [weak self] in
            let finished = await Self.value(of: enumerate, timeout: Self.enumerationTimeout)
            guard let self, generation == self.generation else { return }
            self.apply(finished, generation: generation)
            self.loading = false
            self.hasLoadedOnce = true
            // タイムアウトしても列挙状態は解放する — 解放しないと、権限プロンプト保留などで
            // 列挙タスクが返らない間は「更新」を押しても二度と一覧を取り直せない。
            // 遅れて返ってきた古い結果は世代で捨てるので、取り違えは起きない
            self.enumerationInFlight = false
            if self.needsReload {
                self.needsReload = false
                self.reload()
            }
        }
    }

    private func apply(_ result: Result<(displays: [DisplayInfo], windows: [WindowInfo]), Error>?,
                       generation: Int) {
        guard let result else {
            // 古い一覧を残したままタイムアウトのエラーを出すと、表示とエラーが食い違う
            displays = []
            windows = []
            loadError = "画面/ウィンドウの列挙がタイムアウトしました。画面収録の権限確認が保留になっていないか確認し、再度更新してください"
            return
        }
        switch result {
        case .success(let snapshot):
            loadError = nil
            displays = snapshot.displays
            windows = snapshot.windows
                .filter { window in
                    // メニューバーの項目やツールチップのような小さいもの・自分自身は収録対象にしない
                    window.isOnScreen && window.bundleIdentifier != nil
                        && window.bundleIdentifier != Self.ownBundleID
                        && window.frame.width >= 120 && window.frame.height >= 80
                }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            // 選択中の対象が消えていたら (ウィンドウが閉じた、ディスプレイが外れた) ディスプレイ 0 に戻す
            switch request.target {
            case .window(let id) where !windows.contains(where: { $0.windowID == id }):
                request.target = .display(index: 0)
            case .display(let index) where !displays.indices.contains(index):
                request.target = .display(index: 0)
            default:
                break
            }
            // 新しい一覧に古い画像を残さない (windowID は再利用されるので、別のウィンドウの
            // 見た目で選んでしまう)。取得できるまでプレースホルダを出す
            thumbnails = [:]
            loadThumbnails(generation: generation)
        case .failure(let error):
            // 画面収録の権限が無いとここに来る (オンボーディングは issue #19)
            displays = []
            windows = []
            loadError = "画面/ウィンドウの列挙に失敗しました (画面収録の権限を確認してください): \(error)"
        }
    }

    private func loadThumbnails(generation: Int) {
        let ids = windows.prefix(Self.thumbnailLimit).map(\.windowID)
        Task.detached {
            let images = await DisplayCatalog.windowThumbnails(windowIDs: ids)
            let converted = images.mapValues { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run { [weak self] in
                // 短い間隔で更新すると古い取得が後から終わることがある。今の一覧に
                // 古い画像を貼ると、見た目で別のウィンドウを選んでしまうので捨てる
                guard let self, generation == self.generation else { return }
                self.thumbnails = converted
            }
        }
    }

    /// タスクの完了とタイムアウトの先着を返す (タイムアウトなら nil)。
    /// withTaskGroup はスコープを抜けるときに全子タスクの完了を待つので、止められない列挙の
    /// await を子に置くとタイムアウト後も戻らない。そのためポーリングで先着を拾う
    private static func value<T>(of task: Task<T, Never>, timeout: TimeInterval) async -> T? {
        let box = ResultBox<T>()
        let watcher = Task { box.store(await task.value) }
        defer { watcher.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = box.load() { return value }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return box.load()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func store(_ newValue: T) {
            lock.lock(); defer { lock.unlock() }
            if value == nil { value = newValue }
        }

        func load() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
