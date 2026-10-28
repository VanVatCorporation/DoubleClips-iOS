import SwiftUI

/// The app's language (Settings > General > Language), next to the Theme setting.
///
/// - The choice is stored under `app_language`: "system" (follow the phone) or a language code from `supported`.
/// - SwiftUI text (`Text("Settings")`, buttons, alerts, navigation titles...) is looked up in `Localizable.strings` of
///   that language through the `\.locale` environment that `DoubleClipsApp` sets, so a change shows at once, no restart.
///   The English text itself is the key, so English needs no file and every untranslated string simply stays English.
/// - Strings built in code (error messages, progress texts) go through `L(_:)`, which reads the same table.
/// - To add a language: add a row to `supported` and a `<code>.lproj/Localizable.strings` (copy `vi.lproj` and translate).
struct AppLanguage: Identifiable, Hashable {
    /// BCP-47 code, also the name of the `.lproj` folder.
    let code: String
    /// The language's own name: it is never translated (so someone can always find theirs).
    let nativeName: String
    var id: String { code }
    
    static let storageKey = "app_language"
    static let system = "system"
    
    /// Every language the app can show. English is the language the strings are written in.
    static let supported: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "vi", nativeName: "Tiếng Việt"),
    ]
    
    /// For the picker: alphabetical by the language's own name ("System Default" goes first, in the picker).
    static var sortedForPicker: [AppLanguage] {
        supported.sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
    }
    
    /// The stored choice ("system" or a code) -> the code to display. "system" picks the first of the phone's preferred
    /// languages that the app has, else English.
    static func resolve(_ choice: String) -> String {
        if choice != system, supported.contains(where: { $0.code == choice }) { return choice }
        for preferred in Locale.preferredLanguages {
            let base = Locale(identifier: preferred).language.languageCode?.identifier ?? preferred
            if let match = supported.first(where: { $0.code == base }) { return match.code }
        }
        return "en"
    }
    
    /// The language shown right now (reads the stored choice).
    static var currentCode: String {
        resolve(UserDefaults.standard.string(forKey: storageKey) ?? system)
    }
    
    static func locale(for choice: String) -> Locale { Locale(identifier: resolve(choice)) }
    
    // MARK: Strings built in code
    
    /// The `.lproj` bundle of a language, or nil when the app has no file for it (English: the keys are the text).
    private static func bundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
    
    /// `key` (the English text) in the current language; the key itself when there is no translation.
    static func string(_ key: String) -> String {
        guard let bundle = bundle(for: currentCode) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// A string for code that isn't a SwiftUI `Text` literal (error messages, status lines).
func L(_ key: String) -> String { AppLanguage.string(key) }

/// `L` with arguments: `Lf("%@ of %@ used", a, b)`; the translation may reorder them with `%1$@ %2$@`.
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: AppLanguage.string(key), locale: Locale(identifier: AppLanguage.currentCode), arguments: args)
}
