import Foundation
import CoreGraphics
import AppKit

/// HDR を出せるディスプレイの判定 (issue #16)。
///
/// **メインスレッド専用。セッションの中から呼ばないこと。**
/// `NSScreen` はメインスレッドで読む必要があるが、`Recorder` は CLI の同期経路
/// (`run()` が呼び出しスレッド = メインスレッドを完了までブロックする) からも呼ばれる。
/// セッションの中で `MainActor` へディスパッチすると、そのメインスレッドは `run()` で
/// 塞がっているので永久に実行されない = デッドロックする。
///
/// そのため **`KildeCore.Recorder` は MainActor を要求しない**という不変条件を置き、
/// UI フレームワークに触る判定は呼び出し側 (CLI の起動時 / GUI の MainActor 上) で
/// 済ませて、結果だけを `RecordOptions.hdrCapableDisplayIDs` に載せて渡す。
@MainActor
public enum DisplayHDR {

    /// HDR を出せるディスプレイの ID 集合。
    ///
    /// 判定に使うのは `maximumPotentialExtendedDynamicRangeColorComponentValue` =
    /// 「その画面が到達しうる EDR の上限」で、SDR ディスプレイでは 1.0 のままになる。
    /// 現在値 (`maximumExtendedDynamicRangeColorComponentValue`) の方は明るさ設定や
    /// 表示中の内容で変動するので、対応可否の判定には使えない。
    public static func capableDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            if screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 {
                ids.insert(id)
            }
        }
        return ids
    }
}
