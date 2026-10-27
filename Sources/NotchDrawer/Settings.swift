import ServiceManagement
import SwiftUI

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

    init() {
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
