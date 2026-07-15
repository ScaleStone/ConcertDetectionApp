import ConcertSongFinderCore
import Foundation

final class BackendSetlistService: SetlistService {
    private let client: BackendAPIClient
    private let dateFormatter: DateFormatter

    init(client: BackendAPIClient) {
        self.client = client
        self.dateFormatter = DateFormatter()
        self.dateFormatter.calendar = Calendar(identifier: .gregorian)
        self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter.dateFormat = "yyyy-MM-dd"
    }

    func searchConcerts(
        artist: String?,
        date: Date?,
        venue: String?,
        location: VideoLocation?,
        cityName: String?,
        stateCode: String?,
        countryCode: String?
    ) async throws -> [ConcertCandidate] {
        let request = ConcertSearchRequest(
            artist: artist,
            date: date.map { dateFormatter.string(from: $0) },
            venue: venue,
            latitude: location?.latitude,
            longitude: location?.longitude,
            cityName: cityName,
            stateCode: stateCode,
            countryCode: countryCode
        )
        let latitudeDescription = request.latitude.map { String($0) } ?? "nil"
        let longitudeDescription = request.longitude.map { String($0) } ?? "nil"
        AppLog.network.info("Setlist search request artist=\(artist ?? "nil", privacy: .public) date=\(request.date ?? "nil", privacy: .public) lat=\(latitudeDescription, privacy: .public) lon=\(longitudeDescription, privacy: .public) city=\(cityName ?? "nil", privacy: .public) state=\(stateCode ?? "nil", privacy: .public) country=\(countryCode ?? "nil", privacy: .public)")
        AppLog.network.info("Checking backend health before setlist search.")
        try await client.checkHealth()
        AppLog.network.info("Backend health check succeeded; continuing setlist search.")
        return try await client.post("api/concerts/search", body: request, responseType: [ConcertCandidate].self, timeout: 20)
    }

    func fetchSetlist(id: String) async throws -> ConcertSetlist {
        AppLog.network.info("Fetching setlist id=\(id, privacy: .public)")
        return try await client.get("api/setlists/\(id)", responseType: ConcertSetlist.self, timeout: 20)
    }
}
