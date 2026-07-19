import ConcertSongFinderCore
import Foundation

final class BackendAPIClient {
    let baseURL: URL?
    private let apiKey: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL?, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeBackendDate(from: decoder)
        }
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        responseType: Response.Type,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var request = try makeRequest(path: path, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request, responseType: responseType)
    }

    func get<Response: Decodable>(_ path: String, responseType: Response.Type, timeout: TimeInterval = 15) async throws -> Response {
        var request = try makeRequest(path: path, timeout: timeout)
        request.httpMethod = "GET"
        return try await send(request, responseType: responseType)
    }

    private func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest {
        guard let baseURL else {
            AppLog.network.error("Backend request rejected because no backend URL is configured path=\(path, privacy: .public)")
            throw ConcertSongFinderError.unknown(
                "The backend is not configured. Set CSFBackendBaseURL in Info.plist to your Mac's address (for example http://192.168.1.20:8000)."
            )
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        return request
    }

    func checkHealth() async throws {
        _ = try await get("health", responseType: BackendHealthResponse.self, timeout: 3)
    }

    private func send<Response: Decodable>(_ request: URLRequest, responseType: Response.Type) async throws -> Response {
        let requestURL = request.url?.absoluteString ?? "unknown"
        AppLog.network.info("Backend request starting method=\(request.httpMethod ?? "GET", privacy: .public) url=\(requestURL, privacy: .public) timeout=\(request.timeoutInterval, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                AppLog.network.error("Backend request failed without HTTP response url=\(requestURL, privacy: .public)")
                throw ConcertSongFinderError.backendUnavailable
            }
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            AppLog.network.info("Backend response url=\(requestURL, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            switch http.statusCode {
            case 200..<300:
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch {
                    AppLog.network.error("Backend decode failed url=\(requestURL, privacy: .public) error=\(error.localizedDescription, privacy: .public) body=\(responseBody.prefix(500), privacy: .public)")
                    throw ConcertSongFinderError.unknown("The backend response could not be decoded. Check the network logs for the response body.")
                }
            case 404:
                AppLog.network.error("Backend returned 404 url=\(requestURL, privacy: .public) body=\(responseBody.prefix(500), privacy: .public)")
                throw ConcertSongFinderError.noSetlistFound
            case 429:
                AppLog.network.error("Backend returned 429 url=\(requestURL, privacy: .public) body=\(responseBody.prefix(500), privacy: .public)")
                throw ConcertSongFinderError.rateLimited
            case 503:
                AppLog.network.error("Backend returned 503 url=\(requestURL, privacy: .public) body=\(responseBody.prefix(500), privacy: .public)")
                throw ConcertSongFinderError.backendUnavailable
            default:
                AppLog.network.error("Backend returned unexpected status url=\(requestURL, privacy: .public) status=\(http.statusCode, privacy: .public) body=\(responseBody.prefix(500), privacy: .public)")
                throw ConcertSongFinderError.unknown("Backend request failed with HTTP \(http.statusCode). Check backend logs for details.")
            }
        } catch let error as ConcertSongFinderError {
            throw error
        } catch let error as URLError {
            AppLog.network.error("Backend URL error url=\(requestURL, privacy: .public) code=\(error.code.rawValue, privacy: .public) description=\(error.localizedDescription, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) isCancellation=\((error.code == .cancelled), privacy: .public)")
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw ConcertSongFinderError.unknown("Backend is not reachable at \(requestURL): \(error.localizedDescription)")
        } catch {
            AppLog.network.error("Backend request failed url=\(requestURL, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw ConcertSongFinderError.unknown("Backend request failed: \(error.localizedDescription)")
        }
    }

    private static func decodeBackendDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        let internetDateTime = ISO8601DateFormatter()
        internetDateTime.formatOptions = [.withInternetDateTime]

        let internetDateTimeWithFractionalSeconds = ISO8601DateFormatter()
        internetDateTimeWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let backendDateTimeWithoutTimeZone = DateFormatter()
        backendDateTimeWithoutTimeZone.calendar = Calendar(identifier: .gregorian)
        backendDateTimeWithoutTimeZone.locale = Locale(identifier: "en_US_POSIX")
        backendDateTimeWithoutTimeZone.timeZone = TimeZone(secondsFromGMT: 0)
        backendDateTimeWithoutTimeZone.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let backendDateOnly = DateFormatter()
        backendDateOnly.calendar = Calendar(identifier: .gregorian)
        backendDateOnly.locale = Locale(identifier: "en_US_POSIX")
        backendDateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        backendDateOnly.dateFormat = "yyyy-MM-dd"

        if let date = internetDateTime.date(from: value)
            ?? internetDateTimeWithFractionalSeconds.date(from: value)
            ?? backendDateTimeWithoutTimeZone.date(from: value)
            ?? backendDateOnly.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported backend date format: \(value)"
        )
    }
}
