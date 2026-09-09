import Foundation
import RetraceKit

/// Injectable HTTP transport so tests replay recorded responses without network.
public protocol LLMTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: LLMTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIError("llm_unavailable", "The model endpoint returned a non-HTTP response.", exitCode: 3)
        }
        return (data, http)
    }
}

public struct Attribution: Sendable, Equatable {
    public let project: String
    public let activity: String
    public let confidence: Double?

    public init(project: String, activity: String, confidence: Double?) {
        self.project = project
        self.activity = activity
        self.confidence = confidence
    }
}

/// Minimal Gemini generateContent client: one prompt, optional inline JPEG parts,
/// JSON-mode structured output, bounded retry on rate limiting. The API key comes
/// from the caller (BYO, env at the CLI boundary) and is never persisted here.
public final class GeminiClient: Sendable {
    public static let defaultModel = "gemini-3.5-flash-lite"

    private let apiKey: String
    private let model: String
    private let transport: LLMTransport

    public init(apiKey: String, model: String = GeminiClient.defaultModel, transport: LLMTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func classify(block: ClosedBlock, ocrDigest: String, images: [Data]) async throws -> Attribution {
        let prompt = Self.prompt(block: block, ocrDigest: ocrDigest, hasImages: !images.isEmpty)
        let request = try Self.request(endpoint: endpoint, apiKey: apiKey, prompt: prompt, images: images)
        var lastError: CLIError?
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))), clock: .continuous)
            }
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200:
                return try Self.parse(data)
            case 429, 500, 503:
                lastError = CLIError("llm_rate_limited", "The model endpoint is busy; classification will be retried.", exitCode: 3)
            case 401, 403:
                throw CLIError("llm_key_invalid", "The model API key was rejected.", exitCode: 3)
            default:
                throw CLIError("llm_unavailable", "The model endpoint returned status \(response.statusCode).", exitCode: 3)
            }
        }
        throw lastError ?? CLIError("llm_unavailable", "The model endpoint did not respond.", exitCode: 3)
    }

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    static func prompt(block: ClosedBlock, ocrDigest: String, hasImages: Bool) -> String {
        """
        You classify what project a person was working on from recorded computer activity.

        Activity record:
        - App: \(block.appBundleId ?? "unknown")
        - Window: \(block.windowName ?? "unknown")
        - URL: \(block.browserUrl ?? "none")
        - On-screen text observed during this period (OCR, truncated):
        \(ocrDigest.isEmpty ? "(none)" : String(ocrDigest.prefix(6000)))
        \(hasImages ? "- Screenshot(s) of the period are attached as images." : "")

        Known projects will be listed by the caller when available; otherwise infer from
        the evidence (repository names, domains, document titles).
        Respond ONLY with JSON: {"project": string, "activity": string, "confidence": number}
        where project is a short stable kebab-case identifier, activity is a concise
        phrase, and confidence is 0.0-1.0.
        """
    }

    static func request(endpoint: URL, apiKey: String, prompt: String, images: [Data]) throws -> URLRequest {
        struct InlineData: Codable { var mime_type = "image/jpeg"; var data: String }
        struct Part: Codable { var text: String?; var inline_data: InlineData? }
        struct Content: Codable { var parts: [Part] }
        struct GenerationConfig: Codable { var response_mime_type = "application/json"; var temperature = 0.0 }
        struct Body: Codable { var contents: [Content]; var generationConfig: GenerationConfig }

        var parts: [Part] = [Part(text: prompt, inline_data: nil)]
        parts.append(contentsOf: images.map { Part(text: nil, inline_data: InlineData(data: $0.base64EncodedString())) })

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(Body(contents: [Content(parts: parts)],
                                                         generationConfig: GenerationConfig()))
        return request
    }

    struct ModelText: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable { struct Part: Decodable { let text: String? }; let parts: [Part]? }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    static func parse(_ data: Data) throws -> Attribution {
        let decoded = try JSONDecoder().decode(ModelText.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).first,
              let json = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let project = object["project"] as? String, !project.isEmpty else {
            throw CLIError("llm_response_invalid", "The model response could not be parsed as a classification.", exitCode: 3)
        }
        return Attribution(project: project,
                           activity: object["activity"] as? String ?? "",
                           confidence: object["confidence"] as? Double)
    }
}
