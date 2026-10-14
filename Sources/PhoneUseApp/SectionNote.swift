import SwiftUI

/// Explanatory text under a grouped form section, aligned with the rows above it.
struct SectionNote: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
