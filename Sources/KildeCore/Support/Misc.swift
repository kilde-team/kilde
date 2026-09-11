import Foundation

/// "30" / "30s" / "5m" / "1h" を秒数にする
public func parseDuration(_ s: String?) -> TimeInterval? {
    guard let s, !s.isEmpty else { return nil }
    let numStr = String(s.prefix { $0.isNumber || $0 == "." })
    guard var n = Double(numStr) else { return nil }
    if s.hasSuffix("m") { n *= 60 }
    else if s.hasSuffix("h") { n *= 3600 }
    return n
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
