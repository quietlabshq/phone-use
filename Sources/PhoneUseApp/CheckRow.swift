import SwiftUI

/// A setup check: its state, title and detail, and an optional action to fix it.
struct CheckRow<Action: View>: View {
    let state: CheckMark.State
    let title: String
    var titleDetail: String?
    let detail: String
    @ContentBuilder var action: Action

    var body: some View {
        LabeledContent {
            action
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let titleDetail {
                        Text("\(title) \(Text(titleDetail).monospaced().foregroundStyle(.secondary))")
                    } else {
                        Text(title)
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                CheckMark(state: state)
            }
        }
    }
}

extension CheckRow where Action == EmptyView {
    init(state: CheckMark.State, title: String, titleDetail: String? = nil, detail: String) {
        self.init(state: state, title: title, titleDetail: titleDetail, detail: detail) { EmptyView() }
    }
}

/// Setup check state: done, still to do, a problem, or guidance that cannot be checked.
struct CheckMark: View {
    enum State { case done, todo, problem, info }
    let state: State

    var body: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .todo:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("To do")
        case .problem:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Problem")
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel("Not checked")
        }
    }
}
