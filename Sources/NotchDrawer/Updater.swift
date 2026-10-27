import AppKit

/// «Обновить…» в меню: скачивает свежую версию с GitHub, собирает и перезапускает приложение.
/// Всё происходит в окне Терминала, чтобы было видно, что идёт.
enum Updater {
    static let repo = "https://github.com/AlexShishl/glaz-boga.git"

    static func run() {
        let script = """
        #!/bin/bash
        set -e
        SRC="$HOME/Library/Application Support/NotchDrawer/source"
        echo "👁  Обновляю Глаз Бога…"
        if [ -d "$SRC/.git" ]; then
            git -C "$SRC" fetch --quiet origin
            git -C "$SRC" reset --hard --quiet origin/HEAD
        else
            rm -rf "$SRC"
            git clone "\(repo)" "$SRC"
        fi
        bash "$SRC/build.sh" --install
        echo ""
        echo "✅ Готово! Это окно можно закрыть."
        """
        let url = Storage.dir.appendingPathComponent("update.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            NSLog("Updater: \(error)")
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
