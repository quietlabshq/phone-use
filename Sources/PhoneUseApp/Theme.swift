import SwiftUI

/// Colors and type from the Phone Use design. The app is always dark.
enum Theme {
    static let background = Color(hex: 0x0D0E10)
    static let sidebar = Color(hex: 0x121316)
    static let card = Color(hex: 0x16171A)
    static let panel = Color(hex: 0x141518)
    static let raised = Color(hex: 0x17181C)
    static let control = Color(hex: 0x1A1B1F)
    static let selected = Color(hex: 0x1F2125)
    static let segment = Color(hex: 0x2C2E33)
    static let well = Color(hex: 0x0F1012)
    static let code = Color(hex: 0x0A0B0C)

    static let line = Color(hex: 0x24262A)
    static let headerLine = Color(hex: 0x1E2024)
    static let outline = Color(hex: 0x2E3035)
    static let frame = Color(hex: 0x2A2C31)
    static let strongOutline = Color(hex: 0x3A3C42)

    static let text = Color(hex: 0xECEAE5)
    static let secondary = Color(hex: 0xC9C7C2)
    static let tertiary = Color(hex: 0xA0A3A9)
    static let quaternary = Color(hex: 0x8C8F96)
    static let codeText = Color(hex: 0xE4D3A8)
    static let caption = Color(hex: 0xF7E3B5)

    static let amber = Color(hex: 0xF2B33D)
    static let amberInk = Color(hex: 0x17130A)
    static let blue = Color(hex: 0x7CB7FF)
    static let blueInk = Color(hex: 0x0B1726)
    static let green = Color(hex: 0x5ED39A)
    static let greenInk = Color(hex: 0x0B1A12)
    static let red = Color(hex: 0xFF7B6B)
    static let redText = Color(hex: 0xFF8E80)
    static let idle = Color(hex: 0x5F6268)
    static let quietDot = Color(hex: 0x3E4046)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist", size: size).weight(weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist Mono", size: size).weight(weight) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

/// A status dot that can pulse while something is in progress.
struct Dot: View {
    let color: Color
    var size: CGFloat = 7
    var breathing = false
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(breathing && dim ? 0.35 : 1)
            .onAppear { updateAnimation() }
            .onChange(of: breathing) { updateAnimation() }
    }

    private func updateAnimation() {
        if breathing {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.default) { dim = false }
        }
    }
}

/// Buttons from the design: light primary, outlined secondary, and the blue and amber calls to action.
struct ThemeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, blue, amber }
    var kind = Kind.secondary
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, kind == .quiet ? .regular : kind == .secondary ? .medium : .semibold))
            .labelStyle(GapLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(hex: 0x121316)
        case .secondary: Theme.text
        case .quiet: Theme.secondary
        case .blue: Theme.blueInk
        case .amber: Theme.amberInk
        }
    }
    private var background: Color {
        switch kind {
        case .primary: Theme.text
        case .secondary: Theme.control
        case .quiet: .clear
        case .blue: Theme.blue
        case .amber: Theme.amber
        }
    }
    private var border: Color {
        switch kind {
        case .secondary: Theme.strongOutline
        case .quiet: Theme.outline
        default: .clear
        }
    }
}

struct GapLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.font(.system(size: 12, weight: .semibold)); configuration.title }
    }
}

/// A row of mutually exclusive options in a dark well.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var mono = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(mono ? Theme.mono(12) : Theme.font(12))
                        .foregroundStyle(selected ? Theme.text : Theme.tertiary)
                        .padding(.horizontal, mono ? 0 : 12)
                        .frame(minWidth: mono ? 34 : nil, minHeight: 26)
                        .background(selected ? Theme.segment : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(mono ? Theme.raised : Theme.well, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0x26282D)))
    }
}

/// Setup check state: done, still to do, a problem, or guidance that cannot be checked.
struct CheckMark: View {
    enum State { case done, todo, problem, info }
    let state: State
    var size: CGFloat = 18

    var body: some View {
        switch state {
        case .done:
            Circle().fill(Theme.green).frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(Theme.greenInk))
                .accessibilityLabel("Done")
        case .todo:
            Circle().strokeBorder(Theme.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])).frame(width: size, height: size)
                .accessibilityLabel("To do")
        case .problem:
            Circle().fill(Theme.red).frame(width: size, height: size)
                .overlay(Text("!").font(.system(size: size * 0.65, weight: .bold)).foregroundStyle(Color(hex: 0x1F0B08)))
                .accessibilityLabel("Problem")
        case .info:
            Circle().strokeBorder(Theme.tertiary, lineWidth: 1.5).frame(width: size, height: size)
                .overlay(Text("i").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(Theme.tertiary))
                .accessibilityLabel("Not checked")
        }
    }
}

/// A small outlined label, optionally with a status dot.
struct Tag: View {
    let text: String
    var dot: Color?
    var color = Theme.secondary
    var border = Theme.outline

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Dot(color: dot, size: 6) }
            Text(text)
        }
        .font(Theme.font(11.5))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
    }
}

/// A bordered group of rows; separate rows with `Hairline`.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

struct Hairline: View {
    var color = Theme.line
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// A switch drawn like the design's toggle.
struct ThemeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Theme.green : Theme.strongOutline)
                .frame(width: 40, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
