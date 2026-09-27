import Foundation
import Combine

@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    static let storageKey = "FolderBeacon.language"

    enum Choice: String, CaseIterable, Identifiable {
        case system, english, simplifiedChinese
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return L10n.string("Follow System")
            case .english: return "English"
            case .simplifiedChinese: return "简体中文"
            }
        }
    }

    @Published var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.storageKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    var localization: String {
        switch choice {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .system:
            return Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier == "zh" ? "zh-Hans" : "en" } ?? "en"
        }
    }

    private init() {
        choice = Choice(rawValue: UserDefaults.standard.string(forKey: Self.storageKey) ?? "") ?? .system
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("FolderBeacon.appLanguageDidChange")
}

enum L10n {
    @MainActor static func string(_ key: String) -> String {
        let language = AppLanguage.shared.localization
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    @MainActor static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: AppLanguage.shared.localization), arguments: arguments)
    }
}
