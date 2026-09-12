import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
// HEVC Main10 のプロファイル定数 (kVTProfileLevel_HEVC_Main10_AutoLevel) は
// AVFoundation ではなく VideoToolbox 側にある (issue #16)
import VideoToolbox

/// AVAssetWriter ラッパ。
/// - 映像あり: 最初の映像サンプル PTS をセッション開始 (アンカー) にする
/// - 音声のみ: 最初の音声サンプル PTS をアンカーにする
/// - macOS 26 の AVFoundation は outputSettings に幅・高さが必須 (SPIKE-NOTES F-D.2)
final class MovieWriter {

    enum Anchor { case firstVideo, firstAudio }

    enum OutputFilePolicy {
        /// 明示パスは CLI の従来契約として上書きする。
        case overwrite
        /// 既定名は、自分が原子的に作った予約ファイルだけを置き換える。
        case reserved(OutputFileReservation)
        /// 予約も明示的な上書き指定もない呼び出し元は、既存ファイルを保護する。
        case rejectExisting
    }

    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let audioInputs: [String: AVAssetWriterInput]
    let anchor: Anchor
    let url: URL

    private let lock = NSLock()
    private(set) var sessionStarted = false
    private var sessionStartTime: CMTime?
    private(set) var videoAppended = 0
    private(set) var videoDropped = 0
    private(set) var audioAppended: [String: Int] = [:]
    private(set) var audioDropped: [String: Int] = [:]
    private(set) var firstVideoPTS: CMTime?
    private(set) var lastVideoPTS: CMTime?
    private(set) var firstAudioPTS: [String: CMTime] = [:]
    private(set) var lastAudioPTS: [String: CMTime] = [:]
    /// 一時停止していた合計 (issue #11)。append する PTS からこれを引いて、
    /// 出力ファイルのタイムラインから一時停止区間を詰める
    private var pauseOffset = CMTime.zero

    init(url: URL, fileType: AVFileType, video: Bool, videoSize: CGSize?,
         codec: VideoCodecKind, hdr: Bool = false,
         audioLabels: [String], anchor: Anchor,
         outputFilePolicy: OutputFilePolicy = .rejectExisting) throws {
        self.url = url
        self.anchor = anchor
        // AVAssetWriter は出力先ディレクトリが無くても init / startWriting を失敗させず
        // status が failed になるだけなので、ここで先に弾く。弾かないと「何も録れていない
        // ファイルが無いまま録画成功」扱いになり、セッションも停止待ちで迷子になる
        let dir = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            throw KilError.failed("出力先ディレクトリが存在しません: \(dir.path)")
        }
        switch outputFilePolicy {
        case .overwrite:
            // fileExists はパスを解決するため dangling シンボリックリンクで false を返し、
            // リンク自体が残って AVAssetWriter がリンク先に書いてしまう。存在チェックを
            // せず常に削除を試み、「元から無い」以外の失敗だけをエラーにする
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                // 元から無いのは問題ない
            } catch {
                throw KilError.failed("既存の出力ファイルを上書きできません: \(url.path) (\(error))")
            }
        case .reserved(let reservation):
            guard reservation.url == url else {
                throw KilError.failed("出力ファイルの予約 URL が一致しません: \(url.path)")
            }
            try reservation.consume()
        case .rejectExisting:
            if FileManager.default.fileExists(atPath: url.path) {
                throw KilError.failed("出力ファイルが既に存在します: \(url.path)")
            }
        }
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        if video {
            guard let size = videoSize else {
                throw KilError.failed("video: サイズが不明です")
            }
            var settings: [String: Any] = [:]
            switch codec {
            case .h264:
                settings[AVVideoCodecKey] = AVVideoCodecType.h264
                settings[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            case .hevc:
                settings[AVVideoCodecKey] = AVVideoCodecType.hevc
                if hdr {
                    // HDR は 10-bit が要るので Main10 を明示する (既定の Main は 8-bit)。
                    // 色情報も書かないと、再生側が SDR として解釈して眠い絵になる
                    settings[AVVideoCompressionPropertiesKey] = [
                        AVVideoAverageBitRateKey: 20_000_000,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                    ]
                    // 色域は SCK のプリセット (captureHDRStreamLocalDisplay) が実際に渡してくる
                    // バッファに合わせて Display P3。**PQ と組み合わせる YCbCr マトリクスは、
                    // 色域が P3 でも BT.2020 を使う** — P3 に BT.709 を合わせるのは SDR と HLG の
                    // 話で、709 で変換すると BT.2020 の部分集合である P3 の彩度の高い色が
                    // 範囲外の Cb/Cr になってクランプされ、色相と彩度がずれる (SPIKE-NOTES F-H)
                    settings[AVVideoColorPropertiesKey] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                    ]
                } else {
                    settings[AVVideoCompressionPropertiesKey] = [
                        AVVideoAverageBitRateKey: 10_000_000,
                    ]
                }
            case .prores:
                settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
            }
            settings[AVVideoWidthKey] = Int(size.width)
            settings[AVVideoHeightKey] = Int(size.height)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            v.expectsMediaDataInRealTime = true
            writer.add(v)
            videoInput = v
        } else {
            videoInput = nil
        }

        var inputs: [String: AVAssetWriterInput] = [:]
        for label in audioLabels {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            inputs[label] = a
        }
        audioInputs = inputs
        writer.startWriting()
        // startWriting は書き込み不能な出力先でも例外を投げず status が .failed に
        // なるだけ (存在しないディレクトリ・権限不足・読み取り専用ボリューム等)。
        // 放置すると「何も録れていないのに録画成功扱い」になるためここで弾く。
        // init の throw は呼び出し側の cancel 経路に届かないので、自分で後始末する
        if writer.status == .failed {
            let reason = String(describing: writer.error)
            writer.cancelWriting()
            throw KilError.failed("出力ファイルを開けません: \(url.path) (\(reason))")
        }
    }

    // MARK: - 追加
    // 複数ソース (SCK / AVCapture) のコールバックキューから並行して呼ばれるため、
    // すべての入口を lock で直列化する。

    func appendVideo(_ rawSampleBuffer: CMSampleBuffer) {
        guard let input = videoInput else { return }
        lock.lock(); defer { lock.unlock() }
        // 一時停止ぶんを詰めてから PTS を見る (セッション開始時刻も詰めた後の値にする)
        let sb = Self.shifted(rawSampleBuffer, by: pauseOffset)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        if !sessionStarted {
            startSessionLocked(at: pts)
        }
        guard sessionStarted, input.isReadyForMoreMediaData else {
            videoDropped += 1
            return
        }
        let fixed = Self.withValidVideoTiming(sb)
        if input.append(fixed) {
            videoAppended += 1
            if firstVideoPTS == nil { firstVideoPTS = pts }
            lastVideoPTS = pts
        } else {
            videoDropped += 1
        }
    }

    func appendAudio(_ rawSampleBuffer: CMSampleBuffer, label: String) {
        guard let input = audioInputs[label] else { return }
        lock.lock(); defer { lock.unlock() }
        let sb = Self.shifted(rawSampleBuffer, by: pauseOffset)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_NUMERIC(pts) else { return }
        if !sessionStarted, anchor == .firstAudio {
            startSessionLocked(at: pts)
        }
        guard sessionStarted else {
            audioDropped[label, default: 0] += 1
            return
        }
        if let start = sessionStartTime, CMTimeCompare(pts, start) < 0 {
            // アンカー前の音声はドロップ (A/V 同期のため)
            audioDropped[label, default: 0] += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            audioDropped[label, default: 0] += 1
            return
        }
        if input.append(sb) {
            audioAppended[label, default: 0] += 1
            if firstAudioPTS[label] == nil { firstAudioPTS[label] = pts }
            lastAudioPTS[label] = pts
        } else {
            audioDropped[label, default: 0] += 1
        }
    }

    private func startSessionLocked(at t: CMTime) {
        guard !sessionStarted else { return }
        sessionStarted = true
        sessionStartTime = t
        writer.startSession(atSourceTime: t)
    }

    /// 書き込みセッションを破棄する後始末。主に開始前の失敗経路で使うが、
    /// `startSession` 後でも `finishWriting` を呼ぶ前ならいつでも合法 —
    /// 全フレームが drop されて videoAppended == 0 のまま終わる検証失敗経路では
    /// セッション開始済みの状態で呼ばれうる。
    /// removingOutput: 映像が 1 フレームも来なかった場合など、成功と誤認できる
    /// 空ファイルを残さないときに指定する
    func cancel(removingOutput: Bool = false) {
        writer.cancelWriting()
        if removingOutput {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 一時停止していた長さを積む (issue #11)。以降に append するサンプルの PTS から
    /// これを引くことで、出力ファイルのタイムラインが一時停止ぶん伸びないようにする
    func addPauseGap(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        // AudioMixer.advanceAnchor と同じ 48kHz の刻みで積む。600 で量子化すると
        // writer と mixer の補正量が食い違い、小数ミリ秒の一時停止を繰り返すたびに
        // A/V のずれが蓄積する
        pauseOffset = CMTimeAdd(pauseOffset, CMTime(seconds: seconds,
                                                    preferredTimescale: CMTimeScale(AudioMixer.sampleRate)))
    }

    /// サンプルの PTS / DTS を offset だけ手前にずらしたコピーを返す (lock 保持中に呼ぶ)。
    /// offset が 0 のときは元のバッファをそのまま返す (通常の録画では余計なコピーをしない)
    static func shifted(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard CMTIME_IS_NUMERIC(offset), offset.seconds > 0 else { return sb }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return sb }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else { return sb }
        for i in timings.indices {
            if CMTIME_IS_NUMERIC(timings[i].presentationTimeStamp) {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if CMTIME_IS_NUMERIC(timings[i].decodeTimeStamp) {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &out) == noErr, let out else { return sb }
        return out
    }

    /// SCK の映像バッファは duration が無効のことがあるため 1/600s を与え直す
    static func withValidVideoTiming(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        let dur = CMSampleBufferGetDuration(sb)
        if CMTIME_IS_NUMERIC(dur), dur.value > 0 { return sb }
        guard let pb = CMSampleBufferGetImageBuffer(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return sb }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? (out ?? sb) : sb
    }

    // MARK: - 終了

    func finish() async throws {
        lock.lock()
        let started = sessionStarted
        lock.unlock()
        guard started else {
            writer.cancelWriting()
            return
        }
        videoInput?.markAsFinished()
        for a in audioInputs.values { a.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed {
            throw KilError.failed("出力ファイルのファイナライズに失敗: \(String(describing: writer.error))")
        }
    }

    // MARK: - レポート

    struct Counters {
        let videoAppended: Int
        let audioAppended: [String: Int]
    }

    /// ロック下で一貫したカウンタのスナップショットを返す (ステータス表示用)。
    /// キャプチャコールバックが並行して更新するため、生プロパティの直接読みはしない。
    func countersSnapshot() -> Counters {
        lock.lock(); defer { lock.unlock() }
        return Counters(videoAppended: videoAppended, audioAppended: audioAppended)
    }

    static func string(_ t: CMTime?) -> String {
        guard let t, CMTIME_IS_NUMERIC(t) else { return "-" }
        return String(format: "%.3fs", t.seconds)
    }

    /// 音声各トラックの「映像 first PTS との差」(A/V 同期の指標)
    var firstPTSOffsets: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let fv = firstVideoPTS, CMTIME_IS_NUMERIC(fv) else { return [:] }
        var out: [String: Double] = [:]
        for (label, fa) in firstAudioPTS where CMTIME_IS_NUMERIC(fa) {
            out[label] = fa.seconds - fv.seconds
        }
        return out
    }
}
