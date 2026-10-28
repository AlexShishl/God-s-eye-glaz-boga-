import AppKit
import SwiftUI

struct ClipItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var date: Date
}

/// История буфера обмена (только текст). Пароли из менеджеров паролей не сохраняются.
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    static let limit = 60

    @Published private(set) var items: [ClipItem] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        items = Storage.load([ClipItem].self, from: "clipboard.json") ?? []
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func markOwnChange() { changeCount = NSPasteboard.general.changeCount }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        guard AppSettings.shared.isOn(.clipboard) else {
            changeCount = pb.changeCount
            return
        }
        changeCount = pb.changeCount
        let types = pb.types ?? []
        let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if types.contains(where: { secret.contains($0.rawValue) }) { return }
        guard let text = pb.string(forType: .string), !text.trimmed.isEmpty else { return }
        add(text)
    }

    private func add(_ text: String) {
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text, date: Date()), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func copy(_ item: ClipItem) {
        Pasteboard.copy(item.text)
        add(item.text)
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() { Storage.save(items, to: "clipboard.json") }
}

struct ClipboardView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var grabber = TextGrabber.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @State private var query = ""
    @State private var copiedID: UUID?

    private var filtered: [ClipItem] {
        let q = query.trimmed
        return q.isEmpty ? store.items : store.items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TabHeader("Буфер обмена", subtitle: grabber.status ?? "Нажми на запись — она снова скопируется") {
                SearchField(placeholder: "Поиск", text: $query).frame(width: 160)
                Button { TextGrabber.shared.start() } label: {
                    Label("С экрана", systemImage: "text.viewfinder")
                }
                .buttonStyle(PillButton())
                .help("Выдели область экрана — текст из неё скопируется"
                      + (hotKeys.textGrab.map { " (\($0.display))" } ?? ""))
                if !store.items.isEmpty {
                    Button("Очистить") { store.clear() }.buttonStyle(PillButton())
                }
            }

            if filtered.isEmpty {
                EmptyState(icon: "doc.on.clipboard",
                           text: store.items.isEmpty ? "Скопируй что-нибудь (⌘C) — и оно появится тут" : "Ничего не нашлось")
            } else {
                ScrollView {
                    // Обычный VStack: записей не больше 60, а LazyVStack со строками
                    // разной высоты на macOS уходит в бесконечный пересчёт раскладки.
                    VStack(spacing: 5) {
                        ForEach(filtered) { item in
                            ClipRow(item: item, copied: copiedID == item.id) {
                                store.copy(item)
                                copiedID = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                                    if copiedID == item.id { copiedID = nil }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let copied: Bool
    let onCopy: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.text.trimmed)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copied {
                Label("Скопировано", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else if hover {
                Button { withAnimation { ClipboardStore.shared.remove(item) } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text(RuDate.time.string(from: item.date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .card(hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onCopy)
    }
}
