import Foundation
import CoreGraphics

/// "x,y,w,h" (ポイント座標) を矩形にする。文字列全体が有効な形式で、原点が 0 以上・
/// 幅と高さが正であること。原点はディスプレイの左上 (SCStreamConfiguration.sourceRect と同じ向き)。
/// ディスプレイの範囲に収まるかは収録時に確認する (ここではディスプレイを知らないため)
public func parseRegion(_ s: String?) -> CGRect? {
    guard let s, !s.isEmpty else { return nil }
    let parts = s.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var values: [CGFloat] = []
    for part in parts {
        let t = part.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." }),
              let v = Double(t), v.isFinite else { return nil }
        values.append(CGFloat(v))
    }
    guard values[2] > 0, values[3] > 0 else { return nil }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

/// "30" / "30s" / "5m" / "1h" を秒数にする。文字列全体が有効な形式であること。
public func parseDuration(_ s: String?) -> TimeInterval? {
    guard let s, !s.isEmpty else { return nil }
    var numPart = s
    var multiplier = 1.0
    if let last = s.last, last == "s" || last == "m" || last == "h" {
        numPart = String(s.dropLast())
        if last == "m" { multiplier = 60 }
        else if last == "h" { multiplier = 3600 }
    }
    guard !numPart.isEmpty,
          numPart.allSatisfy({ $0.isNumber || $0 == "." }),
          let n = Double(numPart), n.isFinite else { return nil }
    return n * multiplier
}

public func defaultOutputName(prefix: String = "kilde", ext: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "\(prefix)-\(f.string(from: Date())).\(ext)"
}

public func fileSizeString(_ url: URL) -> String {
    let b = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(b ?? 0), countStyle: .file)
}
