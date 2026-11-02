import Foundation

/// Langue de l'image de partage d'un test d'expérience : celle de l'app, français ou anglais.
///
/// Les phrases sont un contrat commun figé à l'octet (`presentation-v1`) : elles vivent dans
/// une table plutôt que dans le catalogue, pour que le vecteur des deux langues se rejoue
/// quel que soit le simulateur. Le vouvoiement rend le français.
enum ExperienceShareLanguage: String, CaseIterable, Sendable {
    case fr, en

    static var current: Self { Bundle.main.preferredLocalizations.first == "en" ? .en : .fr }

    var locale: Locale { Locale(identifier: self == .fr ? "fr_FR" : "en_US") }

    func text(_ fr: String, _ en: String) -> String { self == .fr ? fr : en }
}

/// Libellés des usages sur l'image de partage. Les phrases viennent de `presentation-v1`
/// (`ExperiencePresentation`), qui a remplacé `experience-share-phrases-v1` le 02/11.
enum ExperienceSharePhrases {
    enum Use: String, CaseIterable, Sendable {
        case video, webPage, gameAndCalls, upload

        func label(_ language: ExperienceShareLanguage) -> String {
            switch self {
            case .video: language.text("Vidéo", "Video")
            case .webPage: "Web"
            case .gameAndCalls: language.text("Jeu et appels", "Gaming & calls")
            case .upload: language.text("Envoi", "Upload")
            }
        }
    }

    // MARK: Nombres

    /// Milliers séparés par U+202F en français, par une virgule en anglais.
    static func integer(_ value: Int, _ language: ExperienceShareLanguage) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: language.text("\u{202F}", ","))
    }
}
