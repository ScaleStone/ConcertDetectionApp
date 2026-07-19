import ConcertSongFinderCore
import Foundation

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published private(set) var record: AnalysisRecord
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var currentVideoName: String = ""
    @Published private(set) var currentRangeDescription: String = ""
    @Published private(set) var songsFound: Int = 0
    @Published private(set) var stage: RecognitionStage = .idle
    @Published private(set) var errorMessage: String?

    private let environment: AppEnvironment
    private var isCancelled = false
    private var analysisTask: Task<AnalysisRecord, Never>?
    private var didWarnLyricsUnavailable = false
    /// Prepared audio is retained across pipeline phases (Shazam pass first,
    /// timeline/fallback later) and cleaned up when the analysis finishes.
    private var preparedAudioByVideoID: [UUID: PreparedAudio] = [:]
    private var retainedTemporaryFiles: [URL] = []

    init(record: AnalysisRecord, environment: AppEnvironment) {
        self.record = record
        self.environment = environment
    }

    /// Starts (or returns the already-running) analysis in a task owned by
    /// this view model rather than the view. This keeps a multi-minute
    /// analysis alive when the hosting view disappears (e.g. tab switch).
    func startAnalysis() -> Task<AnalysisRecord, Never> {
        if let analysisTask {
            return analysisTask
        }
        let task = Task { await self.analyze() }
        analysisTask = task
        return task
    }

    func cancel() {
        AppLog.analysis.warning("User requested analysis cancellation for record \(self.record.id.uuidString, privacy: .public)")
        isCancelled = true
        // Cancel the running task too so in-flight work (Shazam windows,
        // transcription, network calls) stops promptly instead of waiting
        // for the next between-videos check.
        analysisTask?.cancel()
    }

    /// The multi-concert pipeline, in phases:
    /// 1. Shazam recognition pass over ALL videos (no setlist lookups yet)
    /// 2. Timestamp clustering of all media into concert clusters
    /// 3. Per-cluster concert/setlist identification (failure never merges clusters)
    /// 4. Per-video timeline build + speech/lyrics fallback (cluster-scoped setlist)
    /// 5. Per-cluster artist consensus + media classification
    func analyze() async -> AnalysisRecord {
        AppLog.analysis.info("AnalysisViewModel.analyze started record=\(self.record.id.uuidString, privacy: .public) videoCount=\(self.record.videos.count, privacy: .public) photoCount=\(self.record.photos.count, privacy: .public)")
        isCancelled = false
        record.currentStage = .extractingAudio
        persist()

        // PHASE 1: Shazam-first pass across every video.
        let videoCount = max(record.videos.count, 1)
        for index in record.videos.indices {
            if isCancelled || Task.isCancelled {
                AppLog.analysis.warning("Analysis canceled during Shazam pass before video index=\(index, privacy: .public)")
                return finishCanceled()
            }
            currentVideoName = record.videos[index].fileName
            overallProgress = 0.6 * Double(index) / Double(videoCount)
            if record.videos[index].analysisStatus == .completed, !record.videos[index].segments.isEmpty {
                AppLog.analysis.info("Skipping previously completed video during incremental analysis index=\(index, privacy: .public) video=\(self.record.videos[index].id.uuidString, privacy: .public)")
            } else {
                await shazamPass(at: index)
            }
            overallProgress = 0.6 * Double(index + 1) / Double(videoCount)
            persist()
            if isCancelled || Task.isCancelled || record.videos[index].analysisStatus == .canceled {
                return finishCanceled()
            }
        }

        // PHASE 2: group all media into concert clusters by timestamp.
        formClustersIfNeeded()
        persist()

        // PHASE 3: identify each cluster independently.
        await identifyClusters()
        persist()
        if isCancelled || Task.isCancelled {
            return finishCanceled()
        }

        // PHASE 4: timelines and fallback per video, scoped to its cluster.
        for index in record.videos.indices {
            if isCancelled || Task.isCancelled {
                return finishCanceled()
            }
            currentVideoName = record.videos[index].fileName
            if record.videos[index].analysisStatus == .completed, !record.videos[index].segments.isEmpty {
                continue
            }
            await buildTimelineAndFallback(at: index)
            overallProgress = 0.6 + 0.35 * Double(index + 1) / Double(videoCount)
            persist()
        }

        // PHASE 5: consensus filter and media classification per cluster.
        applyArtistConsensusFilterPerCluster()
        classifyMediaPerCluster()
        songsFound = reliableSongCount()

        cleanupRetainedAudio()
        AppLog.analysis.info("AnalysisViewModel.analyze marking completed record=\(self.record.id.uuidString, privacy: .public) clusters=\(self.record.clusters.count, privacy: .public) statuses=\(self.record.videos.map { $0.analysisStatus.rawValue }.joined(separator: ","), privacy: .public)")
        stage = .completed
        record.currentStage = .completed
        record.updatedAt = Date()
        overallProgress = 1
        persist()
        return record
    }

    // MARK: - Phase 1: Shazam pass

    private func shazamPass(at index: Int) async {
        do {
            try Task.checkCancellation()
            stage = .extractingAudio
            record.currentStage = .extractingAudio
            record.videos[index].analysisStatus = .extractingAudio
            AppLog.analysis.info("Extracting audio for video \(self.record.videos[index].id.uuidString, privacy: .public)")

            let preparedAudio = try await environment.audioExtractionService.prepareAudio(for: record.videos[index])
            preparedAudioByVideoID[record.videos[index].id] = preparedAudio
            retainedTemporaryFiles.append(contentsOf: preparedAudio.temporaryFiles)

            try Task.checkCancellation()
            stage = .checkingShazam
            record.currentStage = .checkingShazam
            record.videos[index].analysisStatus = .recognizing
            let windows = RecognitionWindowPlanner.windows(duration: preparedAudio.duration)
            currentRangeDescription = windows.first.map { "\(Formatting.duration($0.start))-\(Formatting.duration($0.end))" } ?? ""
            let rawMatches = try await environment.musicRecognitionService.recognize(
                audio: preparedAudio,
                configuration: .default
            )
            AppLog.analysis.info("Shazam pass completed video=\(self.record.videos[index].id.uuidString, privacy: .public) rawMatchCount=\(rawMatches.count, privacy: .public) matches=\(rawMatches.map { $0.song.title + " by " + $0.song.artist }.joined(separator: " | "), privacy: .public)")
            record.rawMatchesByVideoID[record.videos[index].id] = rawMatches
        } catch is CancellationError {
            AppLog.analysis.error("Shazam pass caught CancellationError video=\(self.record.videos[index].id.uuidString, privacy: .public)")
            record.videos[index].analysisStatus = .canceled
            stage = .canceled
        } catch {
            AppLog.analysis.error("Shazam pass failed for video \(self.record.videos[index].id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            record.videos[index].analysisStatus = .failed
            if record.videos[index].segments.isEmpty {
                record.videos[index].segments = [
                    SongSegment(
                        startTime: 0,
                        endTime: record.videos[index].duration,
                        status: .unknown,
                        primaryCandidate: nil
                    )
                ]
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Phase 2: clustering

    private func formClustersIfNeeded() {
        // Re-analysis of an existing record keeps its clusters so cluster ids
        // (and therefore persisted concert identities) stay stable.
        guard record.clusters.isEmpty else { return }

        var clusters = ConcertClusterer.cluster(videos: record.videos, photos: record.photos)

        // A concert manually selected during setup applies to the cluster(s)
        // on the same calendar day; with a single cluster it applies directly.
        if let setlist = record.selectedSetlist {
            if clusters.count == 1 {
                clusters[0].selectedSetlist = setlist
                clusters[0].selectedConcert = record.selectedConcert
            } else {
                let eventDate = setlist.eventDate ?? record.selectedConcert?.eventDate
                for index in clusters.indices {
                    if let clusterDate = clusters[index].clusterDate,
                       let eventDate,
                       Self.eventDay(eventDate) == Self.localDay(clusterDate) {
                        clusters[index].selectedSetlist = setlist
                        clusters[index].selectedConcert = record.selectedConcert
                    }
                }
            }
        }

        record.clusters = clusters
        AppLog.analysis.info("Formed \(clusters.count, privacy: .public) concert clusters record=\(self.record.id.uuidString, privacy: .public) sizes=\(clusters.map { "\($0.videoIDs.count)v/\($0.photoIDs.count)p" }.joined(separator: ","), privacy: .public)")
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    /// Backend event dates are calendar dates at UTC midnight.
    private static func eventDay(_ date: Date) -> DateComponents {
        utcCalendar.dateComponents([.year, .month, .day], from: date)
    }

    /// Media timestamps are real instants read in local time.
    private static func localDay(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - Phase 3: per-cluster identification

    private func identifyClusters() async {
        for index in record.clusters.indices {
            if isCancelled || Task.isCancelled { return }
            var cluster = record.clusters[index]
            let rankedArtists = rankedArtists(forClusterVideoIDs: cluster.videoIDs)

            // Fallback label is always set so an unidentified cluster still
            // has a meaningful name ("Artist — date" / "Concert — date").
            cluster.fallbackLabel = ConcertClusterer.fallbackLabel(
                artist: rankedArtists.first,
                clusterDate: cluster.clusterDate,
                isUndated: cluster.isUndated
            )

            guard cluster.selectedSetlist == nil else {
                record.clusters[index] = cluster
                continue
            }
            guard let date = cluster.clusterDate else {
                // Undated cluster: no date to search by; stays separate with
                // its fallback label.
                record.clusters[index] = cluster
                continue
            }
            guard !rankedArtists.isEmpty else {
                AppLog.network.info("Cluster identification skipped because no artist was recognized cluster=\(cluster.id.uuidString, privacy: .public)")
                record.clusters[index] = cluster
                continue
            }

            stage = .checkingSetlist
            record.currentStage = .checkingSetlist

            // Openers: multiple artists in one cluster are one concert. Try
            // the likely headliner first (most distinct songs, later in the
            // evening), then fall back to the other recognized artists.
            for artist in rankedArtists.prefix(3) {
                do {
                    AppLog.network.info("Cluster setlist lookup cluster=\(cluster.id.uuidString, privacy: .public) artist=\(artist, privacy: .public) date=\(Formatting.dateOnly.string(from: date), privacy: .public)")
                    let candidates = try await environment.setlistService.searchConcerts(
                        artist: artist,
                        date: date,
                        venue: nil,
                        location: nil,
                        cityName: nil,
                        stateCode: nil,
                        countryCode: nil
                    )
                    guard let selected = autoSelectableCandidate(from: candidates) else {
                        AppLog.network.info("Cluster lookup ambiguous or empty cluster=\(cluster.id.uuidString, privacy: .public) artist=\(artist, privacy: .public) candidateCount=\(candidates.count, privacy: .public)")
                        continue
                    }
                    let setlist = try await environment.setlistService.fetchSetlist(id: selected.id)
                    cluster.selectedConcert = selected
                    cluster.selectedSetlist = setlist
                    AppLog.network.info("Cluster identified cluster=\(cluster.id.uuidString, privacy: .public) setlist=\(setlist.id, privacy: .public) artist=\(setlist.artistName, privacy: .public) venue=\(setlist.venueName ?? "nil", privacy: .public) songs=\(setlist.occurrences.count, privacy: .public)")
                    break
                } catch is CancellationError {
                    record.clusters[index] = cluster
                    return
                } catch {
                    // Identification failure never merges or drops clusters.
                    AppLog.network.error("Cluster setlist lookup failed cluster=\(cluster.id.uuidString, privacy: .public) artist=\(artist, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            record.clusters[index] = cluster
        }

        // Preserve the record-level selection for the single-cluster case so
        // existing results/attribution behavior is unchanged.
        if record.clusters.count == 1 {
            record.selectedConcert = record.selectedConcert ?? record.clusters[0].selectedConcert
            record.selectedSetlist = record.selectedSetlist ?? record.clusters[0].selectedSetlist
        }
    }

    /// Ranks recognized artists in a cluster by headliner likelihood:
    /// most distinct recognized songs first, later-evening appearance as the
    /// tie-breaker (openers play earlier), then window support.
    private func rankedArtists(forClusterVideoIDs videoIDs: [UUID]) -> [String] {
        struct ArtistStats {
            var songIDs: Set<String> = []
            var windowCount = 0
            var latestVideoDate: Date?
        }
        var stats: [String: ArtistStats] = [:]
        var displayNames: [String: String] = [:]
        let unknownKey = TextNormalizer.normalizeText("Unknown Artist")

        for videoID in videoIDs {
            let videoDate = record.videos.first(where: { $0.id == videoID })?.createdAt
            for match in record.rawMatchesByVideoID[videoID] ?? [] {
                let artist = match.song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = TextNormalizer.normalizeText(artist)
                guard !key.isEmpty, key != unknownKey else { continue }
                var artistStats = stats[key, default: ArtistStats()]
                artistStats.songIDs.insert(match.song.id)
                artistStats.windowCount += 1
                if let videoDate, artistStats.latestVideoDate.map({ videoDate > $0 }) ?? true {
                    artistStats.latestVideoDate = videoDate
                }
                stats[key] = artistStats
                displayNames[key] = artist
            }
        }

        return stats
            .sorted { left, right in
                if left.value.songIDs.count != right.value.songIDs.count {
                    return left.value.songIDs.count > right.value.songIDs.count
                }
                switch (left.value.latestVideoDate, right.value.latestVideoDate) {
                case let (.some(a), .some(b)) where a != b:
                    return a > b
                default:
                    return left.value.windowCount > right.value.windowCount
                }
            }
            .compactMap { displayNames[$0.key] }
    }

    private func autoSelectableCandidate(from candidates: [ConcertCandidate]) -> ConcertCandidate? {
        guard let best = candidates.max(by: { $0.confidenceScore < $1.confidenceScore }) else { return nil }
        if candidates.count == 1 { return best }

        let secondBestScore = candidates
            .filter { $0.id != best.id }
            .map(\.confidenceScore)
            .max() ?? 0
        return best.confidenceScore >= 0.78 && best.confidenceScore - secondBestScore >= 0.12 ? best : nil
    }

    // MARK: - Phase 4: timeline + fallback

    private func buildTimelineAndFallback(at index: Int) async {
        let video = record.videos[index]
        guard video.analysisStatus != .failed, video.analysisStatus != .canceled else { return }

        let rawMatches = record.rawMatchesByVideoID[video.id] ?? []
        stage = .buildingTimeline
        record.currentStage = .buildingTimeline
        record.videos[index].analysisStatus = .buildingTimeline
        var segments = environment.timelineBuilder.buildTimeline(
            duration: video.duration,
            rawMatches: rawMatches,
            configuration: .default
        )
        AppLog.analysis.info("Timeline build completed video=\(video.id.uuidString, privacy: .public) segmentCount=\(segments.count, privacy: .public) statuses=\(segments.map { $0.status.rawValue }.joined(separator: ","), privacy: .public)")

        if segments.contains(where: { $0.status == .unknown }),
           let preparedAudio = preparedAudioByVideoID[video.id] {
            let cluster = cluster(containingVideoID: video.id)
            segments = await transcribeAndEnrichUnknownSegments(
                segments,
                videoIndex: index,
                preparedAudio: preparedAudio,
                cluster: cluster
            )
        }

        record.videos[index].segments = segments
        record.videos[index].analysisStatus = .completed
        songsFound = reliableSongCount()
    }

    private func cluster(containingVideoID videoID: UUID) -> ConcertClusterAssignment? {
        record.clusters.first { $0.videoIDs.contains(videoID) }
    }

    private func transcribeAndEnrichUnknownSegments(
        _ segments: [SongSegment],
        videoIndex: Int,
        preparedAudio: PreparedAudio,
        cluster: ConcertClusterAssignment?
    ) async -> [SongSegment] {
        var updated = segments
        let videoID = record.videos[videoIndex].id
        let clusterSetlist = cluster?.selectedSetlist ?? record.selectedSetlist
        let clusterVideoIDs = cluster.map { Set($0.videoIDs) }

        let candidateWindow: CandidateSetlistWindow?
        if let setlist = clusterSetlist {
            stage = .checkingSetlist
            record.currentStage = .checkingSetlist

            let observations = makeObservations(restrictedTo: clusterVideoIDs)
            let clusterVideoOrder = videoOrder(of: videoID, within: clusterVideoIDs)
            let alignment = environment.alignmentService.align(observations: observations, to: setlist.occurrences)
            let window = environment.alignmentService.candidateWindow(
                forVideoOrder: clusterVideoOrder,
                observations: observations,
                occurrences: setlist.occurrences,
                alignment: alignment
            )
            candidateWindow = window.occurrences.isEmpty ? nil : window
        } else {
            candidateWindow = nil
        }

        for segmentIndex in updated.indices where updated[segmentIndex].status == .unknown {
            do {
                stage = .transcribing
                record.currentStage = .transcribing
                let segment = updated[segmentIndex]
                let alternatives = try await environment.speechTranscriptionService.transcribe(
                    audioURL: preparedAudio.audioURL,
                    timeRange: segment.startTime..<segment.endTime,
                    locale: Locale(identifier: "en_US")
                )
                let transcriptTexts = alternatives.map(\.text).filter { !$0.isEmpty }
                updated[segmentIndex].evidence.speechAlternatives = transcriptTexts
                AppLog.analysis.info("Speech transcription unknown segment video=\(videoID.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) alternativeCount=\(alternatives.count, privacy: .public)")

                guard let candidateWindow, !transcriptTexts.isEmpty else {
                    continue
                }

                stage = .comparingLyrics
                record.currentStage = .comparingLyrics
                let songs = candidateWindow.occurrences.map {
                    SongIdentity(id: TextNormalizer.normalizedSongKey(title: $0.title, artist: $0.artist), title: $0.title, artist: $0.artist)
                }
                let lyrics = try await environment.lyricsService.lyrics(for: songs)
                let usableLyrics = lyrics.filter { !($0.lyrics ?? "").isEmpty }
                if usableLyrics.isEmpty {
                    // The lyrics provider is not configured (backend stub
                    // returns unavailable records). Tell the user once
                    // instead of silently producing no lyric evidence.
                    if !didWarnLyricsUnavailable {
                        didWarnLyricsUnavailable = true
                        errorMessage = "Lyric matching was skipped because no lyrics provider is configured. Unknown segments rely on Shazam and setlist evidence only."
                        AppLog.analysis.warning("Lyrics provider returned no usable lyrics; lyric matching skipped for this analysis.")
                    }
                    continue
                }
                let prior = Dictionary(uniqueKeysWithValues: candidateWindow.occurrences.map { ($0.id, candidateWindow.confidenceModifier) })
                let ranked = environment.lyricMatchingService.rankCandidates(
                    transcripts: alternatives,
                    lyrics: lyrics,
                    occurrences: candidateWindow.occurrences,
                    context: RecognitionContext(
                        targetVideoID: videoID,
                        videoOrder: videoOrder(of: videoID, within: clusterVideoIDs),
                        setlistPriorByOccurrenceID: prior
                    )
                )

                if let top = ranked.first, top.confidenceLabel != .insufficient {
                    updated[segmentIndex].primaryCandidate = top
                    updated[segmentIndex].alternativeCandidates = Array(ranked.dropFirst())
                    updated[segmentIndex].status = top.confidenceLabel == .likely ? .likely : .possible
                    updated[segmentIndex].evidence.setlistSequencePrior = candidateWindow.confidenceModifier
                    updated[segmentIndex].evidence.classificationSource = .lyrics
                }
            } catch {
                AppLog.analysis.error("Speech transcription failed for unknown segment video=\(videoID.uuidString, privacy: .public) segment=\(updated[segmentIndex].id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return updated
    }

    /// Observations for setlist alignment; restricted to a cluster's videos
    /// so one concert's recognized songs never influence another's alignment.
    private func makeObservations(restrictedTo clusterVideoIDs: Set<UUID>?) -> [SongObservation] {
        let scopedVideos = record.videos.filter { clusterVideoIDs?.contains($0.id) ?? true }
        return scopedVideos.enumerated().flatMap { videoIndex, video in
            video.segments.compactMap { segment in
                guard let candidate = segment.primaryCandidate,
                      [.identified, .likely, .userConfirmed].contains(segment.status) else {
                    return nil
                }
                return SongObservation(
                    videoID: video.id,
                    segmentID: segment.id,
                    videoOrder: videoIndex,
                    segmentStart: segment.startTime,
                    segmentEnd: segment.endTime,
                    song: candidate.song,
                    confidenceLabel: candidate.confidenceLabel,
                    isUserConfirmed: segment.evidence.isUserConfirmed
                )
            }
        }
    }

    /// Order of a video within its cluster (or the whole record when
    /// unclustered), matching the ordering used by makeObservations.
    private func videoOrder(of videoID: UUID, within clusterVideoIDs: Set<UUID>?) -> Int {
        let scopedVideos = record.videos.filter { clusterVideoIDs?.contains($0.id) ?? true }
        return scopedVideos.firstIndex(where: { $0.id == videoID }) ?? 0
    }

    // MARK: - Phase 5: consensus + classification

    private func applyArtistConsensusFilterPerCluster() {
        let clusters = record.clusters.isEmpty
            ? [ConcertClusterAssignment(videoIDs: record.videos.map(\.id), photoIDs: record.photos.map(\.id))]
            : record.clusters

        for cluster in clusters {
            let clusterVideoIDs = Set(cluster.videoIDs)
            guard let dominantArtist = dominantArtistName(in: cluster) else {
                continue
            }

            var demotedCount = 0
            for videoIndex in record.videos.indices where clusterVideoIDs.contains(record.videos[videoIndex].id) {
                for segmentIndex in record.videos[videoIndex].segments.indices {
                    let segment = record.videos[videoIndex].segments[segmentIndex]
                    guard segment.status == .possible,
                          segment.evidence.shazamWindowCount <= 1,
                          let candidate = segment.primaryCandidate,
                          !artist(candidate.song.artist, matches: dominantArtist) else {
                        continue
                    }

                    record.videos[videoIndex].segments[segmentIndex].status = .unknown
                    record.videos[videoIndex].segments[segmentIndex].primaryCandidate = nil
                    record.videos[videoIndex].segments[segmentIndex].alternativeCandidates = [candidate]
                    demotedCount += 1
                }
            }
            AppLog.analysis.info("Artist consensus filter completed cluster=\(cluster.id.uuidString, privacy: .public) dominantArtist=\(dominantArtist, privacy: .public) demotedCount=\(demotedCount, privacy: .public)")
        }
    }

    private func dominantArtistName(in cluster: ConcertClusterAssignment) -> String? {
        if let artist = cluster.selectedSetlist?.artistName.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return artist
        }

        let clusterVideoIDs = Set(cluster.videoIDs)
        var weightedCounts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for video in record.videos where clusterVideoIDs.contains(video.id) {
            for segment in video.segments {
                guard let candidate = segment.primaryCandidate,
                      [.identified, .likely, .userConfirmed].contains(segment.status) else {
                    continue
                }

                let artist = candidate.song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalizedArtist(artist)
                guard !key.isEmpty && key != normalizedArtist("Unknown Artist") else { continue }

                weightedCounts[key, default: 0] += max(segment.evidence.shazamWindowCount, 1)
                displayNames[key] = artist
            }
        }

        guard let best = weightedCounts.max(by: { $0.value < $1.value }),
              best.value >= 3 else {
            return nil
        }

        return displayNames[best.key]
    }

    /// Runs media classification per cluster so photos from one concert are
    /// never matched against another concert's setlist or timeline.
    private func classifyMediaPerCluster() {
        let service = DefaultMediaClassificationService()
        let subRecords = record.perClusterAnalysisRecords()

        AppLog.mediaClassification.info("Starting media classification record=\(self.record.id.uuidString, privacy: .public) clusterCount=\(subRecords.count, privacy: .public)")
        if subRecords.count == 1 {
            let classified = service.classify(record: subRecords[0])
            record.photos = classified.photos
            record.videos = classified.videos
            return
        }

        for subRecord in subRecords {
            let classified = service.classify(record: subRecord)
            for photo in classified.photos {
                if let photoIndex = record.photos.firstIndex(where: { $0.id == photo.id }) {
                    record.photos[photoIndex] = photo
                }
            }
            for video in classified.videos {
                if let videoIndex = record.videos.firstIndex(where: { $0.id == video.id }) {
                    record.videos[videoIndex] = video
                }
            }
        }
    }

    // MARK: - Shared helpers

    private func finishCanceled() -> AnalysisRecord {
        cleanupRetainedAudio()
        stage = .canceled
        record.currentStage = .canceled
        persist()
        return record
    }

    private func cleanupRetainedAudio() {
        for file in retainedTemporaryFiles {
            AppLog.analysis.info("Removing temporary analysis file \(file.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
        }
        retainedTemporaryFiles = []
        preparedAudioByVideoID = [:]
    }

    private func artist(_ artist: String, matches dominantArtist: String) -> Bool {
        let artist = normalizedArtist(artist)
        let dominantArtist = normalizedArtist(dominantArtist)
        guard !artist.isEmpty, !dominantArtist.isEmpty else { return false }
        return artist == dominantArtist ||
            artist.contains(dominantArtist) ||
            dominantArtist.contains(artist)
    }

    private func normalizedArtist(_ artist: String) -> String {
        TextNormalizer.normalizeText(artist)
    }

    private func reliableSongCount() -> Int {
        let reliableStatuses: Set<SegmentStatus> = [.identified, .likely, .userConfirmed]
        let videoSongIDs = record.videos.flatMap(\.segments).compactMap { segment in
            reliableStatuses.contains(segment.status) ? segment.primaryCandidate?.song.id : nil
        }
        let photoSongIDs = record.photos.compactMap { photo in
            reliableStatuses.contains(photo.classificationStatus) ? photo.primaryCandidate?.song.id : nil
        }
        return Set(videoSongIDs + photoSongIDs).count
    }

    private func persist() {
        do {
            var records = try environment.historyStore.loadRecords()
            records.removeAll { $0.id == record.id }
            record.updatedAt = Date()
            records.append(record)
            try environment.historyStore.saveRecords(records)
        } catch {
            AppLog.analysis.error("Could not persist analysis history: \(String(describing: error), privacy: .private)")
        }
    }
}
