import ConcertSongFinderCore
import Foundation

final class BackendLyricsService: LyricsService {
    private let client: BackendAPIClient

    init(client: BackendAPIClient) {
        self.client = client
    }

    func lyrics(for songs: [SongIdentity]) async throws -> [SongLyrics] {
        let request = LyricsBatchRequest(
            songs: songs.map {
                LyricsSongRequest(id: $0.id, title: $0.title, artist: $0.artist, isrc: $0.isrc)
            }
        )
        return try await client.post("api/lyrics/batch", body: request, responseType: [SongLyrics].self)
    }
}
