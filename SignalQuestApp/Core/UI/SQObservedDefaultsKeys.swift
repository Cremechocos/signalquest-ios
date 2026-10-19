import Combine
import Foundation
import ObjectiveC
import os

/// Clés UserDefaults observées par `@AppStorage` (TRX-39).
///
/// SwiftUI n'observe une clé à elle seule que si son nom ne contient pas de
/// point ; sinon la vue se recalcule à CHAQUE écriture dans UserDefaults,
/// quelle que soit la clé écrite (mesuré : 5 écritures d'une autre clé,
/// 5 recalculs). Trois de ces clés vivaient à la racine de l'app : toute
/// écriture recalculait l'arbre entier, et deux vues qui écrivaient pendant
/// leur rendu tournaient en boucle. Les clés observées n'ont donc jamais de
/// point ; les anciennes valeurs sont recopiées une fois, au lancement.
enum SQObservedDefaultsKeys {
    /// Ancienne clé, à point, puis la nouvelle.
    static let renamed: [(old: String, new: String)] = [
        ("sq.hasCompletedOnboarding", OnboardingEntryState.completionKey),
        ("sq.fieldMode.enabled", SQFieldMode.storageKey),
        ("sq.browseAsGuest", RootView.guestPreferenceKey),
        ("sq.security.appLockEnabled", AppLockSettings.enabledKey),
        ("sq.security.appLockGraceSeconds", AppLockSettings.lockGraceKey),
        ("sq.security.autoLogoutSeconds", AppLockSettings.autoLogoutKey),
        ("sq.security.e2eeBiometricEnabled", E2EEBiometric.enabledKey),
        ("sq.carplay.coverageAlerts", CarPlayAlertSettings.coverageAlertsKey),
    ]

    /// Recopie chaque ancienne valeur sous sa nouvelle clé, avant toute vue :
    /// une nouvelle clé déjà écrite l'emporte. L'ancienne reste en place pour
    /// une version antérieure de l'app.
    static func migrate(in defaults: UserDefaults = .standard) {
        for (old, new) in renamed where defaults.object(forKey: new) == nil {
            if let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }
        }
    }
}

// MARK: - Tutoiement / vouvoiement (ADDR-1)

/// Le ton de l'app en français, choisi par le membre et porté par son compte.
///
/// POURQUOI UNE LANGUE PRIVÉE. Les 5000 clés du catalogue sont déjà tutoyées ; le
/// vouvoiement vit dans le MÊME `Localizable.xcstrings`, sous la localisation
/// `fr-x-formal`. Xcode en tire `fr-x-formal.lproj` dans l'app, que le système ne
/// choisit jamais pour un utilisateur : seule la surcharge ci-dessous y puise.
///
/// POURQUOI UN `Bundle` SURCHARGÉ. Les ~5000 chaînes sont lues par SwiftUI
/// (`Text`, `Button`, titres), par `NSLocalizedString` et par UIKit : deux entrées
/// de `Bundle.main`, que `SQAddressBundle` redirige d'un seul endroit, sans toucher
/// aux appels. `String(localized:)` n'en passe par aucune et reste au tutoiement. Le drapeau est lu à chaque chaîne, d'où un
/// verrou et non un `UserDefaults`.
///
/// Sans vouvoiement actif, ou si l'app n'est pas en français, ou si une clé n'a
/// pas de variante, la recherche retombe sur l'implémentation d'origine : le
/// tutoiement (ou l'anglais) reste le comportement de base.
enum SQAddress {
    /// Localisation privée du vouvoiement dans le catalogue.
    static let formalLocalization = "fr-x-formal"
    private static let cachePrefix = "fr.signalquest.ios.addressForm."
    /// Garde « une fois par jour » de la question : locale à l'appareil.
    static let lastAskedKey = "fr.signalquest.ios.addressForm.lastAsked"
    static let minimumDelayBetweenQuestions: TimeInterval = 24 * 3600

    private static let formalFlag = OSAllocatedUnfairLock(initialState: false)
    static var isFormal: Bool { formalFlag.withLock { $0 } }
    static func setFormal(_ formal: Bool) { formalFlag.withLock { $0 = formal } }

    /// L'app tourne-t-elle en français ? La question et le réglage n'existent que là.
    /// Lu AVANT la surcharge de `Bundle.main` (qui annonce `fr-x-formal` en tête) ;
    /// la langue de l'app ne change pas tant que le processus vit.
    static let appIsFrench: Bool = Bundle.main.preferredLocalizations.first == "fr"

    /// `fr-x-formal.lproj` de l'app, résolu une fois ; `nil` hors français ou si le
    /// dossier est absent.
    fileprivate static let formalBundle: Bundle? = {
        guard appIsFrench,
              let path = Bundle.main.path(forResource: formalLocalization, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)
    }()

    /// Pose la surcharge sur `Bundle.main` (une fois) et recharge le ton en cache.
    /// À appeler avant toute vue : le premier rendu doit déjà être dans le bon ton.
    static func install() {
        _ = appIsFrench
        _ = installation
        setFormal(cachedForm == .formal)
    }

    private static let installation: Void = {
        object_setClass(Bundle.main, SQAddressBundle.self)
    }()

    // MARK: Cache par compte

    /// Le ton vient du serveur ; ce cache ne sert qu'à démarrer dans le bon ton
    /// hors ligne. Une clé par compte, purgée à sa déconnexion.
    static func cacheKey(ownerScopeId: String) -> String {
        cachePrefix + LocalAccountScope.storageNamespace(for: ownerScopeId)
    }

    /// Ton en cache du compte courant ; tutoiement sans compte ou sans cache.
    static var cachedForm: SQAddressForm {
        #if DEBUG
        if AppEnvironment.hasQAFlag("address-formal") { return .formal }   // recette : sans compte ni serveur
        #endif
        guard LocalAccountScope.currentUserId != nil,
              let raw = UserDefaults.standard.string(forKey: cacheKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId)),
              let form = SQAddressForm(rawValue: raw)
        else { return .informal }
        return form
    }

    static func remember(_ form: SQAddressForm, ownerScopeId: String) {
        UserDefaults.standard.set(form.rawValue, forKey: cacheKey(ownerScopeId: ownerScopeId))
    }

    /// Déconnexion : le cache du compte disparaît et l'app repasse au tutoiement.
    static func purge(ownerScopeId: String) {
        UserDefaults.standard.removeObject(forKey: cacheKey(ownerScopeId: ownerScopeId))
        setFormal(false)
    }

    // MARK: Question à l'ouverture

    /// Règle d'affichage de la question : compte connecté, serveur qui l'expose et
    /// répond « pas encore choisi », app en français, et pas déjà posée depuis 24 h
    /// sur cet appareil. « Plus tard » n'écrit rien côté serveur.
    static func shouldAsk(isAuthenticated: Bool, chosen: Bool?, appIsFrench: Bool,
                          lastAsked: Date?, now: Date = Date()) -> Bool {
        guard isAuthenticated, appIsFrench, chosen == false else { return false }
        guard let lastAsked else { return true }
        let elapsed = now.timeIntervalSince(lastAsked)
        // Une horloge reculée ne doit pas museler la question pour des mois.
        return elapsed >= minimumDelayBetweenQuestions || elapsed < 0
    }

    static var lastAsked: Date? {
        #if DEBUG
        if AppEnvironment.hasQAFlag("address-prompt") { return nil }   // recette : la question se rejoue
        #endif
        let seconds = UserDefaults.standard.double(forKey: lastAskedKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func markAsked(at date: Date = Date()) {
        #if DEBUG
        if AppEnvironment.hasQAFlag("address-prompt") { return }
        #endif
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastAskedKey)
    }

    /// Marqueur de recherche : une clé absente de la variante rend ce texte, jamais
    /// la clé, ce qui la distingue d'une traduction égale à la clé.
    fileprivate static let missingMarker = "\u{1}sq-address-missing\u{1}"
}

/// Miroir observable du ton, injecté à la racine comme `SQUnitsStore`. Le serveur
/// reste la source de vérité : `refresh` relit les préférences du compte, `choose`
/// les écrit. Hors ligne ou avant le chargement, le ton en cache du compte (ou le
/// tutoiement) s'applique, et la question n'est pas posée (`chosen == nil`).
@MainActor
final class SQAddressStore: ObservableObject {
    @Published private(set) var form: SQAddressForm = SQAddress.cachedForm
    /// `false` = compte qui n'a encore rien choisi ; `nil` = inconnu (pas encore
    /// chargé, hors ligne, ou serveur qui n'expose pas le réglage).
    @Published private(set) var chosen: Bool?
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?
    /// Génération de l'arbre principal : `RootView` en fait l'identité de `MainTabView`.
    /// SwiftUI ne relit pas un `Text` déjà affiché quand le `Bundle` change de ton, et
    /// aucune valeur d'environnement ne l'y oblige (essayé : la locale) ; seule une
    /// nouvelle identité reconstruit les textes. Elle ne change donc qu'aux moments où
    /// rien n'est en cours (voir `applyTone`).
    @Published private(set) var treeRevision = 0
    private var renderedForm = SQAddress.cachedForm

    /// Réponse « inconnue » du serveur ; en recette (`--qa-address-prompt`), un
    /// compte qui n'a rien choisi, pour montrer la question et le réglage sans serveur.
    private static var unknownChosen: Bool? {
        #if DEBUG
        if AppEnvironment.hasQAFlag("address-prompt") { return false }
        #endif
        return nil
    }

    init() { chosen = Self.unknownChosen }

    /// Reconstruit l'arbre principal si le ton a changé depuis son dernier rendu.
    /// Appelé après la réponse à la question, au lancement et au retour au premier
    /// plan : jamais au milieu d'un écran (une reconstruction referme les écrans ouverts).
    func applyTone() {
        guard renderedForm != form else { return }
        renderedForm = form
        treeRevision += 1
    }

    /// Applique les préférences d'un compte : ton effectif, ou tutoiement.
    func apply(_ preferences: UserPreferences, ownerScopeId: String) {
        let next = preferences.addressForm ?? .informal
        chosen = preferences.addressFormChosen
        SQAddress.remember(next, ownerScopeId: ownerScopeId)
        SQAddress.setFormal(next == .formal)
        if next != form { form = next }
    }

    /// Relit le ton du compte. Un échec (réseau, route absente) garde le ton courant
    /// et ne pose pas la question.
    func refresh(using service: PrivacyServicing) async {
        guard let session = LocalAccountScope.sessionSnapshot() else { return }
        do {
            let preferences = try await service.scoped(to: session).preferences()
            guard session.isCurrent else { return }
            apply(preferences, ownerScopeId: session.ownerScopeId)
        } catch {}
    }

    /// Enregistre le choix. Vrai quand le serveur l'a accepté ; sinon `saveError`
    /// dit pourquoi et le ton ne change pas.
    @discardableResult
    func choose(_ choice: SQAddressForm, using service: PrivacyServicing) async -> Bool {
        #if DEBUG
        // Recette sans serveur : le choix s'applique sur place.
        if AppEnvironment.hasQAFlag("address-prompt") {
            apply(UserPreferences(addressForm: choice, addressFormChosen: true), ownerScopeId: "qa")
            return true
        }
        #endif
        guard !isSaving, let session = LocalAccountScope.sessionSnapshot() else { return false }
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            var saved = try await service.scoped(to: session).updatePreferences(UserPreferencesPatch(addressForm: choice))
            guard session.isCurrent else { return false }
            // La réponse rend les deux clés ; en cas de doute, c'est le choix qui compte.
            if saved.addressForm == nil { saved.addressForm = choice }
            saved.addressFormChosen = true
            apply(saved, ownerScopeId: session.ownerScopeId)
            Haptics.success()
            return true
        } catch {
            guard !error.isCancellation else { return false }
            saveError = error.userFacingMessage
            Haptics.error()
            return false
        }
    }

    /// Déconnexion ou changement de compte : on repart du ton en cache du compte
    /// courant (le tutoiement sans compte, son cache disque ayant été purgé), et le
    /// serveur n'a encore rien répondu pour lui.
    func restart() {
        let cached = SQAddress.cachedForm
        SQAddress.setFormal(cached == .formal)
        chosen = Self.unknownChosen; saveError = nil
        if form != cached { form = cached }
        applyTone()
    }
}

/// Redirige la lecture des chaînes vers `fr-x-formal.lproj` quand le vouvoiement
/// est actif et que l'app est en français. Aucune propriété stockée : la classe
/// remplace celle de `Bundle.main` en place (`object_setClass`).
///
/// Deux entrées, car Foundation et SwiftUI n'en partagent pas une seule (mesuré au
/// simulateur) : `NSLocalizedString`, UIKit et les alertes passent par
/// `localizedString(forKey:)`, tout `Text`, `Button` et titre SwiftUI par la version
/// attribuée. `String(localized:)` lit le tutoiement.
private final class SQAddressBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if SQAddress.isFormal, let formal = SQAddress.formalBundle {
            let marker = SQAddress.missingMarker
            let text = formal.localizedString(forKey: key, value: marker, table: tableName)
            if text != marker { return text }
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    override func __localizedAttributedString(forKey key: String, value: String?, table tableName: String?) -> NSAttributedString {
        if SQAddress.isFormal, let formal = SQAddress.formalBundle {
            let marker = SQAddress.missingMarker
            let text = formal.__localizedAttributedString(forKey: key, value: marker, table: tableName)
            if text.string != marker { return text }
        }
        return super.__localizedAttributedString(forKey: key, value: value, table: tableName)
    }
}
