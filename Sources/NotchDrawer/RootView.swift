import SwiftUI

enum DrawerTab: String, CaseIterable, Identifiable {
    case player, shots, clipboard, snippets, calendar, translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: "Плеер"
        case .shots: "Скриншоты"
        case .clipboard: "Буфер обмена"
        case .snippets: "Заготовки"
        case .calendar: "Календарь"
        case .translate: "Переводчик"
        }
    }

    var icon: String {
        switch self {
        case .player: "play.circle.fill"
        case .shots: "photo.on.rectangle.angled"
        case .clipboard: "doc.on.clipboard.fill"
        case .snippets: "square.grid.2x2.fill"
        case .calendar: "calendar"
        case .translate: "character.bubble.fill"
        }
    }
}

struct DrawerRootView: View {
    @EnvironmentObject var state: DrawerState
    @AppStorage("lastTab") private var tab: DrawerTab = .player

    private let leftTabs: [DrawerTab] = [.player, .shots, .clipboard]
    private let rightTabs: [DrawerTab] = [.snippets, .calendar, .translate]

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            UsageStrip()
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 24,
                                   bottomTrailingRadius: 24, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
        )
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .scaleEffect(state.isOpen ? 1 : 0.35, anchor: .top)
        .opacity(state.isOpen ? 1 : 0)
    }

    // Иконки разделов по бокам от выреза камеры
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(leftTabs) { tabButton($0) }
                Spacer(minLength: 0)
            }
            Color.clear.frame(width: state.notchSize.width)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(rightTabs) { tabButton($0) }
                Button {
                    state.pinned.toggle()
                } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 26)
                        .foregroundStyle(state.pinned ? Color.yellow : Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(state.pinned ? "Открепить" : "Закрепить открытой")
            }
        }
        .frame(height: max(state.notchSize.height, 30))
    }

    private func tabButton(_ t: DrawerTab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = t }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 12, weight: .semibold))
                if tab == t {
                    Text(t.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(tab == t ? 0.16 : 0)))
            .foregroundStyle(tab == t ? Color.white : Color.white.opacity(0.55))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(t.title)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .player: PlayerView()
        case .shots: ShotsView()
        case .clipboard: ClipboardView()
        case .snippets: SnippetsView()
        case .calendar: CalendarView()
        case .translate: TranslatorView()
        }
    }
}

// MARK: - Общие кусочки интерфейса

struct TabHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct PillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0.1)))
    }
}

struct EmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func card(_ highlight: Bool = false) -> some View {
        self.padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(highlight ? 0.12 : 0.06)))
    }
}
