import Foundation
import SwiftUI

struct UsageLimit {
    let percent: Double
    let resetsAt: Date?
}

struct UsageError: Error {
    let message: String
}

/// Источник лимитов одной нейросети: «сессия» (короткое окно) и «неделя».
class UsageSource: ObservableObject {
    let name: String
    let icon: String
    let color: Color

    @Published var session: UsageLimit?
    @Published var week: UsageLimit?
    @Published var error: String?
    @Published var loading = false
    private var lastUpdate: Date?

    init(name: String, icon: String, color: Color) {
        self.name = name
        self.icon = icon
        self.color = color
    }

    func refreshIfNeeded() {
        if let lastUpdate, Date().timeIntervalSince(lastUpdate) < 120 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = await self.fetch()
            await MainActor.run {
                self.loading = false
                self.lastUpdate = Date()
                switch result {
                case .success(let (session, week)):
                    self.session = session
                    self.week = week
                    self.error = nil
                case .failure(let err):
                    self.error = err.message
                }
            }
        }
    }

    /// Переопределяется в наследниках.
    func fetch() async -> Result<(UsageLimit?, UsageLimit?), UsageError> {
        .failure(UsageError(message: "Не поддерживается"))
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Все нейросети, лимиты которых умеет показывать шторка.
enum UsageProviders {
    static let claude = ClaudeUsage()
    static let codex = CodexUsage()

    struct Info: Identifiable {
        let id: String
        let source: UsageSource
        let hint: String
    }

    static let all: [Info] = [
        Info(id: "claude", source: claude, hint: "Claude Code и claude.ai: 5-часовая сессия и неделя"),
        Info(id: "codex", source: codex, hint: "Codex (ChatGPT): цифры с последнего запуска codex в Терминале"),
    ]
}

// MARK: - Claude Code

/// Берёт вход из Claude Code (Связка ключей) и спрашивает тот же сервер, что и команда /usage.
final class ClaudeUsage: UsageSource {
    private var token: String?
    private static var tokenExpiry: Date?

    init() {
        super.init(name: "Claude", icon: "sparkle", color: Color(red: 0.85, green: 0.47, blue: 0.34))
    }

    override func fetch() async -> Result<(UsageLimit?, UsageLimit?), UsageError> {
        for attempt in 0..<2 {
            if token == nil || attempt > 0 { token = Self.readToken() }
            guard let token else {
                return .failure(UsageError(message: "Не нашла вход Claude Code: запусти claude в Терминале и войди"))
            }
            if let exp = Self.tokenExpiry, exp < Date().addingTimeInterval(60) {
                if attempt == 0, await Self.refreshLogin() { continue }
                return .failure(UsageError(message: "Вход Claude Code на этом Mac истёк: запусти claude в Терминале, и строка оживёт"))
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15
            guard let reply = try? await URLSession.shared.data(for: req) else {
                return .failure(UsageError(message: "Нет интернета"))
            }
            let (data, response) = reply
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                if attempt == 0, await Self.refreshLogin() { continue }
                return .failure(UsageError(message: "Сервер не пустил (код \(status)): запусти claude в Терминале и войди заново"))
            }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(UsageError(message: "Не получилось узнать лимиты (код \(status))"))
            }
            return .success((Self.limit(json["five_hour"]), Self.limit(json["seven_day"])))
        }
        return .failure(UsageError(message: "Не получилось узнать лимиты"))
    }

    private static func limit(_ any: Any?) -> UsageLimit? {
        guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        return UsageLimit(percent: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
    }

    private static let service = "Claude Code-credentials"
    private static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    /// Claude Code хранит вход в Связке ключей («Claude Code-credentials») или в ~/.claude/.credentials.json.
    private static func readCredentials() -> (json: [String: Any], inKeychain: Bool)? {
        if let out = security(["find-generic-password", "-s", service, "-w"]),
           let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
            return (json, true)
        }
        if let data = try? Data(contentsOf: credentialsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, false)
        }
        return nil
    }

    private static func readToken() -> String? {
        guard let oauth = readCredentials()?.json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        tokenExpiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return token
    }

    /// Вход протух: обновляем его так же, как сам Claude Code (по refreshToken),
    /// и записываем новый вход обратно, чтобы Claude Code тоже продолжил работать.
    private static func refreshLogin() async -> Bool {
        guard let (json, inKeychain) = readCredentials(),
              var oauth = json["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else { return false }

        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = reply["access_token"] as? String
        else { return false }

        oauth["accessToken"] = access
        if let newRefresh = reply["refresh_token"] as? String { oauth["refreshToken"] = newRefresh }
        if let expiresIn = reply["expires_in"] as? Double {
            oauth["expiresAt"] = ((Date().timeIntervalSince1970 + expiresIn) * 1000).rounded()
        }
        var updated = json
        updated["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: updated),
              let text = String(data: out, encoding: .utf8) else { return false }

        if inKeychain {
            let account = keychainAccount() ?? NSUserName()
            _ = security(["add-generic-password", "-U", "-a", account, "-s", service, "-w", text])
        } else {
            try? out.write(to: credentialsFile, options: .atomic)
        }
        return true
    }

    private static func keychainAccount() -> String? {
        guard let out = security(["find-generic-password", "-s", service]),
              let text = String(data: out, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.contains("\"acct\"") }),
              let start = line.range(of: "=\"")?.upperBound
        else { return nil }
        return String(line[start...].dropLast())
    }

    private static func security(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

// MARK: - Codex (ChatGPT)

/// Codex CLI записывает свои лимиты в журналы ~/.codex/sessions/…/*.jsonl после каждого ответа.
/// Читаем самую свежую запись, поэтому цифры такие, какими были при последнем запуске codex.
final class CodexUsage: UsageSource {
    init() {
        super.init(name: "Codex", icon: "circle.hexagongrid.fill", color: Color(red: 0.45, green: 0.75, blue: 0.65))
    }

    override func fetch() async -> Result<(UsageLimit?, UsageLimit?), UsageError> {
        guard let newest = Self.newestLogs() else {
            return .failure(UsageError(message: "Codex ещё не запускался на этом Mac"))
        }
        for url in newest {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let limits = Self.findRateLimits(json) else { continue }
                let stamp = (json["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()
                return .success((Self.limit(limits["primary"], stamp), Self.limit(limits["secondary"], stamp)))
            }
        }
        return .failure(UsageError(message: "Нет данных: сделай один запрос в codex"))
    }

    private static func newestLogs() -> [URL]? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var logs: [(URL, Date)] = []
        while let url = files.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            logs.append((url, date))
        }
        return logs.sorted { $0.1 > $1.1 }.prefix(5).map { $0.0 }
    }

    private static func findRateLimits(_ any: Any) -> [String: Any]? {
        guard let dict = any as? [String: Any] else { return nil }
        if let r = dict["rate_limits"] as? [String: Any] { return r }
        for value in dict.values {
            if let r = findRateLimits(value) { return r }
        }
        return nil
    }

    private static func limit(_ any: Any?, _ stamp: Date) -> UsageLimit? {
        guard let d = any as? [String: Any], let used = d["used_percent"] as? Double else { return nil }
        var reset: Date?
        if let at = d["resets_at"] as? Double {
            reset = Date(timeIntervalSince1970: at)
        } else if let inSec = d["resets_in_seconds"] as? Double {
            reset = stamp.addingTimeInterval(inSec)
        }
        // Если окно уже сбросилось, значит, сейчас израсходовано 0%.
        if let r = reset, r < Date() { return UsageLimit(percent: 0, resetsAt: nil) }
        return UsageLimit(percent: used, resetsAt: reset)
    }
}

// MARK: - Строки внизу шторки

/// «Claude · Сессия ▓▓░ 23% · Неделя ▓░ 41%», по строке на каждую включённую нейросеть.
struct UsageStrip: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 4) {
            ForEach(UsageProviders.all.filter { settings.isOn(limits: $0.id) }) { p in
                UsageRow(source: p.source)
            }
        }
    }
}

private struct UsageRow: View {
    @EnvironmentObject var state: DrawerState
    @ObservedObject var source: UsageSource

    var body: some View {
        HStack(spacing: 12) {
            Label(source.name, systemImage: source.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(source.color)
                .frame(width: 70, alignment: .leading)
            if let error = source.error, source.session == nil {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(error)
            } else {
                meter("Сессия", source.session, resetFormat: RuDate.time)
                meter("Неделя", source.week, resetFormat: RuDate.weekdayTime)
            }
            Spacer(minLength: 0)
            Button { source.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(source.loading ? 180 : 0))
                    .animation(.easeInOut(duration: 0.4), value: source.loading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Обновить лимиты")
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .onAppear { source.refreshIfNeeded() }
        .onChange(of: state.isOpen) { _, open in
            if open { source.refreshIfNeeded() }
        }
    }

    private func meter(_ title: String, _ limit: UsageLimit?, resetFormat: DateFormatter) -> some View {
        let pct = limit?.percent ?? 0
        let color: Color = pct < 60 ? .green : (pct < 85 ? .orange : .red)
        return HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: 60 * min(max(pct, 0), 100) / 100)
            }
            .frame(width: 60, height: 5)
            Text(limit == nil ? "—" : "\(Int(pct.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            if let reset = limit?.resetsAt {
                Text("сброс \(resetFormat.string(from: reset))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
