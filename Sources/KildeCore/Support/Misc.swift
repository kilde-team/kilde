import Foundation

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
