import Foundation
import DropyCore

final class PreferenceStore {
    private let key = "org.dropy.preferences.v1"
    private let defaults: UserDefaults
    private(set) var value: DropyPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(DropyPreferences.self, from: data) {
            value = saved
        } else {
            value = DropyPreferences()
        }
    }

    func update(_ edit: (inout DropyPreferences) -> Void) {
        edit(&value)
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
