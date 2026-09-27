import SwiftUI

/// Banc visuel compilé seulement sur simulateur Debug. Les URL pointent vers
/// le serveur synthétique loopback ; aucune photo ni session réelle.
struct RemoteImageQAScreen: View {
    @State private var imageVersion = 1
    @State private var cellGeneration = 0
    private let usesSyntheticTimeout: Bool

    #if DEBUG && targetEnvironment(simulator)
    private static let timeoutPipeline = ImagePipeline { url, _, reload in
        if !reload { throw URLError(.timedOut) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImagePipelineError.httpStatus(http.statusCode)
        }
        return data
    }
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        _imageVersion = State(initialValue: Int(ProcessInfo.processInfo.environment["SQ_QA_IMAGE_VERSION"] ?? "1") ?? 1)
        usesSyntheticTimeout = ProcessInfo.processInfo.environment["SQ_QA_IMAGE_TIMEOUT_ONCE"] == "1"
        #else
        usesSyntheticTimeout = false
        #endif
    }

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            VStack(spacing: SQSpace.xl) {
                RemoteImage(
                    url: URL(string: "http://127.0.0.1:49243/image?version=\(imageVersion)"),
                    maxDimension: 320,
                    contentMode: .fill,
                    pipeline: usesSyntheticTimeout ? Self.timeoutPipeline : .shared,
                    showsFailureUI: true
                ) {
                    Rectangle().fill(SQColor.fill)
                        .accessibilityIdentifier("remoteImage.loading")
                }
                .id(cellGeneration)
                .frame(width: 320, height: 320)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))

                Button("Recréer la cellule") { cellGeneration += 1 }
                    .accessibilityIdentifier("remoteImage.qa.recreate")
                    .frame(minHeight: 44)
                Button("Autre image") { imageVersion += 1 }
                    .accessibilityIdentifier("remoteImage.qa.next")
                    .frame(minHeight: 44)
            }
            .padding(SQSpace.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .signalQuestBackground()
            .navigationTitle("Photos QA")
        }
        #else
        EmptyView()
        #endif
    }
}
