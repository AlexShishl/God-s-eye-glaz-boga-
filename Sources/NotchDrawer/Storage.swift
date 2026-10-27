import AppKit

enum Storage {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDrawer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardStore.shared.markOwnChange()
    }

    static func copyImage(at url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = []
        if let image = NSImage(contentsOf: url) { objects.append(image) }
        objects.append(url as NSURL)
        pb.writeObjects(objects)
        ClipboardStore.shared.markOwnChange()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum RuDate {
    static let time: DateFormatter = make("HH:mm")
    static let day: DateFormatter = make("EEEE, d MMMM")
    static let shortDay: DateFormatter = make("EE, d MMM")
    static let weekdayTime: DateFormatter = make("EE HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }
}
