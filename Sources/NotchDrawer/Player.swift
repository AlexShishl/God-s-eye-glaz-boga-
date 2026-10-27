import AppKit
import ApplicationServices
import SwiftUI

/// Достаёт «что сейчас играет» через системный MediaRemote (работает не на всех версиях macOS).
private final class MediaRemote {
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private var getInfo: GetInfoFn?
    private var sendFn: SendFn?

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return }
        if let s = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") { getInfo = unsafeBitCast(s, to: GetInfoFn.self) }
        if let s = dlsym(h, "MRMediaRemoteSendCommand") { sendFn = unsafeBitCast(s, to: SendFn.self) }
    }

    func nowPlaying(_ completion: @escaping ([String: Any]?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(DispatchQueue.main) { completion($0) }
    }

    @discardableResult
    func send(_ command: UInt32) -> Bool { sendFn?(command, nil) ?? false }
}

enum PlayerCommand {
    case playPause, next, previous

    var mediaRemote: UInt32 {
        switch self {
        case .playPause: 2
        case .next: 4
        case .previous: 5
        }
    }

    // NX_KEYTYPE_PLAY / NEXT / PREVIOUS
    var mediaKey: Int {
        switch self {
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
    }
}

final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var source = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var artworkURL: URL?
    @Published var duration: Double = 0
    @Published var elapsed: Double = 0
    @Published var canUseMediaKeys = AXIsProcessTrusted()

    private let remote = MediaRemote()
    private var timer: Timer?
    private var artworkSize = 0

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard DrawerState.shared.isOpen else { return }
        canUseMediaKeys = AXIsProcessTrusted()
        remote.nowPlaying { [weak self] info in
            guard let self else { return }
            if let info, let t = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !t.isEmpty {
                self.apply(mediaRemote: info, title: t)
            } else {
                self.refreshViaAppleScript()
            }
        }
    }

    private func apply(mediaRemote info: [String: Any], title: String) {
        self.title = title
        artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        source = ""
        artworkURL = nil
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        isPlaying = rate > 0
        duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
        var e = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        if isPlaying, let ts = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            e += Date().timeIntervalSince(ts) * rate
        }
        elapsed = e
        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            if data.count != artworkSize {
                artworkSize = data.count
                artwork = NSImage(data: data)
            }
        } else {
            artworkSize = 0
            artwork = nil
        }
    }

    /// Запасной путь: спрашиваем Spotify и Музыку напрямую (только если они уже запущены).
    private func refreshViaAppleScript() {
        let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        for (bundleID, name) in players {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { continue }
            let art = name == "Spotify" ? " & \"||\" & (artwork url of current track)" : ""
            let source = """
            tell application "\(name)"
                if player state is stopped then return ""
                return (name of current track) & "||" & (artist of current track) & "||" & (album of current track) & "||" & (player state as string) & "||" & (player position as string) & "||" & (duration of current track as string)\(art)
            end tell
            """
            var error: NSDictionary?
            guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "||")
            guard parts.count >= 6 else { continue }
            func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

            title = parts[0]
            artist = parts[1]
            album = parts[2]
            isPlaying = parts[3] == "playing"
            elapsed = num(parts[4])
            duration = name == "Spotify" ? num(parts[5]) / 1000 : num(parts[5])
            self.source = name == "Music" ? "Музыка" : name
            artwork = nil
            artworkSize = 0
            artworkURL = parts.count > 6 ? URL(string: parts[6]) : nil
            return
        }
        title = ""
        artist = ""
        album = ""
        source = ""
        isPlaying = false
        duration = 0
        artwork = nil
        artworkURL = nil
    }

    func send(_ command: PlayerCommand) {
        if AXIsProcessTrusted() {
            postMediaKey(command.mediaKey)
        } else {
            remote.send(command.mediaRemote)
        }
        if command == .playPause { isPlaying.toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    /// Нажимает «медиа-клавишу» — работает с любым плеером, включая YouTube в браузере.
    private func postMediaKey(_ key: Int) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        canUseMediaKeys = AXIsProcessTrustedWithOptions(options)
    }
}

struct PlayerView: View {
    @ObservedObject private var np = NowPlaying.shared

    var body: some View {
        HStack(spacing: 16) {
            artwork
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                if np.title.isEmpty {
                    Text("Сейчас ничего не играет").font(.headline)
                    Text("Включи музыку где угодно: Музыка, Spotify, YouTube в браузере.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(np.title).font(.headline).lineLimit(1)
                    Text(np.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if !np.album.isEmpty || !np.source.isEmpty {
                        Text([np.album, np.source].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }

                if np.duration > 0 {
                    VStack(spacing: 3) {
                        ProgressView(value: min(np.elapsed, np.duration), total: np.duration)
                            .progressViewStyle(.linear)
                            .tint(.white)
                        HStack {
                            Text(format(np.elapsed))
                            Spacer()
                            Text(format(np.duration))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 24) {
                    control("backward.fill", .previous, size: 16)
                    control(np.isPlaying ? "pause.fill" : "play.fill", .playPause, size: 24)
                    control("forward.fill", .next, size: 16)
                }
                .frame(maxWidth: .infinity)

                if !np.canUseMediaKeys {
                    Button("Разрешить управлять любым плеером") { np.requestAccessibility() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.top, 4)
        .onAppear { np.startPolling() }
        .onDisappear { np.stopPolling() }
    }

    @ViewBuilder private var artwork: some View {
        if let img = np.artwork {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let url = np.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func control(_ icon: String, _ command: PlayerCommand, size: CGFloat) -> some View {
        Button { np.send(command) } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 16, height: size + 16)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
