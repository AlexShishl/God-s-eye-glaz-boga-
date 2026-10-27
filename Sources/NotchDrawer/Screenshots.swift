import AppKit
import ImageIO
import SwiftUI

struct ShotItem: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let date: Date

    var url: URL {
        ScreenshotStore.shelfDir.appendingPathComponent(id.uuidString).appendingPathComponent(name)
    }
}

/// Полка скриншотов: новые скриншоты копируются сюда и живут 12 часов.
final class ScreenshotStore: ObservableObject {
    static let shared = ScreenshotStore()
    static let retention: TimeInterval = 12 * 60 * 60

    static let shelfDir: URL = {
        let d = Storage.dir.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @Published private(set) var items: [ShotItem] = []
    /// Превью в углу экрана задерживает сохранение файла, пока не исчезнет.
    @Published var cornerPreviewEnabled = ScreenshotStore.readCornerPreview()
    private var seen = Set<String>()
    private var thumbs: [UUID: NSImage] = [:]
    private var timer: Timer?
    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    /// Папка, куда macOS сохраняет скриншоты (по умолчанию — Рабочий стол).
    var watchDir: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func readCornerPreview() -> Bool {
        UserDefaults(suiteName: "com.apple.screencapture")?.object(forKey: "show-thumbnail") as? Bool ?? true
    }

    /// То же, что снять галочку «Показывать плавающую миниатюру» в ⌘⇧5 → Параметры.
    func disableCornerPreview() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", "false"]
        try? p.run()
        p.waitUntilExit()
        cornerPreviewEnabled = false
    }

    func start() {
        items = Storage.load([ShotItem].self, from: "shots.json") ?? []
        purge()
        seen = Set(listFiles().map(\.path))
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func listFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: watchDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func isScreenshot(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return ["Снимок экрана", "Screenshot", "Screen Shot"].contains { name.hasPrefix($0) }
    }

    private func scan() {
        guard AppSettings.shared.isOn(.shots) else {
            seen.formUnion(listFiles().map(\.path))
            purge()
            return
        }
        for file in listFiles() where !seen.contains(file.path) {
            seen.insert(file.path)
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard Date().timeIntervalSince(created) < 120, isScreenshot(file) else { continue }
            add(file)
        }
        purge()
    }

    private func add(_ file: URL) {
        let item = ShotItem(id: UUID(), name: file.lastPathComponent, date: Date())
        let folder = item.url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: item.url)
        } catch {
            NSLog("Screenshot copy failed: \(error)")
            return
        }
        withAnimation(.spring(response: 0.3)) { items.insert(item, at: 0) }
        save()
    }

    private func purge() {
        let now = Date()
        let expired = items.filter {
            now.timeIntervalSince($0.date) > Self.retention || !FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard !expired.isEmpty else { return }
        expired.forEach(deleteFiles)
        items.removeAll { item in expired.contains(item) }
        save()
    }

    func remove(_ item: ShotItem) {
        deleteFiles(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeAll() {
        items.forEach(deleteFiles)
        items.removeAll()
        save()
    }

    private func deleteFiles(_ item: ShotItem) {
        thumbs[item.id] = nil
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
    }

    private func save() { Storage.save(items, to: "shots.json") }

    func thumbnail(for item: ShotItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        thumbs[item.id] = img
        return img
    }
}

struct ShotsView: View {
    @ObservedObject private var store = ScreenshotStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader("Скриншоты", subtitle: store.items.isEmpty
                      ? "Хранятся 12 часов"
                      : "\(store.items.count) шт. · перетащи куда нужно · хранятся 12 часов") {
                if !store.items.isEmpty {
                    Button("Очистить всё") { withAnimation { store.removeAll() } }.buttonStyle(PillButton())
                }
                Button { NSWorkspace.shared.open(store.watchDir) } label: { Image(systemName: "folder") }
                    .buttonStyle(PillButton())
                    .help("Открыть папку со скриншотами")
            }

            if store.cornerPreviewEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    Text("Сейчас скриншот ждёт, пока исчезнет превью в углу экрана.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Сразу в шторку") { store.disableCornerPreview() }.buttonStyle(PillButton())
                }
                .card()
            }

            if store.items.isEmpty {
                EmptyState(icon: "camera.viewfinder", text: "Нажми ⌘⇧3 или ⌘⇧4 — и скриншот сразу появится здесь")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(store.items) { ShotThumb(item: $0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ShotThumb: View {
    let item: ShotItem
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = ScreenshotStore.shared.thumbnail(for: item) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
                .frame(width: 150, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(hover ? 0.45 : 0.1), lineWidth: 1))

                if hover {
                    Button {
                        withAnimation { ScreenshotStore.shared.remove(item) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Удалить с полки")
                }
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Открыть") { NSWorkspace.shared.open(item.url) }
            Button("Скопировать картинку") { Pasteboard.copyImage(at: item.url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Удалить") { ScreenshotStore.shared.remove(item) }
        }
    }

    private var caption: String {
        let left = max(0, ScreenshotStore.retention - Date().timeIntervalSince(item.date))
        let hours = Int(left / 3600)
        let rest = hours > 0 ? "ещё \(hours) ч" : "ещё \(Int(left / 60)) мин"
        return "\(RuDate.time.string(from: item.date)) · \(rest)"
    }
}
