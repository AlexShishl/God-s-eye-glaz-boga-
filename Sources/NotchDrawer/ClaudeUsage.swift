import Foundation
import SwiftUI

/// Лимиты Claude Code: 5-часовая сессия и неделя.
/// Берёт вход из Claude Code (Связка ключей) и спрашивает тот же сервер, что и команда /usage.
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    struct Limit {
        let percent: Double
        let resetsAt: Date?
    }

    @Published var session: Limit?
    @Published var week: Limit?
    @Published var error: String?
    @Published var loading = false
    private var lastUpdate: Date?
    private var token: String?

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

    private struct UsageError: Error {
        let message: String
    }

    private func fetch() async -> Result<(Limit?, Limit?), UsageError> {
        for attempt in 0..<2 {
            if token == nil || attempt > 0 { token = Self.readToken() }
            guard let token else {
                return .failure(UsageError(message: "Не нашла вход Claude Code: запусти claude в Терминале и войди"))
            }
            if let exp = Self.tokenExpiry, exp < Date() {
                if attempt == 0 { continue }
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
                if attempt == 0 { continue }
                return .failure(UsageError(message: "Сервер не пустил (код \(status)): запусти claude в Терминале и войди заново"))
            }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(UsageError(message: "Не получилось узнать лимиты (код \(status))"))
            }
            return .success((Self.limit(json["five_hour"]), Self.limit(json["seven_day"])))
        }
        return .failure(UsageError(message: "Не получилось узнать лимиты"))
    }

    private static var tokenExpiry: Date?

    private static func limit(_ any: Any?) -> Limit? {
        guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        return Limit(percent: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Claude Code хранит вход в Связке ключей («Claude Code-credentials») или в ~/.claude/.credentials.json.
    private static func readToken() -> String? {
        var raw: Data?
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            raw = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { raw = nil }
        }
        if raw == nil {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            raw = try? Data(contentsOf: file)
        }
        guard let raw,
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        tokenExpiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return token
    }
}

/// Строка внизу шторки: «Claude Code · Сессия ▓▓░ 23% · Неделя ▓░ 41%».
struct UsageStrip: View {
    @EnvironmentObject var state: DrawerState
    @ObservedObject private var usage = ClaudeUsage.shared

    var body: some View {
        HStack(spacing: 14) {
            Label("Claude Code", systemImage: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
            if let error = usage.error, usage.session == nil {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(error)
            } else {
                meter("Сессия", usage.session, resetFormat: RuDate.time)
                meter("Неделя", usage.week, resetFormat: RuDate.weekdayTime)
            }
            Spacer(minLength: 0)
            Button { usage.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(usage.loading ? 180 : 0))
                    .animation(.easeInOut(duration: 0.4), value: usage.loading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Обновить лимиты")
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .onAppear { usage.refreshIfNeeded() }
        .onChange(of: state.isOpen) { _, open in
            if open { usage.refreshIfNeeded() }
        }
    }

    private func meter(_ title: String, _ limit: ClaudeUsage.Limit?, resetFormat: DateFormatter) -> some View {
        let pct = limit?.percent ?? 0
        let color: Color = pct < 60 ? .green : (pct < 85 ? .orange : .red)
        return HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: 70 * min(max(pct, 0), 100) / 100)
            }
            .frame(width: 70, height: 5)
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
