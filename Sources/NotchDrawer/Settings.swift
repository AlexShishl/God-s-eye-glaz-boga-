import AppKit
import ServiceManagement
import SwiftUI

enum Theme: String, CaseIterable, Identifiable {
    case dark, light, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Тёмная"
        case .light: "Светлая"
        case .glass: "Стекло"
        }
    }
}

/// Фон шторки. «Стекло» на macOS 26 — настоящее жидкое стекло, на старых — матовое размытие.
struct ThemeBackground: View {
    let theme: Theme

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 24,
                               bottomTrailingRadius: 24, topTrailingRadius: 0, style: .continuous)
    }

    var body: some View {
        switch theme {
        case .dark:
            shape.fill(Color.black)
        case .light:
            shape.fill(Color(white: 0.97))
        case .glass:
            glass
        }
    }

    @ViewBuilder private var glass: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            blur
        }
        #else
        blur
        #endif
    }

    private var blur: some View {
        VisualEffectBlur().clipShape(shape)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Что показывать в шторке: разделы и лимиты каких нейросетей.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published private var hiddenModules: Set<String> {
        didSet { defaults.set(Array(hiddenModules), forKey: "hiddenModules") }
    }
    @Published private var enabledLimits: Set<String> {
        didSet { defaults.set(Array(enabledLimits), forKey: "enabledLimits") }
    }

    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }

    /// Масштаб шторки: 0.85 — компактнее, 1.5 — крупнее.
    @Published var scale: Double {
        didSet { defaults.set(scale, forKey: "scale") }
    }

    init() {
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        let savedScale = defaults.double(forKey: "scale")
        scale = savedScale == 0 ? 1 : min(max(savedScale, 0.85), 1.5)
        hiddenModules = Set(defaults.stringArray(forKey: "hiddenModules") ?? [])
        enabledLimits = Set(defaults.stringArray(forKey: "enabledLimits") ?? ["claude"])
    }

    func isOn(_ tab: DrawerTab) -> Bool { !hiddenModules.contains(tab.rawValue) }

    func set(_ tab: DrawerTab, on: Bool) {
        if on { hiddenModules.remove(tab.rawValue) } else { hiddenModules.insert(tab.rawValue) }
    }

    func isOn(limits id: String) -> Bool { enabledLimits.contains(id) }

    func set(limits id: String, on: Bool) {
        if on { enabledLimits.insert(id) } else { enabledLimits.remove(id) }
    }

    var visibleTabs: [DrawerTab] { DrawerTab.modules.filter { isOn($0) } }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Тема").font(.system(size: 14, weight: .bold))
                Picker("", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                HStack(spacing: 6) {
                    Text("Размер").font(.caption)
                    Slider(value: $settings.scale, in: 0.85...1.5, step: 0.05)
                        .controlSize(.mini)
                    Text("\(Int((settings.scale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    if settings.scale != 1 {
                        Button { settings.scale = 1 } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help("Вернуть 100%")
                    }
                }
                Text("Разделы шторки").font(.system(size: 14, weight: .bold))
                Text("Выключи то, что тебе не нужно").font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(DrawerTab.modules) { tab in
                            Toggle(isOn: Binding(get: { settings.isOn(tab) },
                                                 set: { settings.set(tab, on: $0) })) {
                                Label(tab.title, systemImage: tab.icon).font(.caption)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }
            }
            .card()
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("Лимиты нейросетей").font(.system(size: 14, weight: .bold))
                Text("Строки внизу шторки").font(.caption2).foregroundStyle(.secondary)
                ForEach(UsageProviders.all) { p in
                    Toggle(isOn: Binding(get: { settings.isOn(limits: p.id) },
                                         set: { on in
                                             settings.set(limits: p.id, on: on)
                                             if on { p.source.refresh() }
                                         })) {
                        VStack(alignment: .leading, spacing: 0) {
                            Label(p.source.name, systemImage: p.source.icon).font(.caption)
                            Text(p.hint).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Spacer(minLength: 0)
                Divider()
                Toggle(isOn: $launchAtLogin) { Text("Запускать при входе").font(.caption) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Button("Обновить приложение") { Updater.run() }.buttonStyle(PillButton())
                    Spacer()
                    Text("Глаз Бога \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .card()
            .frame(maxWidth: .infinity)
        }
    }
}
