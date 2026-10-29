import AppKit
import EventKit

/// «Выдать разрешения…» в меню: по очереди вызывает все системные запросы,
/// чтобы осталось только нажимать «Разрешить».
enum Permissions {
    static func requestAll() {
        Task { @MainActor in
            // Календарь и Напоминания
            CalendarStore.shared.requestAccess()
            try? await Task.sleep(for: .seconds(1))
            while EKEventStore.authorizationStatus(for: .event) == .notDetermined
                    || EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                try? await Task.sleep(for: .seconds(1))
            }

            // Рабочий стол и Документы (для скриншотов)
            let home = FileManager.default.homeDirectoryForCurrentUser
            _ = try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Desktop").path)
            _ = try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Documents").path)

            // Автоматизация: Музыка и Spotify, если запущены
            for id in ["com.apple.Music", "com.spotify.client"] {
                await Task.detached { askAutomation(bundleID: id) }.value
            }

            // Связка ключей: лимиты Claude спросят доступ к «Claude Code-credentials»
            UsageProviders.claude.refresh()

            // Запись экрана: для «Текста с экрана» во вкладке «Буфер»
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

            // Микрофон и распознавание речи: для вкладки «Созвон»
            _ = await CallPermissions.microphone()
            _ = await CallPermissions.speech()

            // Универсальный доступ: системное окно со ссылкой в Настройки
            NowPlaying.shared.requestAccessibility()
        }
    }

    private static func askAutomation(bundleID: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return }
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else { return }
        defer { AEDisposeDesc(&target) }
        _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    }
}
