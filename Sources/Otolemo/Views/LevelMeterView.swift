import SwiftUI

/// 入力レベルの横棒メーター。
struct LevelMeterView: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .scaleEffect(x: CGFloat(min(1, max(0, level))), anchor: .leading)
                }
                .frame(height: 6)
                .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)の入力レベル")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
    }
}
