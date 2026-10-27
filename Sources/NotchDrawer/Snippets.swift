import SwiftUI

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var value: String
    var icon: String

    static let defaults: [Snippet] = [
        Snippet(title: "Почта", value: "", icon: "envelope.fill"),
        Snippet(title: "Рабочая почта", value: "", icon: "briefcase.fill"),
        Snippet(title: "Телефон", value: "", icon: "phone.fill"),
        Snippet(title: "GitHub", value: "https://github.com/AlexShishl", icon: "chevron.left.forwardslash.chevron.right"),
        Snippet(title: "Telegram", value: "", icon: "paperplane.fill"),
    ]

    static let icons = [
        "envelope.fill", "briefcase.fill", "phone.fill", "paperplane.fill",
        "chevron.left.forwardslash.chevron.right", "link", "person.fill", "house.fill",
        "creditcard.fill", "number", "star.fill", "heart.fill", "text.quote", "key.fill",
    ]
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published var items: [Snippet] {
        didSet { Storage.save(items, to: "snippets.json") }
    }

    init() {
        items = Storage.load([Snippet].self, from: "snippets.json") ?? Snippet.defaults
    }

    func upsert(_ s: Snippet) {
        if let i = items.firstIndex(where: { $0.id == s.id }) {
            items[i] = s
        } else {
            items.append(s)
        }
    }

    func delete(_ s: Snippet) { items.removeAll { $0.id == s.id } }
}

struct SnippetsView: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var editing: Snippet?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var filtered: [Snippet] {
        let q = query.trimmed
        return q.isEmpty ? store.items : store.items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                TabHeader("Заготовки", subtitle: "Нажми на блок — текст скопируется") {
                    SearchField(placeholder: "Поиск по названию", text: $query).frame(width: 220)
                    Button {
                        editing = Snippet(title: "", value: "", icon: "star.fill")
                    } label: {
                        Label("Добавить", systemImage: "plus")
                    }
                    .buttonStyle(PillButton())
                }

                if filtered.isEmpty {
                    EmptyState(icon: "square.grid.2x2", text: store.items.isEmpty ? "Добавь первую заготовку кнопкой «Добавить»" : "Ничего не нашлось")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(filtered) { s in
                                SnippetCard(snippet: s, copied: copiedID == s.id,
                                            onCopy: { copy(s) },
                                            onEdit: { editing = s })
                            }
                        }
                    }
                }
            }

            if let draft = editing {
                Color.black.opacity(0.35)
                    .onTapGesture { editing = nil }
                SnippetEditor(draft: draft,
                              isNew: !store.items.contains { $0.id == draft.id },
                              onSave: { store.upsert($0); editing = nil },
                              onDelete: { store.delete(draft); editing = nil },
                              onCancel: { editing = nil })
                    .id(draft.id)
            }
        }
    }

    private func copy(_ s: Snippet) {
        guard !s.value.isEmpty else { editing = s; return }
        Pasteboard.copy(s.value)
        copiedID = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if copiedID == s.id { copiedID = nil }
        }
    }
}

private struct SnippetCard: View {
    let snippet: Snippet
    let copied: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snippet.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(snippet.value.isEmpty ? "Нажми, чтобы заполнить" : snippet.value)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover && !copied {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Изменить")
            }
        }
        .card(hover)
        .overlay {
            if copied {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.9))
                    .overlay(Label("Скопировано", systemImage: "checkmark").font(.callout.weight(.semibold)))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onCopy)
        .animation(.easeOut(duration: 0.15), value: copied)
    }
}

private struct SnippetEditor: View {
    @State var draft: Snippet
    let isNew: Bool
    let onSave: (Snippet) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(isNew ? "Новая заготовка" : "Изменить заготовку").font(.headline)
            TextField("Название (например, «Рабочая почта»)", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            TextField("Что копировать", text: $draft.value, axis: .vertical)
                .lineLimit(1...2)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                ForEach(Snippet.icons, id: \.self) { icon in
                    Button { draft.icon = icon } label: {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(draft.icon == icon ? 0.3 : 0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                if !isNew {
                    Button("Удалить", role: .destructive, action: onDelete).buttonStyle(PillButton()).foregroundStyle(.red)
                }
                Spacer()
                Button("Отмена", action: onCancel).buttonStyle(PillButton())
                Button("Сохранить") { onSave(draft) }
                    .buttonStyle(PillButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmed.isEmpty)
            }
        }
        .padding(12)
        .controlSize(.small)
        .frame(width: 470)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4))
    }
}
