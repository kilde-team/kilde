import XCTest
@testable import KildeCore

/// `--hdr` の判定 (issue #16) の検証。
///
/// HDR で実際に録れることは HDR ディスプレイが要るのでここでは確かめられない
/// (SPIKE-NOTES F-H)。代わりに **SDR へ落ちる側の分岐**を検証する — こちらは
/// HDR 非対応機でこそ通せる経路で、「黙って SDR にしない」という契約の中身そのもの。
final class HDRDecisionTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-hdr-test-\(UUID().uuidString).m4a")
    }

    /// 音声のみ + HDR 指定。映像が無いので HDR は効かず、理由付きで SDR に落ちる。
    /// 録画自体は成功する (終了コードを汚さないのが要件)
    private func audioOnlyHDROptions(url: URL) -> RecordOptions {
        var o = RecordOptions()
        o.wantsVideo = false
        o.audioSources = []  // SCK もマイクも使わない = 権限・デバイス不要
        o.outputURL = url
        // start() 直後の stop() は準備中キャンセルになる (issue #56) ため、
        // 成功フローは短い duration で自然終了させる
        o.duration = 0.2
        o.hdr = true
        o.hdrCapableDisplayIDs = []   // 判定済み・対応ディスプレイなし
        return o
    }

    private func collect(_ recorder: Recorder) async -> [RecorderEvent] {
        var events: [RecorderEvent] = []
        let collector = Task {
            for await e in recorder.events { events.append(e) }
        }
        recorder.start()
        await collector.value
        return events
    }

    /// 映像なしで `--hdr` を指定したら、理由を Summary に載せて SDR で録る。
    /// **cleanupWarnings には載せない** — あれは CLI が終了コード 1 に変換する印で、
    /// SDR へのフォールバックは録画が成功している以上 0 のままでなければならない
    func testAudioOnlyFallsBackWithReasonAndKeepsSuccess() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder(options: audioOnlyHDROptions(url: url))

        let events = await collect(recorder)

        guard case .completed(let summary) = events.last else {
            return XCTFail("末尾が completed ではありません: \(events)")
        }
        XCTAssertNotNil(summary.hdrFallback, "SDR に落ちた理由が Summary に載っていない")
        XCTAssertTrue(summary.hdrFallback?.contains("音声のみ") ?? false,
                      "理由が実際の原因を指していない: \(summary.hdrFallback ?? "nil")")
        XCTAssertTrue(recorder.cleanupWarnings.isEmpty,
                      "フォールバックを cleanupWarnings に載せると終了コード 1 になる")
    }

    /// `--hdr` を指定していなければ、`hdrCapableDisplayIDs` が未設定 (nil) でも何も起きない。
    /// HDR を使わない呼び出し側 (GUI・単体テスト) に判定を強制しないための条件
    func testWithoutHDRRequestUnsetCapabilityIsHarmless() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var options = audioOnlyHDROptions(url: url)
        options.hdr = false
        options.hdrCapableDisplayIDs = nil
        let recorder = Recorder(options: options)

        let events = await collect(recorder)

        guard case .completed(let summary) = events.last else {
            return XCTFail("末尾が completed ではありません: \(events)")
        }
        XCTAssertNil(summary.hdrFallback, "HDR を要求していないのに理由が載っている")
    }
    /// SDR へ落ちる経路では Summary.hdrPreset が nil であること (issue #76)。
    /// HDR で録れたときだけ方式名 (HDR10 / Stream Local Display) が載る契約 —
    /// フォールバックに方式名が混入すると「HDR で録れた」と誤読させる
    func testFallbackSummaryHasNoHDRPreset() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let events = await collect(Recorder(options: audioOnlyHDROptions(url: url)))
        guard case .completed(let summary) = events.last else {
            return XCTFail("完了していません: \(events)")
        }
        XCTAssertNil(summary.hdrPreset,
                     "SDR フォールバックに方式名 (\(String(describing: summary.hdrPreset))) が混入しています")
        XCTAssertNotNil(summary.hdrFallback)
    }

}
