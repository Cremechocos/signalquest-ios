import Foundation

protocol PhotoServicing: Sendable {
    func listPhotos(filter: String, sortBy: String, limit: Int) async throws -> [Photo]
    func photo(id: String) async throws -> Photo
    func comments(photoId: String) async throws -> [PhotoComment]
    func addComment(photoId: String, content: String) async throws -> PhotoComment?
    func toggleLike(photoId: String, reaction: String) async throws -> PhotoLikeResponse
    func uploadPhoto(data: Data, siteId: String, description: String?, anfrCode: String?, operatorName: String?, exifMetadata: String?) async throws -> Photo
}

final class PhotoService: PhotoServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func listPhotos(filter: String = "approved", sortBy: String = "recent", limit: Int = 20) async throws -> [Photo] {
        let response: PhotoListResponse = try await api.request(
            APIEndpoint(
                path: "/api/photos",
                query: [
                    URLQueryItem(name: "filter", value: filter),
                    URLQueryItem(name: "sortBy", value: sortBy),
                    URLQueryItem(name: "limit", value: "\(limit)")
                ],
                authenticated: false
            ),
            as: PhotoListResponse.self
        )
        return response.photos
    }

    func photo(id: String) async throws -> Photo {
        try await api.request(APIEndpoint(path: "/api/photos/\(id)", authenticated: false), as: Photo.self)
    }

    func comments(photoId: String) async throws -> [PhotoComment] {
        let response: PhotoCommentsResponse = try await api.request(APIEndpoint(path: "/api/photos/\(photoId)/comments", authenticated: false), as: PhotoCommentsResponse.self)
        return response.comments
    }

    func addComment(photoId: String, content: String) async throws -> PhotoComment? {
        struct Response: Codable { let success: Bool?; let comment: PhotoComment? }
        let response: Response = try await api.requestJSON("/api/photos/\(photoId)/comments", body: ["content": content])
        return response.comment
    }

    func toggleLike(photoId: String, reaction: String = "❤️") async throws -> PhotoLikeResponse {
        try await api.requestJSON("/api/photos/\(photoId)/like", body: ["reaction": reaction])
    }

    func uploadPhoto(data: Data, siteId: String, description: String?, anfrCode: String?, operatorName: String?, exifMetadata: String?) async throws -> Photo {
        var fields = ["siteId": siteId]
        if let description, !description.isEmpty { fields["description"] = description }
        if let anfrCode, !anfrCode.isEmpty { fields["anfrCode"] = anfrCode }
        if let operatorName, !operatorName.isEmpty { fields["operator"] = operatorName }
        // Métadonnées EXIF extraites côté client (GPS, date, appareil) — fusionnées par
        // le backend (mergeClientPhotoExifMetadata), parité Android.
        if let exifMetadata, !exifMetadata.isEmpty { fields["exifMetadata"] = exifMetadata }
        return try await api.uploadMultipart(
            path: "/api/photos",
            fields: fields,
            fileField: "file",
            fileName: "signalquest-ios-\(UUID().uuidString).jpg",
            mimeType: "image/jpeg",
            data: data,
            as: Photo.self
        )
    }
}

