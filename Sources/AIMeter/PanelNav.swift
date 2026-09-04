import SwiftUI

enum SettingsPage: Equatable {
    case root
    case services
    case catalogue
    case add(kind: String)
    case custom
    case menuBar
    case general
    case history
}

@MainActor
final class PanelNav: ObservableObject {
    @Published var stack: [SettingsPage] = []

    func push(_ page: SettingsPage) { stack.append(page) }
    func pop() { if !stack.isEmpty { stack.removeLast() } }
    func reset() { stack.removeAll() }
}

enum PanelEscapeAction: Equatable { case pop, close }

func escapeAction(stackDepth: Int) -> PanelEscapeAction {
    stackDepth > 0 ? .pop : .close
}

func panelPreferredHeight(for page: SettingsPage?) -> CGFloat? {
    switch page {
    case .root: return 430
    case .services: return 680
    case .catalogue, .custom: return 590
    case .add: return 620
    case .menuBar: return 590
    case .general: return 430
    case .history: return 520
    case nil: return nil
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    let back: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, back: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.back = back
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.init(title: title, back: back) { EmptyView() }
    }
}
