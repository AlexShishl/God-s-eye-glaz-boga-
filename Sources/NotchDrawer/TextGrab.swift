import AppKit
import Carbon
import ImageIO
import SwiftUI
import Vision

extension Notification.Name {
    /// Просьба спрятать шторку (например, перед выделением области экрана).
    static let closeDrawer = Notification.Name("GlazCloseDrawer")
}

/// «Текст с экрана»: выделяешь область — Vision распознаёт текст (русский и английский)
/// и кладёт его в буфер обмена, а значит и в историю на вкладке «Буфер».
final class TextGrabber: ObservableObject {
    static let shared = TextGrabber()

    /// Короткая подсказка под заголовком вкладки «Буфер» после распознавания.
    @Published private(set) var status: String?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        NotificationCenter.default.post(name: .closeDrawer, object: nil)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glaz-ocr-\(UUID().uuidString).png")
        // Даём шторке уехать, чтобы она не попала в снимок.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-x", url.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                } catch {
                    NSLog("screencapture error: \(error)")
                }
                let text = Self.recognize(url)
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self.finish(text) }
            }
        }
    }

    /// nil — область не выбрали (нажали Esc), пустая строка — текста нет.
    private static func recognize(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("Vision error: \(error)")
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    private func finish(_ text: String?) {
        running = false
        guard let text else { return }
        let clean = text.trimmed
        if clean.isEmpty {
            NSSound(named: "Basso")?.play()
            show(CGPreflightScreenCaptureAccess()
                 ? "Текст не нашёлся"
                 : "Разреши «Запись экрана» для Глаза Бога в Системных настройках")
            return
        }
        ClipboardStore.shared.copy(ClipItem(text: clean, date: Date()))
        NSSound(named: "Tink")?.play()
        show("Текст с экрана скопирован")
    }

    private func show(_ message: String) {
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status == message { self?.status = nil }
        }
    }
}

// MARK: - Сочетание клавиш

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    /// Модификаторы в формате Carbon (cmdKey, shiftKey…).
    var modifiers: UInt32
    var key: String

    static let `default` = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), key: "2")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }
}

extension HotKey {
    /// Нужен хотя бы один из ⌘ ⌃ ⌥, иначе сочетание будет мешать обычному набору текста.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        let code = Int(event.keyCode)
        self.init(keyCode: UInt32(code), modifiers: mods,
                  key: Self.names[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }

    /// Названия клавиш по их месту на клавиатуре — чтобы при русской раскладке было «⌘⇧T», а не «⌘⇧Е».
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Глобальное сочетание клавиш для «Текста с экрана». Работает через Carbon,
/// поэтому не требует разрешения «Универсальный доступ».
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()
    private let defaults = UserDefaults.standard

    /// nil — сочетание выключено.
    @Published var textGrab: HotKey? {
        didSet {
            defaults.set(textGrab == nil, forKey: "textGrabHotKeyOff")
            if let textGrab, let data = try? JSONEncoder().encode(textGrab) {
                defaults.set(data, forKey: "textGrabHotKey")
            }
            register()
        }
    }

    /// Пока в настройках записывают новое сочетание, старое не срабатывает.
    var paused = false {
        didSet { register() }
    }

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    init() {
        if defaults.bool(forKey: "textGrabHotKeyOff") {
            textGrab = nil
        } else if let data = defaults.data(forKey: "textGrabHotKey"),
                  let saved = try? JSONDecoder().decode(HotKey.self, from: data) {
            textGrab = saved
        } else {
            textGrab = .default
        }
    }

    func register() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        installHandler()
        guard let hk = textGrab, !paused else { return }
        let id = EventHotKeyID(signature: OSType(0x474C_415A), id: 1) // 'GLAZ'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("RegisterEventHotKey error: \(status)") }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { TextGrabber.shared.start() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Кнопка в настройках: нажми и введи новое сочетание (Esc — отмена).
struct HotKeyRecorder: View {
    @ObservedObject private var center = HotKeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Нажми сочетание…" : (center.textGrab?.display ?? "Выключено")) {
                if recording { stop() } else { record() }
            }
            .buttonStyle(PillButton())
            .help("Нажми и введи новое сочетание, Esc — отмена")

            if !recording {
                if center.textGrab != nil {
                    Button { center.textGrab = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Выключить сочетание")
                } else {
                    Button { center.textGrab = .default } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Вернуть \(HotKey.default.display)")
                }
            }
        }
        .font(.caption)
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        center.paused = true
        // Шторка не забирает клавиатуру сама — просим её об этом, пока ждём сочетание.
        NSApp.windows.first { $0 is NotchPanel }?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let hk = HotKey(event: event) {
                center.textGrab = hk
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        center.paused = false
    }
}
