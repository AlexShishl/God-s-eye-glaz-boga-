import AppKit
import SwiftUI

extension Notification.Name {
    /// Пришёл ответ на вопрос из созвона — выдвинуть шторку на вкладке «Созвон».
    static let showCallAnswer = Notification.Name("GlazShowCallAnswer")
}

struct CallLine: Identifiable {
    enum Speaker { case them, me }

    let id = UUID()
    let speaker: Speaker
    let text: String
    let date: Date
    let isQuestion: Bool
}

struct CallAnswer: Identifiable {
    let id = UUID()
    let question: String
    let ai: CallAI
    let isSummary: Bool
    var text = ""
    var done = false
    var error: String?
}

enum CallAI: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var command: String { rawValue }

    var missingHint: String {
        switch self {
        case .claude: "Не нашла Claude Code. Установи его (claude.ai/code) и один раз войди командой claude в Терминале."
        case .codex: "Не нашла Codex. Установи его (npm i -g @openai/codex) и один раз войди командой codex в Терминале."
        }
    }
}

/// «Созвон»: слушает звук Mac и микрофон, превращает речь в текст, замечает вопросы
/// собеседников и сразу просит у Claude или Codex готовый ответ.
final class CallAssistant: ObservableObject {
    static let shared = CallAssistant()
    private let defaults = UserDefaults.standard

    @Published private(set) var listening = false
    @Published private(set) var starting = false
    @Published private(set) var lines: [CallLine] = []
    @Published private(set) var partialThem = ""
    @Published private(set) var partialMe = ""
    @Published private(set) var answers: [CallAnswer] = []
    @Published private(set) var answeredLines: Set<UUID> = []
    @Published var status: String?
    @Published private(set) var lastSavedFile: URL?

    @Published var ai: CallAI { didSet { defaults.set(ai.rawValue, forKey: "call.ai") } }
    /// Отвечать на замеченные вопросы самой, без нажатия кнопки.
    @Published var autoAnswer: Bool { didSet { defaults.set(autoAnswer, forKey: "call.auto") } }
    @Published var useMic: Bool { didSet { defaults.set(useMic, forKey: "call.mic") } }
    /// Выдвигать шторку, когда начинается ответ.
    @Published var popUp: Bool { didSet { defaults.set(popUp, forKey: "call.popup") } }
    /// Быстрее, но проще: Claude Haiku / Codex с коротким размышлением.
    @Published var fast: Bool { didSet { defaults.set(fast, forKey: "call.fast") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "call.lang") } }
    /// «Кто я и о чём созвон» — подставляется в каждый вопрос нейросети.
    @Published var context: String { didSet { defaults.set(context, forKey: "call.context") } }

    static let languages = [Language(code: "ru-RU", name: "Русский"), Language(code: "en-US", name: "Английский")]

    private var system: SystemAudioCapture?
    private var mic: MicCapture?
    private var themText: LiveTranscriber?
    private var meText: LiveTranscriber?
    private var startedAt: Date?
    private var summary: String?

    init() {
        ai = CallAI(rawValue: defaults.string(forKey: "call.ai") ?? "") ?? .claude
        autoAnswer = defaults.object(forKey: "call.auto") as? Bool ?? true
        useMic = defaults.object(forKey: "call.mic") as? Bool ?? true
        popUp = defaults.object(forKey: "call.popup") as? Bool ?? true
        fast = defaults.object(forKey: "call.fast") as? Bool ?? true
        language = defaults.string(forKey: "call.lang") ?? "ru-RU"
        context = defaults.string(forKey: "call.context") ?? ""
    }

    // MARK: Запись

    func toggle() {
        listening ? stop() : start()
    }

    func start() {
        guard !listening, !starting else { return }
        starting = true
        status = "Включаю…"
        lines = []
        answers = []
        answeredLines = []
        summary = nil
        lastSavedFile = nil
        startedAt = Date()
        Task { @MainActor in
            do {
                status = nil
                try await begin()
                listening = true
            } catch {
                teardown()
                status = error.localizedDescription
            }
            starting = false
        }
    }

    @MainActor
    private func begin() async throws {
        guard await CallPermissions.speech() else {
            throw CallError("Разреши «Распознавание речи» для Глаза Бога: Системные настройки → Конфиденциальность")
        }
        let them = LiveTranscriber(locale: language)
        guard them.isAvailable else {
            throw CallError("Распознавание речи сейчас недоступно. Проверь интернет или язык в настройках созвона")
        }
        them.onPartial = { [weak self] t in self?.partialThem = t }
        them.onFinal = { [weak self] t in self?.add(t, from: .them) }
        them.onError = { [weak self] e in self?.status = "Распознавание: \(e)" }
        themText = them

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let sys = SystemAudioCapture()
        sys.onBuffer = { [weak them] in them?.append($0) }
        sys.onStop = { [weak self] e in
            guard let self, self.listening else { return }
            self.stop()
            self.status = "Запись звука остановилась: \(e)"
        }
        do {
            try await sys.start()
        } catch {
            throw CallError(CGPreflightScreenCaptureAccess()
                            ? "Не получилось слушать звук Mac: \(error.localizedDescription)"
                            : "Разреши «Запись экрана и звука» для Глаза Бога в Системных настройках и перезапусти его")
        }
        system = sys
        them.start()

        if useMic {
            if await CallPermissions.microphone() {
                let me = LiveTranscriber(locale: language)
                me.onPartial = { [weak self] t in self?.partialMe = t }
                me.onFinal = { [weak self] t in self?.add(t, from: .me) }
                let m = MicCapture()
                m.onBuffer = { [weak me] in me?.append($0) }
                do {
                    try m.start()
                    mic = m
                    meText = me
                    me.start()
                } catch {
                    status = "Микрофон не включился, слушаю только звук Mac"
                }
            } else {
                status = "Нет доступа к микрофону, слушаю только звук Mac"
            }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        teardown()
        // Даём распознаванию дописать последние фразы, потом сохраняем запись.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.save() }
    }

    private func teardown() {
        system?.stop()
        mic?.stop()
        themText?.stop()
        meText?.stop()
        system = nil
        mic = nil
        themText = nil
        meText = nil
    }

    private func add(_ text: String, from speaker: CallLine.Speaker) {
        let clean = text.trimmed
        guard !clean.isEmpty else { return }
        let line = CallLine(speaker: speaker, text: clean, date: Date(),
                            isQuestion: speaker == .them && QuestionDetector.isQuestion(clean))
        lines.append(line)
        if line.isQuestion && autoAnswer { ask(line) }
    }

    func clear() {
        guard !listening else { return }
        lines = []
        answers = []
        answeredLines = []
        summary = nil
        lastSavedFile = nil
    }

    // MARK: Нейросеть

    /// Ответить на конкретную реплику.
    func ask(_ line: CallLine) {
        guard !answeredLines.contains(line.id) else { return }
        answeredLines.insert(line.id)
        let prompt = """
        Ты незаметный помощник на созвоне. Я сейчас разговариваю с людьми, и мне задали вопрос. \
        Дай ответ, который я могу сразу произнести вслух: коротко (2–5 предложений или короткий список), \
        по делу, на языке вопроса, без вступлений, без заголовков и без упоминания, что ты ИИ. \
        Текст получен распознаванием речи и может быть с ошибками, поэтому додумывай смысл по контексту.
        \(contextBlock)
        Последние реплики созвона («Собеседник» — другие люди, «Я» — я):
        \(transcript(last: 24))

        Вопрос, на который нужно ответить сейчас: «\(line.text)»
        """
        run(prompt, question: line.text, summary: false)
    }

    /// Ответить на последний вопрос собеседника (или просто на последнюю его реплику).
    func askLast() {
        if let line = lines.last(where: { $0.isQuestion && !answeredLines.contains($0.id) })
            ?? lines.last(where: { $0.speaker == .them && !answeredLines.contains($0.id) }) {
            ask(line)
        } else {
            status = "Пока не на что отвечать"
        }
    }

    func makeSummary() {
        guard !lines.isEmpty else {
            status = "Созвон ещё пустой, конспектировать нечего"
            return
        }
        let prompt = """
        Сделай конспект созвона на русском. Структура: «Главное» (3–6 пунктов), «Договорённости и решения», \
        «Задачи» (кто что делает и к какому сроку, если звучало), «Открытые вопросы». Только то, что \
        действительно прозвучало. Текст получен распознаванием речи и может быть с ошибками.
        \(contextBlock)
        Расшифровка («Собеседник» — другие люди, «Я» — я):
        \(transcript(last: nil))
        """
        run(prompt, question: "Конспект созвона", summary: true)
    }

    private var contextBlock: String {
        let c = context.trimmed
        return c.isEmpty ? "" : "\nОбо мне и об этом созвоне: \(c)\n"
    }

    private func transcript(last count: Int?) -> String {
        let source = count.map { Array(lines.suffix($0)) } ?? lines
        return source.map { "\($0.speaker == .them ? "Собеседник" : "Я"): \($0.text)" }.joined(separator: "\n")
    }

    private func run(_ prompt: String, question: String, summary isSummary: Bool) {
        let answer = CallAnswer(question: question, ai: ai, isSummary: isSummary)
        answers.append(answer)
        if popUp { NotificationCenter.default.post(name: .showCallAnswer, object: nil) }
        let id = answer.id
        AIRunner.run(ai, prompt: prompt, fast: fast && !isSummary, onText: { [weak self] text in
            self?.update(id) { $0.text = text }
        }, onDone: { [weak self] error in
            guard let self else { return }
            self.update(id) {
                $0.done = true
                if $0.text.trimmed.isEmpty { $0.error = error ?? "Пустой ответ" }
            }
            if isSummary, let a = self.answers.first(where: { $0.id == id }), a.error == nil {
                self.summary = a.text
                self.save()
            }
        })
    }

    private func update(_ id: UUID, _ change: (inout CallAnswer) -> Void) {
        guard let i = answers.firstIndex(where: { $0.id == id }) else { return }
        change(&answers[i])
    }

    // MARK: Сохранение

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Глаз Бога/Созвоны", isDirectory: true)
    }

    /// Расшифровка (и конспект, если он есть) в ~/Documents/Глаз Бога/Созвоны/<дата>.md
    private func save() {
        guard !lines.isEmpty else { return }
        let start = startedAt ?? lines.first?.date ?? Date()
        let name = Self.fileName.string(from: start) + ".md"
        var text = "# Созвон \(RuDate.day.string(from: start)), \(RuDate.time.string(from: start))\n\n"
        if let summary { text += "## Конспект\n\n\(summary)\n\n" }
        let answered = answers.filter { !$0.isSummary && $0.error == nil && !$0.text.isEmpty }
        if !answered.isEmpty {
            text += "## Подсказки\n\n"
            for a in answered { text += "**\(a.question)**\n\n\(a.text)\n\n" }
        }
        text += "## Расшифровка\n\n"
        for l in lines {
            text += "[\(RuDate.time.string(from: l.date))] **\(l.speaker == .them ? "Собеседник" : "Я"):** \(l.text)\n\n"
        }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let url = Self.folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastSavedFile = url
        } catch {
            status = "Не получилось сохранить расшифровку: \(error.localizedDescription)"
        }
    }

    func revealFolder() {
        if let file = lastSavedFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Self.folder)
        }
    }

    private static let fileName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
}

/// Похоже ли на вопрос: знак «?» (распознавание его ставит), вопросительное слово в начале
/// или просьба вроде «расскажите», «объясните».
enum QuestionDetector {
    private static let starts = [
        "как", "что", "почему", "зачем", "когда", "где", "куда", "откуда", "какой", "какая", "какое",
        "какие", "каким", "какую", "каков", "сколько", "кто", "чем", "чей", "чья", "кому", "кого", "ли",
        "а как", "а что", "а почему", "а когда", "а где", "а сколько", "а кто", "а если", "есть ли",
        "what", "why", "how", "when", "where", "who", "which", "whose", "do", "does", "did", "is", "are",
        "can", "could", "would", "will", "should", "have", "has",
    ]
    private static let requests = [
        "расскажи", "расскажите", "объясни", "объясните", "подскажи", "подскажите", "поясни", "поясните",
        "можешь", "можете", "могли бы", "не могли бы", "как думаешь", "как думаете", "что думаешь",
        "что думаете", "интересно", "приведи пример", "приведите пример",
        "tell me", "explain", "walk me through", "can you", "could you", "what do you think", "describe",
    ]

    static func isQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= 3 else { return false }
        if lower.contains("?") { return true }
        let head = words.prefix(2).joined(separator: " ")
        if starts.contains(where: { head == $0 || head.hasPrefix($0 + " ") }) { return true }
        let padded = " " + words.joined(separator: " ") + " "
        return requests.contains { padded.contains(" \($0) ") }
    }
}

// MARK: - Запуск claude / codex

/// Спрашивает нейросеть через установленные на Mac Claude Code (`claude -p`) или Codex (`codex exec`),
/// то есть по тем же входам, что и в Терминале. Никаких отдельных ключей не нужно.
enum AIRunner {
    private static var located: [String: URL] = [:]
    private static let lock = NSLock()

    static func run(_ ai: CallAI, prompt: String, fast: Bool,
                    onText: @escaping (String) -> Void,
                    onDone: @escaping (_ error: String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (String?) -> Void = { e in DispatchQueue.main.async { onDone(e) } }
            guard let bin = locate(ai.command) else { return finish(ai.missingHint) }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glaz-call", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lastMessage = dir.appendingPathComponent("codex-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: lastMessage) }

            let p = Process()
            p.executableURL = bin
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath(adding: bin.deletingLastPathComponent().path)
            p.environment = env
            switch ai {
            case .claude:
                p.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
                    + (fast ? ["--model", "haiku"] : [])
            case .codex:
                p.arguments = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
                               "--output-last-message", lastMessage.path]
                    + (fast ? ["-c", "model_reasoning_effort=low"] : [])
                    + ["-"]
            }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errors

            do {
                try p.run()
            } catch {
                return finish("Не получилось запустить \(ai.title): \(error.localizedDescription)")
            }
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()

            // stderr читаем параллельно, чтобы его буфер не переполнился и не подвесил процесс.
            let errBox = DataBox()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                errBox.data = errors.fileHandleForReading.readDataToEndOfFile()
                errDone.signal()
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: killer)

            var parser = StreamParser(ai: ai)
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                var changed = false
                while let nl = pending.firstIndex(of: 0x0A) {
                    if parser.feed(Data(pending[pending.startIndex..<nl])) { changed = true }
                    pending.removeSubrange(pending.startIndex...nl)
                }
                if changed {
                    let text = parser.text
                    DispatchQueue.main.async { onText(text) }
                }
            }
            if !pending.isEmpty, parser.feed(pending) {
                let text = parser.text
                DispatchQueue.main.async { onText(text) }
            }
            p.waitUntilExit()
            killer.cancel()
            errDone.wait()

            if ai == .codex, let last = try? String(contentsOf: lastMessage, encoding: .utf8), !last.trimmed.isEmpty {
                let text = last.trimmed
                DispatchQueue.main.async { onText(text) }
                return finish(nil)
            }
            if let e = parser.error { return finish(e) }
            if p.terminationStatus != 0 || parser.text.trimmed.isEmpty {
                let tail = String(decoding: errBox.data.suffix(400), as: UTF8.self).trimmed
                return finish(tail.isEmpty ? "\(ai.title) ничего не ответил (код \(p.terminationStatus))" : tail)
            }
            finish(nil)
        }
    }

    /// Ищем программу там, куда её обычно ставят: приложение, запущенное не из Терминала, не видит PATH из .zshrc.
    static func locate(_ name: String) -> URL? {
        lock.lock()
        if let url = located[name] { lock.unlock(); return url }
        lock.unlock()

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/\(name)", "\(home)/.claude/local/\(name)", "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)", "\(home)/Library/pnpm/\(name)",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted(by: >).map { "\(nvm)/\($0)/bin/\(name)" }
        }
        var found = candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if found == nil { found = askShell(name) }
        if found == nil, name == "claude" { found = desktopClaude() }
        if let found {
            lock.lock()
            located[name] = found
            lock.unlock()
        }
        return found
    }

    /// Claude Code, встроенный в приложение Claude для Mac:
    /// ~/Library/Application Support/Claude/claude-code/<версия>/<хеш>/claude.app/Contents/MacOS/claude.
    /// Версия и хеш меняются с обновлениями, поэтому берём самый свежий.
    private static func desktopClaude() -> URL? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        var best: (URL, Date)?
        for version in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for build in (try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? [] {
                let bin = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                guard fm.isExecutableFile(atPath: bin.path) else { continue }
                let date = (try? bin.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || date > best!.1 { best = (bin, date) }
            }
        }
        return best?.0
    }

    /// Последний шанс: спросить у zsh пользователя, где программа.
    private static func askShell(_ name: String) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { String($0).trimmed }
            .last { $0.hasPrefix("/") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func searchPath(adding dir: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = [dir, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (base + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}

private final class DataBox {
    var data = Data()
}

/// Разбирает вывод: у Claude это JSON-строки (кусочки ответа по мере печати), у Codex — обычный текст.
private struct StreamParser {
    let ai: CallAI
    private(set) var text = ""
    private(set) var error: String?
    private var sawDelta = false

    init(ai: CallAI) { self.ai = ai }

    /// true — текст ответа изменился.
    mutating func feed(_ line: Data) -> Bool {
        if ai == .codex {
            let s = String(decoding: line, as: UTF8.self)
            text += (text.isEmpty ? "" : "\n") + s
            text = text.trimmed
            return true
        }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = json["type"] as? String else { return false }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String else { return false }
            sawDelta = true
            text += piece
            return true
        case "assistant":
            // Старые версии Claude Code присылают ответ целиком, без кусочков.
            guard !sawDelta,
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return false }
            let full = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !full.isEmpty else { return false }
            text = full
            return true
        case "result":
            if json["is_error"] as? Bool == true {
                error = json["result"] as? String ?? "Claude вернул ошибку"
                return false
            }
            guard let result = json["result"] as? String, !result.isEmpty, result != text else { return false }
            text = result
            return true
        default:
            return false
        }
    }
}

// MARK: - Вкладка «Созвон»

struct CallView: View {
    @ObservedObject private var call = CallAssistant.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showOptions = false
    /// 0 — самый свежий ответ, 1 — предыдущий и т. д.
    @State private var offset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader("Созвон", subtitle: call.status ?? subtitle) {
                Picker("", selection: $call.ai) {
                    ForEach(CallAI.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)
                Button { settings.hideFromScreenShare.toggle() } label: {
                    Image(systemName: settings.hideFromScreenShare ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(settings.hideFromScreenShare ? Color.green : Color.orange)
                }
                .buttonStyle(PillButton())
                .help(settings.hideFromScreenShare
                      ? "Шторку не видно при демонстрации экрана. Нажми, чтобы показывать"
                      : "Шторку видно при демонстрации экрана. Нажми, чтобы спрятать")
                Button { showOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(PillButton())
                    .help("Настройки созвона")
                Button { call.toggle() } label: {
                    Label(call.listening ? "Стоп" : "Слушать",
                          systemImage: call.listening ? "stop.fill" : "waveform")
                        .foregroundStyle(call.listening ? Color.red : Color.primary)
                }
                .buttonStyle(PillButton())
                .disabled(call.starting)
            }

            HStack(alignment: .top, spacing: 10) {
                Group {
                    if showOptions { options } else { transcript }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card()

                answerPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .card(true)
            }
        }
        .onChange(of: call.answers.count) { _, _ in offset = 0 }
    }

    private var subtitle: String {
        if call.listening {
            return settings.hideFromScreenShare ? "Слушаю · шторку не видно в демонстрации экрана"
                                                : "Слушаю · шторку ВИДНО в демонстрации экрана"
        }
        return "Слышу собеседников и сразу подсказываю ответ"
    }

    // Расшифровка
    @ViewBuilder private var transcript: some View {
        if call.lines.isEmpty && call.partialThem.isEmpty && call.partialMe.isEmpty {
            EmptyState(icon: "waveform",
                       text: call.listening
                       ? "Слушаю… Как только кто-то заговорит, текст появится здесь"
                       : "Нажми «Слушать», и я буду слышать звук созвона и подсказывать ответы на вопросы.\nПредупреди собеседников, что ведёшь запись.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(call.lines) { line in
                            lineRow(line).id(line.id)
                        }
                        if !call.partialThem.isEmpty { partialRow("Они", call.partialThem) }
                        if !call.partialMe.isEmpty { partialRow("Я", call.partialMe) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: call.lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: call.partialThem) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: call.partialMe) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func lineRow(_ line: CallLine) -> some View {
        let answered = call.answeredLines.contains(line.id)
        return HStack(alignment: .top, spacing: 6) {
            Text(line.speaker == .them ? "Они" : "Я")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(line.speaker == .them ? Color.blue : Color.secondary)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 2)
            Text(line.text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { call.ask(line) } label: {
                Image(systemName: answered ? "checkmark.bubble.fill" : "sparkles")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(answered ? Color.green : Color.primary.opacity(0.45))
            .disabled(answered)
            .help(answered ? "Уже ответила" : "Ответить на это")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(line.isQuestion ? Color.yellow.opacity(0.14) : Color.clear))
    }

    private func partialRow(_ who: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(who).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 2)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5)
    }

    // Настройки созвона
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("Кто я и о чём созвон").font(.system(size: 11, weight: .semibold))
                TextField("Например: собеседование на дизайнера, отвечай уверенно и по-простому",
                          text: $call.context, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(2...4)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                toggle("Отвечать на вопросы сама", $call.autoAnswer)
                toggle("Выдвигать шторку с ответом", $call.popUp)
                toggle("Быстрые ответы (проще, но быстрее)", $call.fast)
                toggle("Мой микрофон тоже", $call.useMic)
                toggle("Прятать шторку при демонстрации экрана", $settings.hideFromScreenShare)
                HStack {
                    Text("Язык созвона").font(.caption)
                    Spacer()
                    Picker("", selection: $call.language) {
                        ForEach(CallAssistant.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 120)
                    .disabled(call.listening)
                }
                Text("Записывать собеседников лучше с их согласия.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Text(title).font(.caption) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    // Ответ нейросети
    private var shown: CallAnswer? {
        guard !call.answers.isEmpty else { return nil }
        let i = call.answers.count - 1 - min(offset, call.answers.count - 1)
        return call.answers[i]
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let a = shown {
                HStack(spacing: 6) {
                    Image(systemName: a.isSummary ? "list.bullet.rectangle" : "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(a.ai == .claude ? UsageProviders.claude.color : UsageProviders.codex.color)
                    Text(a.question).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if call.answers.count > 1 {
                        Button { offset += 1 } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).disabled(offset >= call.answers.count - 1)
                        Text("\(call.answers.count - offset)/\(call.answers.count)")
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        Button { offset -= 1 } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).disabled(offset == 0)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                ScrollView {
                    Group {
                        if let error = a.error {
                            Text(error).foregroundStyle(.red)
                        } else if a.text.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(a.ai.title) думает…").foregroundStyle(.secondary)
                            }
                        } else {
                            Text(Self.markdown(a.text)).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyState(icon: "sparkles",
                           text: "Здесь появится ответ \(call.ai.title), как только тебе зададут вопрос")
            }
            HStack(spacing: 6) {
                Button("Ответить") { call.askLast() }
                    .buttonStyle(PillButton())
                    .help("Ответить на последний вопрос собеседника")
                    .disabled(call.lines.isEmpty)
                Button("Конспект") { call.makeSummary() }
                    .buttonStyle(PillButton())
                    .disabled(call.lines.isEmpty)
                Spacer(minLength: 0)
                Button { call.revealFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(PillButton())
                    .help("Папка с расшифровками созвонов")
                if let a = shown, !a.text.isEmpty {
                    Button { Pasteboard.copy(a.text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(PillButton())
                        .help("Копировать ответ")
                }
            }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
