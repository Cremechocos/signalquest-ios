import SwiftUI

/// Aperçu d'un lien (plan 3, vague 2), tel que le serveur le lit :
/// `GET /api/social/og`, la route des cartes du fil.
struct LinkPreview: Decodable, Equatable, Sendable {
    let url: String
    let finalUrl: String?
    let title: String?
    let description: String?
    let siteName: String?

    static let demo = LinkPreview(
        url: "https://signalquest.fr/carte", finalUrl: "https://signalquest.fr/carte",
        title: "Carte de couverture SignalQuest", description: nil, siteName: "SignalQuest"
    )
}

/// Aperçus déjà lus, en mémoire seulement : une URL n'est demandée qu'une
/// fois par lancement, même si elle revient dans plusieurs messages.
actor LinkPreviewStore {
    static let shared = LinkPreviewStore()

    private var cache: [URL: LinkPreview?] = [:]
    private var inFlight: [URL: Task<LinkPreview??, Never>] = [:]

    /// `nil` sans aperçu. Un échec réseau n'est pas retenu : la prochaine
    /// ouverture réessaie.
    func preview(for url: URL, api: APIClient) async -> LinkPreview? {
        if let cached = cache[url] { return cached }
        let task = inFlight[url] ?? Task { await Self.fetch(url, api: api) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        guard let result else { return nil }
        if cache.count >= 200 { cache.removeAll() }
        cache[url] = result
        return result
    }

    private static func fetch(_ url: URL, api: APIClient) async -> LinkPreview?? {
        if AppEnvironment.usesDemoData {
            return .some(url.host?.hasSuffix("signalquest.fr") == true ? .demo : nil)
        }
        struct Response: Decodable { let preview: LinkPreview? }
        do {
            let response = try await api.request(
                APIEndpoint(path: "/api/social/og", query: [URLQueryItem(name: "url", value: url.absoluteString)]),
                as: Response.self
            )
            return .some(response.preview)
        } catch {
            return nil
        }
    }
}

/// Carte sous le texte d'un message qui contient un lien, dans une
/// conversation non chiffrée seulement : le serveur y lit déjà le texte, et
/// c'est lui qui va chercher la page. L'appareil ne contacte jamais le site
/// du lien, d'où l'absence d'image, qui viendrait de lui. La carte n'existe
/// que pour un lien du texte, et c'est lui qu'elle ouvre.
struct MessageLinkPreview: View {
    let text: String
    let mine: Bool

    @EnvironmentObject private var services: AppServices
    @State private var link: URL?
    @State private var preview: LinkPreview?

    var body: some View {
        Group {
            if let link, let preview, let title = preview.title, !title.isEmpty {
                Link(destination: link) { card(title: title, source: Self.domain(of: preview, link: link)) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ouvre le lien")
                    .accessibilityIdentifier("message.linkPreview")
            } else {
                // Une vue réelle, sans taille : `.task` ne part pas sur une vue vide.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: text) {
            guard let url = Self.firstLink(in: text) else { return }
            let loaded = await LinkPreviewStore.shared.preview(for: url, api: services.api)
            link = url
            preview = loaded
        }
    }

    private func card(title: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(SQFont.body(13.5, .semibold))
                .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !source.isEmpty {
                Text(verbatim: source)
                    .font(SQFont.body(12))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(mine ? SQColor.onAccent.opacity(0.14) : SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        // En OLED, fond atténué et bulle sont noirs : le liseré des cartes la détache.
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQOledPalette.cardStroke, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Le domaine où mène vraiment le lien, redirections suivies par le
    /// serveur, et jamais le nom de site que la page déclare : une page
    /// piégée peut se dire « Ta banque ».
    nonisolated static func domain(of preview: LinkPreview, link: URL) -> String {
        let host = preview.finalUrl.flatMap(URL.init(string:))?.host ?? link.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Premier lien web du texte.
    nonisolated static func firstLink(in text: String) -> URL? {
        guard text.contains("http"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" || $0.scheme == "http" }
    }
}
