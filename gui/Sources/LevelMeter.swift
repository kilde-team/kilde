import SwiftUI

/// ソース別のレベルメーター (issue #18)。Recorder.Progress.peaks (線形のピーク 0...1) を
/// dB に直して -60〜0 dB を棒の長さにする — 線形のままだと話し声 (ピーク 0.1〜0.3) がほぼ動かないため
struct LevelMeter: View {
    let label: String
    let peak: Float

    private static let floorDB: Float = -60

    private var fraction: CGFloat {
        let db = 20 * log10(max(peak, 1e-6))
        return CGFloat(min(max((db - Self.floorDB) / -Self.floorDB, 0), 1))
    }

    private var color: Color {
        // 0 dBFS 付近はクリップの恐れがあるので赤、-6 dB 以上は黄
        if peak >= 0.95 { return .red }
        if peak >= 0.5 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.15), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) のレベル")
        .accessibilityValue(String(format: "%.0f dB", 20 * log10(max(peak, 1e-6))))
    }
}
