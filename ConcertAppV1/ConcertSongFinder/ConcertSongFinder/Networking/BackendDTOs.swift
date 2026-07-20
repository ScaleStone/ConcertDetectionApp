import Foundation

struct ConcertSearchRequest: Encodable {
    let artist: String?
    let date: String?
    let venue: String?
    let latitude: Double?
    let longitude: Double?
    let cityName: String?
    let stateCode: String?
    let countryCode: String?
}

struct BackendHealthResponse: Decodable {
    let status: String
}

struct LyricsBatchRequest: Encodable {
    let songs: [LyricsSongRequest]
}

struct LyricsSongRequest: Encodable {
    let id: String
    let title: String
    let artist: String
    let isrc: String?
}
