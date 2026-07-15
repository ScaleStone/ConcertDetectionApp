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

    init(record: AnalysisRecord, environment: AppEnvironment) {
        self.record = record
        self.environment = environment
    }

    func cancel() {
        AppLog.analysis.warning("User requested analysis cancellation for record \(self.record.id.uuidString, privacy: .public)")
        isCancelled = true
    }

    func analyze() async -> AnalysisRecord {
        AppLog.analysis.info("AnalysisViewModel.analyze started record=\(self.record.id.uuidString, privacy: .public) videoCount=\(self.record.videos.count, privacy: .public) photoCount=\(self.record.photos.count, privacy: .public)")
        isCancelled = false
        record.currentStage = .extractingAudio
        persist()

        for index in record.videos.indices {
            AppLog.analysis.info("Analysis loop entering video index=\(index, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) manualCancelled=\(self.isCancelled, privacy: .public)")
            if isCancelled {
                AppLog.analysis.warning("Analysis loop exiting early from manual cancellation before video index=\(index, privacy: .public)")
                stage = .canceled
                record.currentStage = .canceled
                persist()
                return record
            }

            currentVideoName = record.videos[index].fileName
            overallProgress = Double(index) / Double(max(record.videos.count, 1))
            if record.videos[index].analysisStatus == .completed, !record.videos[index].segments.isEmpty {
                AppLog.analysis.info("Skipping previously completed video during incremental analysis index=\(index, privacy: .public) video=\(self.record.videos[index].id.uuidString, privacy: .public) file=\(self.record.videos[index].fileName, privacy: .public) segmentCount=\(self.record.videos[index].segments.count, privacy: .public)")
            } else {
                await analyzeVideo(at: index)
            }
            AppLog.analysis.info("Analysis loop finished video index=\(index, privacy: .public) status=\(self.record.videos[index].analysisStatus.rawValue, privacy: .public) segmentCount=\(self.record.videos[index].segments.count, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            overallProgress = Double(index + 1) / Double(max(record.videos.count, 1))
            persist()

            if isCancelled || Task.isCancelled || record.videos[index].analysisStatus == .canceled {
                AppLog.analysis.warning("Analysis loop returning canceled record after video index=\(index, privacy: .public)")
                stage = .canceled
                record.currentStage = .canceled
                persist()
                return record
            }
        }

        applyArtistConsensusFilter()
        logTemporalClassificationInputs()
        AppLog.mediaClassification.info("Starting media classification record=\(self.record.id.uuidString, privacy: .public) videoCount=\(self.record.videos.count, privacy: .public) photoCount=\(self.record.photos.count, privacy: .public)")
        record = DefaultMediaClassificationService().classify(record: record)
        AppLog.mediaClassification.info("Finished media classification record=\(self.record.id.uuidString, privacy: .public) photoStatuses=\(self.record.photos.map { $0.classificationStatus.rawValue }.joined(separator: ","), privacy: .public) unknownSegmentsRemaining=\(self.record.videos.flatMap { $0.segments }.filter { $0.status == .unknown }.count, privacy: .public)")
        songsFound = reliableSongCount()

        AppLog.analysis.info("AnalysisViewModel.analyze marking completed record=\(self.record.id.uuidString, privacy: .public) statuses=\(self.record.videos.map { $0.analysisStatus.rawValue }.joined(separator: ","), privacy: .public) segmentCounts=\(self.record.videos.map { String($0.segments.count) }.joined(separator: ","), privacy: .public) photoStatuses=\(self.record.photos.map { $0.classificationStatus.rawValue }.joined(separator: ","), privacy: .public)")
        stage = .completed
        record.currentStage = .completed
        record.updatedAt = Date()
        persist()
        return record
    }

    private func analyzeVideo(at index: Int) async {
        var temporaryFiles: [URL] = []
        do {
            try Task.checkCancellation()
            stage = .extractingAudio
            record.videos[index].analysisStatus = .extractingAudio
            AppLog.analysis.info("Extracting audio for video \(self.record.videos[index].id.uuidString, privacy: .public)")

            let preparedAudio = try await environment.audioExtractionService.prepareAudio(for: record.videos[index])
            temporaryFiles = preparedAudio.temporaryFiles
            AppLog.analysis.info("Audio prepared video=\(self.record.videos[index].id.uuidString, privacy: .public) url=\(preparedAudio.audioURL.lastPathComponent, privacy: .public) duration=\(preparedAudio.duration, privacy: .public) sampleRate=\(preparedAudio.sampleRate, privacy: .public) channels=\(preparedAudio.channelCount, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")

            try Task.checkCancellation()
            stage = .checkingShazam
            record.currentStage = .checkingShazam
            record.videos[index].analysisStatus = .recognizing
            let windows = RecognitionWindowPlanner.windows(duration: preparedAudio.duration)
            AppLog.analysis.info("Shazam recognition starting video=\(self.record.videos[index].id.uuidString, privacy: .public) windowCount=\(windows.count, privacy: .public) windows=\(windows.map { "\(Formatting.duration($0.start))-\(Formatting.duration($0.end))" }.joined(separator: ","), privacy: .public)")
            currentRangeDescription = windows.first.map { "\(Formatting.duration($0.start))-\(Formatting.duration($0.end))" } ?? ""
            let rawMatches = try await environment.musicRecognitionService.recognize(
                audio: preparedAudio,
                configuration: .default
            )
            AppLog.analysis.info("Shazam recognition completed video=\(self.record.videos[index].id.uuidString, privacy: .public) rawMatchCount=\(rawMatches.count, privacy: .public) matches=\(rawMatches.map { $0.song.title + " by " + $0.song.artist }.joined(separator: " | "), privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            record.rawMatchesByVideoID[record.videos[index].id] = rawMatches
            await lookupSetlistFromRecognizedArtistIfNeeded(rawMatches: rawMatches, videoIndex: index)

            try Task.checkCancellation()
            stage = .buildingTimeline
            record.currentStage = .buildingTimeline
            record.videos[index].analysisStatus = .buildingTimeline
            AppLog.analysis.info("Timeline build starting video=\(self.record.videos[index].id.uuidString, privacy: .public) duration=\(self.record.videos[index].duration, privacy: .public) rawMatchCount=\(rawMatches.count, privacy: .public)")
            var segments = environment.timelineBuilder.buildTimeline(
                duration: record.videos[index].duration,
                rawMatches: rawMatches,
                configuration: .default
            )
            AppLog.analysis.info("Timeline build completed video=\(self.record.videos[index].id.uuidString, privacy: .public) segmentCount=\(segments.count, privacy: .public) statuses=\(segments.map { $0.status.rawValue }.joined(separator: ","), privacy: .public)")

            if segments.contains(where: { $0.status == .unknown }) {
                AppLog.analysis.info("Unknown segment detected; starting speech transcription video=\(self.record.videos[index].id.uuidString, privacy: .public) hasSelectedSetlist=\((self.record.selectedSetlist != nil), privacy: .public)")
                segments = await transcribeAndEnrichUnknownSegments(
                    segments,
                    videoIndex: index,
                    preparedAudio: preparedAudio
                )
                AppLog.analysis.info("Unknown segment transcription completed video=\(self.record.videos[index].id.uuidString, privacy: .public) segmentCount=\(segments.count, privacy: .public) statuses=\(segments.map { $0.status.rawValue }.joined(separator: ","), privacy: .public)")
            }

            record.videos[index].segments = segments
            record.videos[index].analysisStatus = .completed
            songsFound = reliableSongCount()
            AppLog.analysis.info("Video analysis completed video=\(self.record.videos[index].id.uuidString, privacy: .public) finalSegmentCount=\(segments.count, privacy: .public) songsFound=\(self.songsFound, privacy: .public)")
        } catch is CancellationError {
            AppLog.analysis.error("Analysis caught CancellationError video=\(self.record.videos[index].id.uuidString, privacy: .public) stage=\(self.stage.rawValue, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public) existingSegmentCount=\(self.record.videos[index].segments.count, privacy: .public)")
            record.videos[index].analysisStatus = .canceled
            stage = .canceled
        } catch {
            AppLog.analysis.error("Analysis failed for video \(self.record.videos[index].id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
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

        for file in temporaryFiles {
            AppLog.analysis.info("Removing temporary analysis file \(file.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func transcribeAndEnrichUnknownSegments(
        _ segments: [SongSegment],
        videoIndex: Int,
        preparedAudio: PreparedAudio
    ) async -> [SongSegment] {
        var updated = segments
        let videoID = record.videos[videoIndex].id

        let candidateWindow: CandidateSetlistWindow?
        if let setlist = record.selectedSetlist {
            stage = .checkingSetlist
            record.currentStage = .checkingSetlist

            let observations = makeObservations()
            let alignment = environment.alignmentService.align(observations: observations, to: setlist.occurrences)
            let window = environment.alignmentService.candidateWindow(
                forVideoOrder: videoIndex,
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
                AppLog.analysis.info("Speech transcription starting unknown segment video=\(videoID.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) range=\(Formatting.duration(segment.startTime), privacy: .public)-\(Formatting.duration(segment.endTime), privacy: .public)")
                let alternatives = try await environment.speechTranscriptionService.transcribe(
                    audioURL: preparedAudio.audioURL,
                    timeRange: segment.startTime..<segment.endTime,
                    locale: Locale(identifier: "en_US")
                )
                let transcriptTexts = alternatives.map(\.text).filter { !$0.isEmpty }
                updated[segmentIndex].evidence.speechAlternatives = transcriptTexts
                AppLog.analysis.info("Speech transcription unknown segment video=\(videoID.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) range=\(Formatting.duration(segment.startTime), privacy: .public)-\(Formatting.duration(segment.endTime), privacy: .public) alternativeCount=\(alternatives.count, privacy: .public) text=\(transcriptTexts.joined(separator: " | "), privacy: .public)")

                guard let candidateWindow, !transcriptTexts.isEmpty else {
                    continue
                }

                stage = .comparingLyrics
                record.currentStage = .comparingLyrics
                let songs = candidateWindow.occurrences.map {
                    SongIdentity(id: TextNormalizer.normalizedSongKey(title: $0.title, artist: $0.artist), title: $0.title, artist: $0.artist)
                }
                let lyrics = try await environment.lyricsService.lyrics(for: songs)
                let prior = Dictionary(uniqueKeysWithValues: candidateWindow.occurrences.map { ($0.id, candidateWindow.confidenceModifier) })
                let ranked = environment.lyricMatchingService.rankCandidates(
                    transcripts: alternatives,
                    lyrics: lyrics,
                    occurrences: candidateWindow.occurrences,
                    context: RecognitionContext(
                        targetVideoID: record.videos[videoIndex].id,
                        videoOrder: videoIndex,
                        setlistPriorByOccurrenceID: prior
                    )
                )

                if let top = ranked.first, top.confidenceLabel != .insufficient {
                    updated[segmentIndex].primaryCandidate = top
                    updated[segmentIndex].alternativeCandidates = Array(ranked.dropFirst())
                    updated[segmentIndex].status = top.confidenceLabel == .likely ? .likely : .possible
                    updated[segmentIndex].evidence.setlistSequencePrior = candidateWindow.confidenceModifier
                    updated[segmentIndex].evidence.classificationSource = .lyrics
                    AppLog.analysis.info("Unknown segment lyric match selected video=\(videoID.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) title=\(top.song.title, privacy: .public) artist=\(top.song.artist, privacy: .public) confidence=\(top.confidenceLabel.rawValue, privacy: .public) score=\(top.evidenceScore, privacy: .public)")
                }
            } catch {
                AppLog.analysis.error("Speech transcription failed for unknown segment video=\(videoID.uuidString, privacy: .public) segment=\(updated[segmentIndex].id.uuidString, privacy: .public) range=\(Formatting.duration(updated[segmentIndex].startTime), privacy: .public)-\(Formatting.duration(updated[segmentIndex].endTime), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return updated
    }

    private func lookupSetlistFromRecognizedArtistIfNeeded(rawMatches: [RawRecognitionMatch], videoIndex: Int) async {
        if let selectedSetlist = record.selectedSetlist {
            AppLog.network.info("Skipping recognized-artist setlist lookup because setlist is already selected id=\(selectedSetlist.id, privacy: .public) occurrenceCount=\(selectedSetlist.occurrences.count, privacy: .public)")
            return
        }
        guard !rawMatches.isEmpty else {
            AppLog.network.info("Skipping recognized-artist setlist lookup because raw match list is empty video=\(self.record.videos[videoIndex].id.uuidString, privacy: .public)")
            return
        }

        let video = record.videos[videoIndex]
        guard let date = video.createdAt ?? record.videos.compactMap(\.createdAt).min() else {
            AppLog.network.info("Skipping recognized-artist setlist lookup because recording date is missing.")
            return
        }
        guard let artist = mostSupportedArtist(from: rawMatches) else {
            AppLog.network.info("Skipping recognized-artist setlist lookup because Shazam did not return a usable artist.")
            return
        }

        do {
            stage = .checkingSetlist
            record.currentStage = .checkingSetlist
            AppLog.network.info("Retrying setlist lookup with recognized artist=\(artist, privacy: .public) date=\(Formatting.dateOnly.string(from: date), privacy: .public) metadataPolicy=timestamp-only")

            let candidates = try await environment.setlistService.searchConcerts(
                artist: artist,
                date: date,
                venue: nil,
                location: nil,
                cityName: nil,
                stateCode: nil,
                countryCode: nil
            )
            AppLog.network.info("Recognized-artist setlist lookup returned \(candidates.count, privacy: .public) candidates for artist=\(artist, privacy: .public) candidates=\(self.setlistCandidateSummary(candidates), privacy: .public)")
            guard let selectedCandidate = autoSelectableCandidate(from: candidates) else {
                AppLog.network.info("Recognized-artist lookup did not auto-select because candidates were empty or ambiguous candidateCount=\(candidates.count, privacy: .public) candidates=\(self.setlistCandidateSummary(candidates), privacy: .public)")
                return
            }
            AppLog.network.info("Recognized-artist lookup auto-selected candidate id=\(selectedCandidate.id, privacy: .public) artist=\(selectedCandidate.artistName, privacy: .public) venue=\(selectedCandidate.venueName ?? "nil", privacy: .public) city=\(selectedCandidate.city ?? "nil", privacy: .public) score=\(selectedCandidate.confidenceScore, privacy: .public)")

            let setlist = try await environment.setlistService.fetchSetlist(id: selectedCandidate.id)
            record.selectedConcert = selectedCandidate
            record.selectedSetlist = setlist
            AppLog.network.info("Recognized-artist lookup selected setlist id=\(setlist.id, privacy: .public) artist=\(setlist.artistName, privacy: .public) venue=\(setlist.venueName ?? "nil", privacy: .public) songs=\(setlist.occurrences.count, privacy: .public)")
        } catch {
            AppLog.network.error("Recognized-artist setlist lookup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func mostSupportedArtist(from rawMatches: [RawRecognitionMatch]) -> String? {
        let grouped = Dictionary(grouping: rawMatches) { match in
            match.song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grouped
            .filter { !$0.key.isEmpty && $0.key.localizedCaseInsensitiveCompare("Unknown Artist") != .orderedSame }
            .max { left, right in left.value.count < right.value.count }?
            .key
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

    private func logTemporalClassificationInputs() {
        let reliableSegments = record.videos.flatMap(\.segments).filter { segment in
            [.identified, .likely, .userConfirmed].contains(segment.status) && segment.primaryCandidate != nil
        }
        let unknownSegments = record.videos.flatMap(\.segments).filter { $0.status == .unknown }
        let setlist = record.selectedSetlist
        AppLog.mediaClassification.info("Temporal classification input checkpoint record=\(self.record.id.uuidString, privacy: .public) selectedSetlistID=\(setlist?.id ?? "nil", privacy: .public) setlistOccurrenceCount=\(setlist?.occurrences.count ?? 0, privacy: .public) reliableAnchorCandidates=\(reliableSegments.count, privacy: .public) unknownVideoSegments=\(unknownSegments.count, privacy: .public) anchorTitles=\(self.anchorCandidateSummary(from: reliableSegments), privacy: .public)")
    }

    private func anchorCandidateSummary(from segments: [SongSegment]) -> String {
        let titles = segments.prefix(12).compactMap { segment -> String? in
            guard let candidate = segment.primaryCandidate else { return nil }
            return "\(candidate.song.title) by \(candidate.song.artist) occurrence=\(candidate.setlistOccurrenceID ?? "nil") status=\(segment.status.rawValue)"
        }
        let suffix = segments.count > 12 ? " ... +\(segments.count - 12) more" : ""
        return titles.joined(separator: " | ") + suffix
    }

    private func setlistCandidateSummary(_ candidates: [ConcertCandidate]) -> String {
        candidates.prefix(8).map { candidate in
            let date = candidate.eventDate.map { Formatting.dateOnly.string(from: $0) } ?? "nil"
            return "\(candidate.id):\(candidate.artistName):\(candidate.venueName ?? "nil"):\(candidate.city ?? "nil"):date=\(date):score=\(candidate.confidenceScore)"
        }
        .joined(separator: " | ")
    }

    private func makeObservations() -> [SongObservation] {
        record.videos.enumerated().flatMap { videoIndex, video in
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

    private func applyArtistConsensusFilter() {
        guard let dominantArtist = dominantArtistName() else {
            AppLog.analysis.info("Artist consensus filter skipped because no dominant artist was found.")
            return
        }

        var demotedCount = 0
        for videoIndex in record.videos.indices {
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
                AppLog.analysis.info("Artist consensus demoted weak off-artist match video=\(self.record.videos[videoIndex].id.uuidString, privacy: .public) title=\(candidate.song.title, privacy: .public) artist=\(candidate.song.artist, privacy: .public) dominantArtist=\(dominantArtist, privacy: .public)")
            }
        }

        AppLog.analysis.info("Artist consensus filter completed dominantArtist=\(dominantArtist, privacy: .public) demotedCount=\(demotedCount, privacy: .public)")
    }

    private func dominantArtistName() -> String? {
        if let artist = record.selectedSetlist?.artistName.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return artist
        }

        var weightedCounts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for segment in record.videos.flatMap(\.segments) {
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

        guard let best = weightedCounts.max(by: { $0.value < $1.value }),
              best.value >= 3 else {
            return nil
        }

        return displayNames[best.key]
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
