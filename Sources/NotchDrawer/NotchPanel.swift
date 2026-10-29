import AppKit
import Combine
import SwiftUI

final class DrawerState: ObservableObject {
    static let shared = DrawerState()
    @Published var isOpen = false
    @Published var pinned = false
    @Published var notchSize = CGSize(width: 200, height: 32)
}

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Следит за мышкой: навели на вырез — шторка выезжает, увели — прячется.
final class NotchController {
    static let baseSize = CGSize(width: 620, height: 300)

    /// Размер шторки с учётом ползунка «Размер» в настройках.
    static var panelSize: CGSize {
        let s = AppSettings.shared.scale
        return CGSize(width: (baseSize.width * s).rounded(), height: (baseSize.height * s).rounded())
    }

    private var panel = NotchPanel(size: NotchController.panelSize)
    private let state = DrawerState.shared
    private var timer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var hotZone = NSRect.zero
    private var menuTracking = false
    private var scaleWatcher: AnyCancellable?
    private var shareWatcher: AnyCancellable?

    init() {
        setupPanel()
        layout()

        // Dock перезапустился (например, его перезапустил установщик) — вместе с ним
        // пересоздаются рабочие столы, и старое окно шторки может перестать показываться.
        // Собираем окно заново.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.rebuildPanel() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .closeDrawer, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        // Пока открыт выпадающий список (например, выбор языка), шторку не закрываем.
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false
        }

        // Двигают ползунок размера — сразу меняем окно (после того как значение сохранится).
        scaleWatcher = AppSettings.shared.$scale
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }

        // Демонстрация экрана: .none — окна нет в чужих записях и трансляциях экрана.
        shareWatcher = AppSettings.shared.$hideFromScreenShare
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hide in self?.panel.sharingType = hide ? .none : .readOnly }

        // Созвон: пришёл ответ — выдвигаем шторку на вкладке «Созвон».
        nc.addObserver(forName: .showCallAnswer, object: nil, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(DrawerTab.call.rawValue, forKey: "lastTab")
            if self?.state.isOpen == false { self?.open(pinned: true) }
        }

        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func setupPanel() {
        let host = NSHostingView(rootView: DrawerRootView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.close() }
        panel.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
    }

    /// Новое окно вместо старого: спасает шторку, если система её «потеряла».
    func rebuildPanel() {
        let wasOpen = state.isOpen
        panel.orderOut(nil)
        panel.contentView = nil
        panel = NotchPanel(size: Self.panelSize)
        setupPanel()
        layout()
        if wasOpen { panel.orderFrontRegardless() }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        let f = screen.frame
        var notchW: CGFloat = 200
        var notchH = f.maxY - screen.visibleFrame.maxY
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchW = right.minX - left.maxX
            notchH = screen.safeAreaInsets.top
        }
        if notchH <= 0 { notchH = 24 }
        state.notchSize = CGSize(width: notchW, height: notchH)

        let size = Self.panelSize
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        hotZone = NSRect(x: f.midX - notchW / 2 - 10, y: f.maxY - notchH,
                         width: notchW + 20, height: notchH + 2)
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let now = Date()

        guard state.isOpen else {
            if hotZone.contains(p) {
                if hoverStart == nil { hoverStart = now }
                if now.timeIntervalSince(hoverStart!) > 0.12 { open(pinned: false) }
            } else {
                hoverStart = nil
            }
            return
        }

        let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(p)
        let dragging = NSEvent.pressedMouseButtons != 0
        if inside || dragging || menuTracking || state.pinned {
            leaveStart = nil
        } else {
            if leaveStart == nil { leaveStart = now }
            if now.timeIntervalSince(leaveStart!) > 0.35 { close() }
        }
    }

    func open(pinned: Bool) {
        hoverStart = nil
        leaveStart = nil
        if pinned { state.pinned = true }
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.isOpen = true }
    }

    func close() {
        leaveStart = nil
        state.pinned = false
        withAnimation(.easeIn(duration: 0.18)) { state.isOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel.orderOut(nil)
        }
    }
}
