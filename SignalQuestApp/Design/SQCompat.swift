import SwiftUI
import UserNotifications

/// Shims de rétro-compatibilité iOS 16 : on garde les APIs iOS 17/18/26 derrière
/// `#available` (sans perdre les rendus récents) et on fournit un repli iOS 16.
/// Même idiome que `SQMotion`/`SQGlass`.
extension View {
    /// `onChange(of:)` rétro-compatible : signature `(ancienne, nouvelle)` sur
    /// iOS 17+, repli sur la signature mono-argument iOS 16 (l'ancienne valeur est
    /// suivie via un `@State` interne). Tous les appels de l'app utilisent déjà la
    /// forme à deux paramètres `{ _, new in }`.
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        modifier(OnChangeCompatModifier(value: value, action: action))
    }

    /// `.contentTransition(.numericText())` quand dispo, sinon un fondu discret.
    @ViewBuilder
    func contentTransitionNumericTextCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.numericText())
        } else {
            self.contentTransition(.opacity)
        }
    }

    /// `.symbolEffect(.pulse, options: .repeating)` (iOS 17+), sinon no-op.
    @ViewBuilder
    func symbolEffectPulseCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }

    /// `.symbolEffect(.bounce, value:)` (iOS 17+), sinon no-op.
    @ViewBuilder
    func symbolEffectBounceCompat<V: Equatable>(value: V) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    /// `.tabViewStyle(.sidebarAdaptable)` (iOS 18+, iPad/large) sinon style par défaut.
    @ViewBuilder
    func sqSidebarAdaptableTabStyle() -> some View {
        if #available(iOS 18.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }

    /// Limite la largeur de lecture et centre le contenu sur les classes de taille
    /// « regular » (iPad, Split View large) pour éviter des lignes de texte et des
    /// cartes étirées sur ~1024 pt (« iPhone étiré »). AUCUN effet sur iPhone
    /// (compact) : sûr à appliquer sur les écrans à contenu texte (UI-01/UXP-04/F-04).
    func sqReadableWidth(_ maxWidth: CGFloat = 700) -> some View {
        modifier(SQReadableWidthModifier(maxWidth: maxWidth))
    }

    /// `.presentationBackground(_:)` est iOS 16.4+ ; sur 16.0–16.3, fond de sheet par défaut.
    @ViewBuilder
    func presentationBackgroundCompat<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(style)
        } else {
            self
        }
    }

    /// `.toolbarTitleDisplayMode(.inline)` (iOS 17+) → repli `navigationBarTitleDisplayMode`.
    @ViewBuilder
    func toolbarTitleInlineCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.toolbarTitleDisplayMode(.inline)
        } else {
            self.navigationBarTitleDisplayMode(.inline)
        }
    }

    /// `.toolbarTitleDisplayMode(.large)` (iOS 17+) → repli `navigationBarTitleDisplayMode`.
    @ViewBuilder
    func toolbarTitleLargeCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.toolbarTitleDisplayMode(.large)
        } else {
            self.navigationBarTitleDisplayMode(.large)
        }
    }

    /// `.navigationDestination(item:)` (iOS 17+) → repli iOS 16 via `isPresented`.
    @ViewBuilder
    func navigationDestinationItemCompat<Item: Hashable, Destination: View>(
        _ item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.navigationDestination(item: item) { destination($0) }
        } else {
            self.navigationDestination(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
    }
}

private struct OnChangeCompatModifier<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var previous: V?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: value) { oldValue, newValue in action(oldValue, newValue) }
        } else {
            content.onChange(of: value) { newValue in
                action(previous ?? newValue, newValue)
                previous = newValue
            }
        }
    }
}

extension UNUserNotificationCenter {
    /// `setBadgeCount` (iOS 17+) sinon repli sur `applicationIconBadgeNumber`.
    func setBadgeCountCompat(_ count: Int) {
        if #available(iOS 17.0, *) {
            setBadgeCount(count)
        } else {
            Task { @MainActor in UIApplication.shared.applicationIconBadgeNumber = count }
        }
    }
}

/// Cf. `View.sqReadableWidth(_:)` : cape la largeur de lecture et centre le contenu
/// sur iPad / Split View large, sans effet sur iPhone (compact).
private struct SQReadableWidthModifier: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
