import ConcertSongFinderCore
import Foundation

struct DetectedConcertPlace {
    let cityName: String?
    let stateCode: String?
    let countryCode: String?

    var displayName: String {
        [cityName, stateCode, countryCode]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

@MainActor
final class ConcertSetupViewModel: ObservableObject {
    @Published var record: AnalysisRecord
    @Published var detectedPlace: DetectedConcertPlace?
    @Published var concertCandidates: [ConcertCandidate] = []
    @Published var selectedCandidateID: ConcertCandidate.ID?
    @Published var selectedSetlist: ConcertSetlist?
    @Published var isSearching = false
    @Published var lookupStatus = "Preparing metadata lookup..."
    @Published var errorMessage: String?

    private let environment: AppEnvironment
    private var hasStartedAutomaticLookup = false
    private var automaticLookupTask: Task<Void, Never>?

    init(record: AnalysisRecord, environment: AppEnvironment) {
        self.record = record
        self.environment = environment
    }

    var earliestRecording: Date? {
        (record.videos.compactMap(\.createdAt) + record.photos.compactMap(\.createdAt)).min()
    }

    var latestRecording: Date? {
        (record.videos.compactMap(\.createdAt) + record.photos.compactMap(\.createdAt)).max()
    }

    var canBeginAnalysis: Bool {
        selectedSetlist != nil || selectedCandidateID != nil || !isSearching
    }

    func startAutomaticLookupIfNeeded() {
        guard !hasStartedAutomaticLookup else {
            AppLog.network.debug("Skipping automatic setlist lookup because it already started. isSearching=\(self.isSearching, privacy: .public) status=\(self.lookupStatus, privacy: .public)")
            return
        }
        hasStartedAutomaticLookup = true
        AppLog.network.info("Automatic setlist lookup task created record=\(self.record.id.uuidString, privacy: .public)")
        automaticLookupTask = Task { [weak self] in
            guard let self else { return }
            AppLog.network.info("Automatic setlist lookup task started record=\(self.record.id.uuidString, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            await self.resolveConcertFromMetadata()
            AppLog.network.info("Automatic setlist lookup task finished record=\(self.record.id.uuidString, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) isSearching=\(self.isSearching, privacy: .public) status=\(self.lookupStatus, privacy: .public)")
        }
    }

    func cancelAutomaticLookup(reason: String) {
        guard let automaticLookupTask, !automaticLookupTask.isCancelled else { return }
        AppLog.network.info("Automatic setlist lookup cancellation requested record=\(self.record.id.uuidString, privacy: .public) reason=\(reason, privacy: .public) isSearching=\(self.isSearching, privacy: .public) status=\(self.lookupStatus, privacy: .public)")
        automaticLookupTask.cancel()
    }

    func resolveConcertFromMetadata() async {
        AppLog.network.info("resolveConcertFromMetadata entered record=\(self.record.id.uuidString, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) previousIsSearching=\(self.isSearching, privacy: .public)")
        isSearching = true
        errorMessage = nil
        selectedSetlist = nil
        concertCandidates = []
        selectedCandidateID = nil
        defer {
            AppLog.network.info("resolveConcertFromMetadata exiting record=\(self.record.id.uuidString, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) status=\(self.lookupStatus, privacy: .public) error=\(self.errorMessage ?? "nil", privacy: .public)")
            isSearching = false
            AppLog.network.info("resolveConcertFromMetadata cleared isSearching record=\(self.record.id.uuidString, privacy: .public) isSearching=\(self.isSearching, privacy: .public)")
        }

        logImportedVideoMetadata()

        guard earliestRecording != nil else {
            lookupStatus = "Missing recording timestamp"
            errorMessage = "The imported media does not contain a recording timestamp."
            AppLog.network.error("Automatic setlist lookup stopped: missing recording timestamp.")
            return
        }

        lookupStatus = "Ready for Shazam artist lookup"
        errorMessage = nil
        AppLog.network.info("Metadata lookup complete using timestamp-only policy. Setlist lookup will run after Shazam identifies a likely artist record=\(self.record.id.uuidString, privacy: .public)")
    }

    func selectCandidate(_ candidate: ConcertCandidate) async {
        selectedCandidateID = candidate.id
        errorMessage = nil
        lookupStatus = "Fetching selected setlist..."
        AppLog.network.info("User selected setlist candidate id=\(candidate.id, privacy: .public) artist=\(candidate.artistName, privacy: .public) venue=\(candidate.venueName ?? "nil", privacy: .public)")
        await fetchSetlist(for: candidate)
    }

    func confirmedRecord() async -> AnalysisRecord {
        AppLog.analysis.info("confirmedRecord entered record=\(self.record.id.uuidString, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) isSearching=\(self.isSearching, privacy: .public) selectedSetlist=\((self.selectedSetlist != nil), privacy: .public) selectedCandidateID=\(self.selectedCandidateID ?? "nil", privacy: .public)")
        if let selectedSetlist {
            record.selectedConcert = concertCandidate(for: selectedSetlist)
            record.selectedSetlist = selectedSetlist
            AppLog.analysis.info("Confirmed record with setlist id=\(selectedSetlist.id, privacy: .public) artist=\(selectedSetlist.artistName, privacy: .public) venue=\(selectedSetlist.venueName ?? "nil", privacy: .public) songs=\(selectedSetlist.occurrences.count, privacy: .public)")
        } else if let selectedCandidateID {
            AppLog.analysis.info("Confirmed record needs final setlist fetch id=\(selectedCandidateID, privacy: .public)")
            do {
                let setlist = try await environment.setlistService.fetchSetlist(id: selectedCandidateID)
                record.selectedConcert = concertCandidates.first { $0.id == selectedCandidateID }
                record.selectedSetlist = setlist
                selectedSetlist = setlist
                AppLog.analysis.info("Final setlist fetch succeeded id=\(setlist.id, privacy: .public) venue=\(setlist.venueName ?? "nil", privacy: .public) songs=\(setlist.occurrences.count, privacy: .public)")
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppLog.analysis.error("Final setlist fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            AppLog.analysis.info("Confirmed record without selected setlist.")
        }
        record.updatedAt = Date()
        AppLog.analysis.info("confirmedRecord returning record=\(self.record.id.uuidString, privacy: .public) selectedSetlist=\((self.record.selectedSetlist != nil), privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
        return record
    }

    private func searchConcerts(date: Date, location: VideoLocation, place: DetectedConcertPlace) async {
        do {
            AppLog.network.info("Starting metadata setlist search date=\(Formatting.dateOnly.string(from: date), privacy: .public) place=\(place.displayName, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            concertCandidates = try await environment.setlistService.searchConcerts(
                artist: nil,
                date: date,
                venue: nil,
                location: location,
                cityName: place.cityName,
                stateCode: place.stateCode,
                countryCode: place.countryCode
            )
            AppLog.network.info("Setlist search returned \(self.concertCandidates.count, privacy: .public) candidates. taskCancelled=\(Task.isCancelled, privacy: .public)")
            for candidate in concertCandidates {
                AppLog.network.info("Setlist candidate id=\(candidate.id, privacy: .public) artist=\(candidate.artistName, privacy: .public) venue=\(candidate.venueName ?? "nil", privacy: .public) city=\(candidate.city ?? "nil", privacy: .public) score=\(candidate.confidenceScore, privacy: .public)")
            }
            if concertCandidates.isEmpty {
                lookupStatus = "No setlists found"
                errorMessage = "No setlists were found for the video's date and location."
                AppLog.network.error("No setlists found for metadata lookup.")
            }
        } catch is CancellationError {
            lookupStatus = "Setlist lookup cancelled"
            errorMessage = nil
            AppLog.network.info("Setlist search cancelled by task cancellation.")
        } catch ConcertSongFinderError.unknown(let message) where Task.isCancelled || message.localizedCaseInsensitiveContains("cancelled") {
            lookupStatus = "Setlist lookup cancelled"
            errorMessage = nil
            AppLog.network.info("Setlist search cancelled while leaving setup flow: \(message, privacy: .public)")
        } catch {
            lookupStatus = "Setlist search failed"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.network.error("Setlist search failed: \(error.localizedDescription, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
        }
    }

    private func autoSelectSetlistIfPossible() async {
        guard !concertCandidates.isEmpty else { return }

        if concertCandidates.count == 1, let candidate = concertCandidates.first {
            selectedCandidateID = candidate.id
            lookupStatus = "Fetching setlist..."
            AppLog.network.info("Auto-selecting only setlist candidate id=\(candidate.id, privacy: .public)")
            await fetchSetlist(for: candidate)
            return
        }

        if allCandidatesShareVenue(concertCandidates) {
            lookupStatus = "Fetching venue setlists..."
            AppLog.network.info("Auto-including \(self.concertCandidates.count, privacy: .public) setlist candidates from shared venue=\(self.concertCandidates.first?.venueName ?? "nil", privacy: .public)")
            await fetchCombinedVenueSetlist(for: concertCandidates)
            return
        }

        lookupStatus = "Multiple possible venues found"
        errorMessage = "Multiple venues matched this date and location. Select the correct setlist below."
        AppLog.network.info("Automatic setlist selection skipped because \(self.concertCandidates.count, privacy: .public) candidates matched across multiple venues.")
    }

    private func fetchSetlist(for candidate: ConcertCandidate) async {
        do {
            let setlist = try await environment.setlistService.fetchSetlist(id: candidate.id)
            selectedSetlist = setlist
            selectedCandidateID = candidate.id
            errorMessage = nil
            lookupStatus = "Setlist ready"
            AppLog.network.info("Fetched setlist id=\(setlist.id, privacy: .public) artist=\(setlist.artistName, privacy: .public) venue=\(setlist.venueName ?? "nil", privacy: .public) songs=\(setlist.occurrences.count, privacy: .public)")
        } catch {
            lookupStatus = "Setlist fetch failed"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.network.error("Setlist fetch failed id=\(candidate.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchCombinedVenueSetlist(for candidates: [ConcertCandidate]) async {
        var fetchedSetlists: [ConcertSetlist] = []
        var failedFetches: [String] = []

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { return }
            do {
                AppLog.network.info("Fetching venue setlist \(index + 1, privacy: .public)/\(candidates.count, privacy: .public) id=\(candidate.id, privacy: .public) artist=\(candidate.artistName, privacy: .public)")
                let setlist = try await environment.setlistService.fetchSetlist(id: candidate.id)
                fetchedSetlists.append(setlist)
                AppLog.network.info("Fetched venue setlist id=\(setlist.id, privacy: .public) artist=\(setlist.artistName, privacy: .public) songs=\(setlist.occurrences.count, privacy: .public)")
            } catch {
                failedFetches.append(candidate.artistName)
                AppLog.network.error("Venue setlist fetch failed id=\(candidate.id, privacy: .public) artist=\(candidate.artistName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

            if index < candidates.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: 650_000_000)
                } catch {
                    return
                }
            }
        }

        guard !fetchedSetlists.isEmpty else {
            lookupStatus = "Setlist fetch failed"
            errorMessage = "Could not fetch the venue setlists. Please try again later."
            AppLog.network.error("No venue setlists could be fetched for combined setup selection.")
            return
        }

        selectedSetlist = combinedSetlist(from: fetchedSetlists, candidates: candidates)
        selectedCandidateID = selectedSetlist?.id
        lookupStatus = failedFetches.isEmpty ? "Venue setlists ready" : "Partial venue setlists ready"
        errorMessage = failedFetches.isEmpty ? nil : "Some venue setlists could not be fetched: \(failedFetches.joined(separator: ", "))."
        AppLog.network.info("Combined venue setlist ready id=\(self.selectedSetlist?.id ?? "nil", privacy: .public) sourceSetlists=\(fetchedSetlists.count, privacy: .public) songs=\(self.selectedSetlist?.occurrences.count ?? 0, privacy: .public)")
    }

    private func combinedSetlist(from setlists: [ConcertSetlist], candidates: [ConcertCandidate]) -> ConcertSetlist {
        var combinedOccurrences: [SetlistOccurrence] = []
        var overallIndex = 0

        for setlist in setlists {
            for occurrence in setlist.occurrences {
                combinedOccurrences.append(
                    SetlistOccurrence(
                        id: occurrence.id,
                        setlistID: occurrence.setlistID,
                        setNumber: occurrence.setNumber,
                        songIndex: occurrence.songIndex,
                        overallIndex: overallIndex,
                        title: occurrence.title,
                        normalizedTitle: occurrence.normalizedTitle,
                        artist: occurrence.artist,
                        setName: occurrence.setName,
                        isEncore: occurrence.isEncore,
                        isTape: occurrence.isTape,
                        notes: occurrence.notes
                    )
                )
                overallIndex += 1
            }
        }

        let artists = orderedUnique(setlists.map(\.artistName))
        let venueName = setlists.compactMap(\.venueName).first ?? candidates.compactMap(\.venueName).first
        let eventDate = setlists.compactMap(\.eventDate).first ?? candidates.compactMap(\.eventDate).first
        let sourceIDs = setlists.map(\.id).joined(separator: "+")
        let versionID = setlists.map(\.versionID).joined(separator: "+")

        return ConcertSetlist(
            id: "combined-\(sourceIDs)",
            artistName: artists.joined(separator: ", "),
            venueName: venueName,
            eventDate: eventDate,
            occurrences: combinedOccurrences,
            attributionURL: setlists.compactMap(\.attributionURL).first,
            versionID: "combined-\(versionID)"
        )
    }

    private func allCandidatesShareVenue(_ candidates: [ConcertCandidate]) -> Bool {
        let venueNames = Set(candidates.compactMap { normalizedVenueName($0.venueName) }.filter { !$0.isEmpty })
        return venueNames.count == 1 && venueNames.first != nil
    }

    private func normalizedVenueName(_ value: String?) -> String {
        (value ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(value)
        }
        return result
    }

    private func concertCandidate(for setlist: ConcertSetlist) -> ConcertCandidate? {
        concertCandidates.first { $0.id == setlist.id } ?? ConcertCandidate(
            id: setlist.id,
            artistName: setlist.artistName,
            venueName: setlist.venueName,
            city: detectedPlace?.cityName,
            eventDate: setlist.eventDate,
            confidenceScore: 0.95,
            attributionURL: setlist.attributionURL
        )
    }

    private func logImportedVideoMetadata() {
        AppLog.importLog.info("Starting automatic concert lookup for \(self.record.videos.count, privacy: .public) imported videos and \(self.record.photos.count, privacy: .public) imported photos.")
        for video in record.videos {
            AppLog.importLog.info("Imported video id=\(video.id.uuidString, privacy: .public) file=\(video.fileName, privacy: .public) createdAt=\(video.createdAt.map { Formatting.timestamp.string(from: $0) } ?? "nil", privacy: .public) duration=\(video.duration, privacy: .public)")
        }
        for photo in record.photos {
            AppLog.importLog.info("Imported photo id=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) createdAt=\(photo.createdAt.map { Formatting.timestamp.string(from: $0) } ?? "nil", privacy: .public)")
        }
    }
}
