/// kilde のエラー型。CLI はこれを終了コードに写像する。
/// ペイロードは String のみなので Sendable も安全に成立する
/// (RecorderEvent 経由で Task をまたいで運ばれるため必要)
public enum KilError: Error, CustomStringConvertible, Sendable {
    /// 権限不足 (画面収録 / マイク)。終了コード 2。
    case permission(String)
    /// デバイスやウィンドウが見つからない。終了コード 3。
    case deviceNotFound(String)
    /// その他。終了コード 1。
    case failed(String)

    public var description: String {
        switch self {
        case .permission(let msg): return "権限エラー: \(msg)"
        case .deviceNotFound(let msg): return "デバイス/ウィンドウ不明: \(msg)"
        case .failed(let msg): return msg
        }
    }

    /// CLI での終了コード (DESIGN.md §6)
    public var exitCode: Int32 {
        switch self {
        case .permission: return 2
        case .deviceNotFound: return 3
        case .failed: return 1
        }
    }
}
