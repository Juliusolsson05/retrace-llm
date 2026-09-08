import Foundation

enum B2ClientError: Error, Sendable, Equatable {
    case disabled, missingCredentials, expiredToken, badAuthToken, badRequest, retryable
    case invalidResponse, invalidRequest, paginationLimit, transportFailed, fileNotPresent
    case httpStatus(Int)
}

struct B2Credentials: Sendable {
    let keyID: String
    let applicationKey: String

    static func fromEnvironment() -> B2Credentials? {
        // Resolve only at the runtime sync gate/authorize, never at initialization or dry-run.
        guard let id = getenv("B2_KEY_ID"), let key = getenv("B2_APPLICATION_KEY") else { return nil }
        return B2Credentials(keyID: String(cString: id), applicationKey: String(cString: key))
    }
}

protocol B2Transport: Sendable {
    /// A file URL is handed to URLSession's file upload API; never materialize a chunk as Data.
    func send(_ request: URLRequest, file: URL?) async throws -> (Data, HTTPURLResponse)
}

private final class B2RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Account and upload tokens must not follow redirects to another endpoint.
        completionHandler(nil)
    }
}

struct B2URLSessionTransport: B2Transport {
    var enabled = false

    func send(_ request: URLRequest, file: URL?) async throws -> (Data, HTTPURLResponse) {
        guard enabled else { throw B2ClientError.disabled }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: B2RedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let result: (Data, URLResponse)
        if let file { result = try await session.upload(for: request, fromFile: file) }
        else { result = try await session.data(for: request) }
        guard let response = result.1 as? HTTPURLResponse else { throw B2ClientError.invalidResponse }
        return (result.0, response)
    }
}

/// B1 chooses minimal B2 Native REST over an S3 SDK: URLSession already supports the
/// five needed endpoints and file-backed request bodies; no dependency or app bootstrap.
/// SyncEngine owns upload policy and resume; the client remains disabled by default.
struct B2Client: Sendable {
    struct Authorization: Decodable, Sendable {
        struct APIInfo: Decodable, Sendable {
            struct StorageAPI: Decodable, Sendable {
                let apiUrl: URL
                let downloadUrl: URL
                let recommendedPartSize: Int64
                let absoluteMinimumPartSize: Int64
                let capabilities: [String]
                let bucketId: String?
                let bucketName: String?
                let namePrefix: String?
            }
            let storageApi: StorageAPI
        }
        let accountId: String
        let authorizationToken: String
        let apiInfo: APIInfo
        let applicationKeyExpirationTimestamp: Int64?
    }

    struct UploadURL: Decodable, Sendable {
        let bucketId: String
        let uploadUrl: URL
        let authorizationToken: String
    }

    struct FileVersion: Decodable, Sendable {
        let fileId: String
        let fileName: String
        let action: String
        let contentLength: Int64
        let contentSha1: String
        let uploadTimestamp: Int64
        let fileInfo: [String: String]?
    }

    struct DeletedVersion: Decodable, Sendable {
        let fileId: String
        let fileName: String
    }

    private struct VersionPage: Decodable {
        let files: [FileVersion]
        let nextFileName: String?
        let nextFileId: String?
    }

    private struct Failure: Decodable { let code: String }

    private let enabled: Bool
    private let transport: any B2Transport
    private let credentials: @Sendable () -> B2Credentials?
    private let authorizationURL: URL

    init(enabled: Bool = false, transport: (any B2Transport)? = nil,
         credentials: @escaping @Sendable () -> B2Credentials? = { B2Credentials.fromEnvironment() },
         authorizationURL: URL = URL(string: "https://api.backblazeb2.com/b2api/v4/b2_authorize_account")!) {
        self.enabled = enabled
        self.transport = transport ?? B2URLSessionTransport(enabled: enabled)
        self.credentials = credentials
        self.authorizationURL = authorizationURL
    }

    func hasCredentials() -> Bool {
        guard let value = credentials() else { return false }
        return !value.keyID.isEmpty && !value.applicationKey.isEmpty
    }

    func authorize() async throws -> Authorization {
        try requireEnabled()
        guard let credentials = credentials(), !credentials.keyID.isEmpty, !credentials.applicationKey.isEmpty else {
            throw B2ClientError.missingCredentials
        }
        try validateURL(authorizationURL)
        var request = URLRequest(url: authorizationURL)
        request.httpMethod = "GET"
        let basic = Data("\(credentials.keyID):\(credentials.applicationKey)".utf8).base64EncodedString()
        request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    func getUploadURL(authorization: Authorization, bucketID: String) async throws -> UploadURL {
        try requireEnabled()
        guard !bucketID.isEmpty else { throw B2ClientError.invalidRequest }
        return try await send(apiRequest(authorization, endpoint: "b2_get_upload_url", body: ["bucketId": bucketID]))
    }

    func uploadFile(upload: UploadURL, fileName: String, file: URL, sizeBytes: Int64, sha1: String) async throws -> FileVersion {
        try requireEnabled()
        guard file.isFileURL, sizeBytes >= 0, !fileName.isEmpty, !fileName.contains("\0"),
              sha1.utf8.count == 40, sha1.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw B2ClientError.invalidRequest
        }
        try validateURL(upload.uploadUrl)
        var request = URLRequest(url: upload.uploadUrl)
        request.httpMethod = "POST"
        request.setValue(upload.authorizationToken, forHTTPHeaderField: "Authorization")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard let encoded = fileName.addingPercentEncoding(withAllowedCharacters: allowed) else { throw B2ClientError.invalidRequest }
        request.setValue(encoded, forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")
        request.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        request.setValue("b2/x-auto", forHTTPHeaderField: "Content-Type")
        return try await send(request, file: file)
    }

    func listFileVersions(authorization: Authorization, bucketID: String, key: String? = nil, maxPages: Int = 1000) async throws -> [FileVersion] {
        try requireEnabled()
        guard !bucketID.isEmpty, maxPages > 0 else { throw B2ClientError.invalidRequest }
        var body: [String: Any] = ["bucketId": bucketID, "maxFileCount": 1000]
        if let key { body["prefix"] = key }
        var files: [FileVersion] = []
        var cursors: Set<[String]> = []
        for _ in 0..<maxPages {
            let page: VersionPage = try await send(apiRequest(authorization, endpoint: "b2_list_file_versions", body: body))
            files.append(contentsOf: page.files.filter { key == nil || $0.fileName == key })
            if page.nextFileName == nil, page.nextFileId == nil { return files }
            guard let name = page.nextFileName, let id = page.nextFileId,
                  cursors.insert([name, id]).inserted else { throw B2ClientError.invalidResponse }
            body["startFileName"] = name
            body["startFileId"] = id
        }
        throw B2ClientError.paginationLimit
    }

    func deleteFileVersion(authorization: Authorization, fileID: String, fileName: String) async throws -> DeletedVersion {
        try requireEnabled()
        guard !fileID.isEmpty, !fileName.isEmpty else { throw B2ClientError.invalidRequest }
        return try await send(apiRequest(authorization, endpoint: "b2_delete_file_version", body: ["fileId": fileID, "fileName": fileName]))
    }

    private func apiRequest(_ authorization: Authorization, endpoint: String, body: [String: Any]) throws -> URLRequest {
        let url = authorization.apiInfo.storageApi.apiUrl.appendingPathComponent("b2api/v4/" + endpoint)
        try validateURL(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization.authorizationToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, file: URL? = nil) async throws -> T {
        try requireEnabled()
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request, file: file) }
        catch is CancellationError { throw CancellationError() }
        catch let error as B2ClientError { throw error }
        catch { throw B2ClientError.transportFailed }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.code
            switch (response.statusCode, code) {
            case (401, "expired_token"): throw B2ClientError.expiredToken
            case (401, "bad_auth_token"): throw B2ClientError.badAuthToken
            case (400, "bad_request"): throw B2ClientError.badRequest
            case (400, "file_not_present"), (404, "file_not_present"): throw B2ClientError.fileNotPresent
            case (503, _): throw B2ClientError.retryable
            default: throw B2ClientError.httpStatus(response.statusCode)
            }
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw B2ClientError.invalidResponse }
    }

    private func requireEnabled() throws { if !enabled { throw B2ClientError.disabled } }

    private func validateURL(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil else { throw B2ClientError.invalidResponse }
    }
}
