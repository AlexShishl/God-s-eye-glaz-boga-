import AppKit
import SwiftUI

struct Language: Hashable {
    let code: String
    let name: String

    static let sources: [Language] = [Language(code: "auto", name: "Определить язык")] + common
    static let targets: [Language] = [Language(code: "auto", name: "Авто (рус ⇄ англ)")] + common
    static let common: [Language] = [
        Language(code: "ru", name: "Русский"),
        Language(code: "en", name: "Английский"),
        Language(code: "uk", name: "Украинский"),
        Language(code: "de", name: "Немецкий"),
        Language(code: "fr", name: "Французский"),
        Language(code: "es", name: "Испанский"),
        Language(code: "it", name: "Итальянский"),
        Language(code: "pt", name: "Португальский"),
        Language(code: "tr", name: "Турецкий"),
        Language(code: "zh-CN", name: "Китайский"),
        Language(code: "ja", name: "Японский"),
        Language(code: "ko", name: "Корейский"),
    ]

    static func name(_ code: String) -> String {
        common.first { code.hasPrefix($0.code) }?.name ?? code
    }
}

/// Быстрый переводчик (через бесплатный веб-переводчик Google, нужен интернет).
final class Translator: ObservableObject {
    static let shared = Translator()

    @Published var input = "" { didSet { if input != oldValue { schedule() } } }
    @Published var output = ""
    @Published var source = "auto" { didSet { schedule(0) } }
    @Published var target = "auto" { didSet { schedule(0) } }
    @Published var detected = ""
    @Published var busy = false
    @Published var error: String?

    private var task: Task<Void, Never>?

    func schedule(_ delay: Double = 0.4) {
        task?.cancel()
        let text = input
        guard !text.trimmed.isEmpty else {
            output = ""
            detected = ""
            error = nil
            return
        }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.translate(text)
        }
    }

    @MainActor
    private func translate(_ text: String) async {
        busy = true
        defer { busy = false }
        do {
            var result = try await Self.request(text, from: source, to: target == "auto" ? "ru" : target)
            if target == "auto" && result.detected.hasPrefix("ru") {
                result = try await Self.request(text, from: source, to: "en")
            }
            guard text == input, !Task.isCancelled else { return }
            output = result.text
            detected = result.detected
            error = nil
        } catch {
            if !Task.isCancelled { self.error = "Не получилось перевести. Проверь интернет." }
        }
    }

    private static func request(_ text: String, from sl: String, to tl: String) async throws -> (text: String, detected: String) {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sl),
            URLQueryItem(name: "tl", value: tl),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw URLError(.cannotParseResponse)
        }
        let parts = (root.first as? [Any])?.compactMap { ($0 as? [Any])?.first as? String } ?? []
        let detected = root.count > 2 ? (root[2] as? String ?? sl) : sl
        return (parts.joined(), detected)
    }

    func swap() {
        guard !output.isEmpty else { return }
        let newSource = target == "auto" ? (detected.hasPrefix("ru") ? "en" : "ru") : target
        let newTarget = source == "auto" ? (detected.isEmpty ? "auto" : detected) : source
        let text = output
        source = Language.common.contains { $0.code == newSource } ? newSource : "auto"
        target = Language.common.contains { $0.code == newTarget } ? newTarget : "auto"
        input = text
    }
}

struct TranslatorView: View {
    @ObservedObject private var tr = Translator.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Переводчик").font(.system(size: 14, weight: .bold))
                Spacer()
                Picker("", selection: $tr.source) {
                    ForEach(Language.sources, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                Button { tr.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(PillButton())
                    .help("Поменять местами")
                Picker("", selection: $tr.target) {
                    ForEach(Language.targets, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if tr.input.isEmpty {
                            Text("Введи или вставь текст…").foregroundStyle(.tertiary).padding(.leading, 5)
                        }
                        TextEditor(text: $tr.input)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                    }
                    .font(.system(size: 13))
                    HStack {
                        if tr.source == "auto" && !tr.detected.isEmpty {
                            Text(Language.name(tr.detected)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Вставить") {
                            if let s = NSPasteboard.general.string(forType: .string) { tr.input = s }
                        }
                        .buttonStyle(PillButton())
                        if !tr.input.isEmpty {
                            Button("Очистить") { tr.input = "" }.buttonStyle(PillButton())
                        }
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(tr.output.isEmpty ? (tr.error ?? "Перевод появится здесь") : tr.output)
                            .font(.system(size: 13))
                            .foregroundStyle(tr.output.isEmpty ? (tr.error == nil ? Color.white.opacity(0.35) : Color.red) : Color.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        if tr.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        CopyButton(text: tr.output)
                    }
                }
                .card(true)
            }
        }
        .onAppear { focused = true }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PillButton())
        .disabled(text.isEmpty)
    }
}
