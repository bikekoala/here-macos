import Foundation

@Observable
@MainActor
final class SettingsStore {
    var showMode: ShowMode {
        didSet { UserDefaults.standard.set(showMode.rawValue, forKey: Keys.showMode) }
    }

    var countryStyle: CountryStyle {
        didSet { UserDefaults.standard.set(countryStyle.rawValue, forKey: Keys.countryStyle) }
    }

    var refreshIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(refreshIntervalSeconds, forKey: Keys.intervalSeconds) }
    }

    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    var widgetBordered: Bool {
        didSet { UserDefaults.standard.set(widgetBordered, forKey: Keys.widgetBordered) }
    }

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalSeconds) ?? .m5 }
        set { refreshIntervalSeconds = newValue.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.showMode = (defaults.string(forKey: Keys.showMode).flatMap(ShowMode.init(rawValue:))) ?? .both
        self.countryStyle = (defaults.string(forKey: Keys.countryStyle).flatMap(CountryStyle.init(rawValue:))) ?? .flag
        let stored = defaults.integer(forKey: Keys.intervalSeconds)
        self.refreshIntervalSeconds = stored > 0 ? stored : RefreshInterval.m5.rawValue
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.widgetBordered = defaults.object(forKey: Keys.widgetBordered) as? Bool ?? true
    }

    private enum Keys {
        static let showMode = "displayStyle.show"
        static let countryStyle = "displayStyle.country"
        static let intervalSeconds = "refresh.intervalSeconds"
        static let launchAtLogin = "launchAtLogin"
        static let widgetBordered = "widget.bordered"
    }
}
