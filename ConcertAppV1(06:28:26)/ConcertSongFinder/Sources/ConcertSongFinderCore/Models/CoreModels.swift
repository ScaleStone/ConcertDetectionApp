import Foundation

public struct ConcertVideo: Identifiable, Codable, Hashable {
    public let id: UUID
    public let localIdentifier: String?
    public let localURL: URL
    public let fileName: String
    public let createdAt: Date?
    public let duration: TimeInterval
    public let location: VideoLocation?
    public var originalSelectionIndex: Int
    public var analysisStatus: AnalysisStatus
    public var segments: [SongSegment]

    public init(
        id: UUID = UUID(),
        localIdentifier: String?,
        localURL: URL,
        fileName: String,
        createdAt: Date?,
        duration: TimeInterval,
        location: VideoLocation?,
        originalSelectionIndex: Int = 0,
        analysisStatus: AnalysisStatus = .imported,
        segments: [SongSegment] = []
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.localURL = localURL
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.location = location
        self.originalSelectionIndex = originalSelectionIndex
        self.analysisStatus = analysisStatus
        self.segments = segments
    }
}

public struct ConcertPhoto: Identifiable, Codable, Hashable {
    public let id: UUID
    public let localIdentifier: String?
    public let localURL: URL
    public let fileName: String
    public let createdAt: Date?
    public let location: VideoLocation?
    public var originalSelectionIndex: Int
    public var classificationStatus: SegmentStatus
    public var primaryCandidate: SongCandidate?
    public var alternativeCandidates: [SongCandidate]
    public var evidence: RecognitionEvidence
    public var assignedVideoID: UUID?
    public var assignedSegmentID: UUID?
    public var concertTiming: PhotoConcertTiming?

    public init(
        id: UUID = UUID(),
        localIdentifier: String?,
        localURL: URL,
        fileName: String,
        createdAt: Date?,
        location: VideoLocation?,
        originalSelectionIndex: Int = 0,
        classificationStatus: SegmentStatus = .unknown,
        primaryCandidate: SongCandidate? = nil,
        alternativeCandidates: [SongCandidate] = [],
        evidence: RecognitionEvidence = RecognitionEvidence(),
        assignedVideoID: UUID? = nil,
        assignedSegmentID: UUID? = nil,
        concertTiming: PhotoConcertTiming? = nil
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.localURL = localURL
        self.fileName = fileName
        self.createdAt = createdAt
        self.location = location
        self.originalSelectionIndex = originalSelectionIndex
        self.classificationStatus = classificationStatus
        self.primaryCandidate = primaryCandidate
        self.alternativeCandidates = alternativeCandidates
        self.evidence = evidence
        self.assignedVideoID = assignedVideoID
        self.assignedSegmentID = assignedSegmentID
        self.concertTiming = concertTiming
    }
}

public struct ConcertMediaImport: Codable, Hashable {
    public let videos: [ConcertVideo]
    public let photos: [ConcertPhoto]

    public init(videos: [ConcertVideo], photos: [ConcertPhoto] = []) {
        self.videos = videos
        self.photos = photos
    }

    public var isEmpty: Bool {
        videos.isEmpty && photos.isEmpty
    }
}

public struct VideoLocation: Codable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum AnalysisStatus: String, Codable, Hashable {
    case imported
    case metadataReady
    case queued
    case extractingAudio
    case recognizing
    case buildingTimeline
    case checkingSetlist
    case transcribing
    case matchingLyrics
    case completed
    case failed
    case canceled
}

public enum RecognitionStage: String, Codable, Hashable, CaseIterable {
    case idle
    case extractingAudio = "Extracting audio"
    case checkingShazam = "Checking Shazam"
    case buildingTimeline = "Building timeline"
    case checkingSetlist = "Checking setlist"
    case transcribing = "Transcribing unclear audio"
    case comparingLyrics = "Comparing lyrics"
    case completed = "Completed"
    case canceled = "Canceled"
}

public struct SongIdentity: Identifiable, Codable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public let isrc: String?

    public init(id: String, title: String, artist: String, album: String? = nil, isrc: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.isrc = isrc
    }
}

public struct SongSegment: Identifiable, Codable, Hashable {
    public let id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var status: SegmentStatus
    public var primaryCandidate: SongCandidate?
    public var alternativeCandidates: [SongCandidate]
    public var evidence: RecognitionEvidence

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        status: SegmentStatus,
        primaryCandidate: SongCandidate?,
        alternativeCandidates: [SongCandidate] = [],
        evidence: RecognitionEvidence = RecognitionEvidence()
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.primaryCandidate = primaryCandidate
        self.alternativeCandidates = alternativeCandidates
        self.evidence = evidence
    }
}

public enum SegmentStatus: String, Codable, Hashable {
    case identified
    case likely
    case possible
    case transition
    case speech
    case unknown
    case userConfirmed
}

public enum PhotoConcertTiming: String, Codable, Hashable {
    case beforeConcert
    case duringConcert
    case afterConcert
    case unknown
}

public struct SongCandidate: Identifiable, Codable, Hashable {
    public let id: UUID
    public let song: SongIdentity
    public let setlistOccurrenceID: String?
    public let evidenceScore: Double
    public let confidenceLabel: ConfidenceLabel
    public let reasons: [String]

    public init(
        id: UUID = UUID(),
        song: SongIdentity,
        setlistOccurrenceID: String?,
        evidenceScore: Double,
        confidenceLabel: ConfidenceLabel,
        reasons: [String]
    ) {
        self.id = id
        self.song = song
        self.setlistOccurrenceID = setlistOccurrenceID
        self.evidenceScore = evidenceScore
        self.confidenceLabel = confidenceLabel
        self.reasons = reasons
    }
}

public enum ConfidenceLabel: String, Codable, Hashable {
    case strong
    case likely
    case possible
    case insufficient
}

public enum ClassificationSource: String, Codable, Hashable {
    case shazamKit
    case temporalPositioning
    case lyrics
    case userCorrection
}

public struct RecognitionEvidence: Codable, Hashable {
    public var shazamWindowCount: Int
    public var shazamMatchedDuration: TimeInterval
    public var speechAlternatives: [String]
    public var phoneticSimilarity: Double?
    public var tokenSimilarity: Double?
    public var characterSimilarity: Double?
    public var setlistSequencePrior: Double?
    public var neighboringVideoSupport: Double?
    public var boundedCandidateOptions: [SongCandidate]
    public var classificationSource: ClassificationSource?
    public var isUserConfirmed: Bool

    public init(
        shazamWindowCount: Int = 0,
        shazamMatchedDuration: TimeInterval = 0,
        speechAlternatives: [String] = [],
        phoneticSimilarity: Double? = nil,
        tokenSimilarity: Double? = nil,
        characterSimilarity: Double? = nil,
        setlistSequencePrior: Double? = nil,
        neighboringVideoSupport: Double? = nil,
        boundedCandidateOptions: [SongCandidate] = [],
        classificationSource: ClassificationSource? = nil,
        isUserConfirmed: Bool = false
    ) {
        self.shazamWindowCount = shazamWindowCount
        self.shazamMatchedDuration = shazamMatchedDuration
        self.speechAlternatives = speechAlternatives
        self.phoneticSimilarity = phoneticSimilarity
        self.tokenSimilarity = tokenSimilarity
        self.characterSimilarity = characterSimilarity
        self.setlistSequencePrior = setlistSequencePrior
        self.neighboringVideoSupport = neighboringVideoSupport
        self.boundedCandidateOptions = boundedCandidateOptions
        self.classificationSource = classificationSource
        self.isUserConfirmed = isUserConfirmed
    }

    private enum CodingKeys: String, CodingKey {
        case shazamWindowCount
        case shazamMatchedDuration
        case speechAlternatives
        case phoneticSimilarity
        case tokenSimilarity
        case characterSimilarity
        case setlistSequencePrior
        case neighboringVideoSupport
        case boundedCandidateOptions
        case classificationSource
        case isUserConfirmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shazamWindowCount = try container.decodeIfPresent(Int.self, forKey: .shazamWindowCount) ?? 0
        shazamMatchedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .shazamMatchedDuration) ?? 0
        speechAlternatives = try container.decodeIfPresent([String].self, forKey: .speechAlternatives) ?? []
        phoneticSimilarity = try container.decodeIfPresent(Double.self, forKey: .phoneticSimilarity)
        tokenSimilarity = try container.decodeIfPresent(Double.self, forKey: .tokenSimilarity)
        characterSimilarity = try container.decodeIfPresent(Double.self, forKey: .characterSimilarity)
        setlistSequencePrior = try container.decodeIfPresent(Double.self, forKey: .setlistSequencePrior)
        neighboringVideoSupport = try container.decodeIfPresent(Double.self, forKey: .neighboringVideoSupport)
        boundedCandidateOptions = try container.decodeIfPresent([SongCandidate].self, forKey: .boundedCandidateOptions) ?? []
        classificationSource = try container.decodeIfPresent(ClassificationSource.self, forKey: .classificationSource)
        isUserConfirmed = try container.decodeIfPresent(Bool.self, forKey: .isUserConfirmed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shazamWindowCount, forKey: .shazamWindowCount)
        try container.encode(shazamMatchedDuration, forKey: .shazamMatchedDuration)
        try container.encode(speechAlternatives, forKey: .speechAlternatives)
        try container.encodeIfPresent(phoneticSimilarity, forKey: .phoneticSimilarity)
        try container.encodeIfPresent(tokenSimilarity, forKey: .tokenSimilarity)
        try container.encodeIfPresent(characterSimilarity, forKey: .characterSimilarity)
        try container.encodeIfPresent(setlistSequencePrior, forKey: .setlistSequencePrior)
        try container.encodeIfPresent(neighboringVideoSupport, forKey: .neighboringVideoSupport)
        try container.encode(boundedCandidateOptions, forKey: .boundedCandidateOptions)
        try container.encodeIfPresent(classificationSource, forKey: .classificationSource)
        try container.encode(isUserConfirmed, forKey: .isUserConfirmed)
    }
}

public struct SetlistOccurrence: Identifiable, Codable, Hashable {
    public let id: String
    public let setlistID: String
    public let setNumber: Int
    public let songIndex: Int
    public let overallIndex: Int
    public let title: String
    public let normalizedTitle: String
    public let artist: String
    public let setName: String?
    public let isEncore: Bool
    public let isTape: Bool
    public let notes: String?

    public init(
        id: String,
        setlistID: String,
        setNumber: Int,
        songIndex: Int,
        overallIndex: Int,
        title: String,
        normalizedTitle: String,
        artist: String,
        setName: String? = nil,
        isEncore: Bool = false,
        isTape: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.setlistID = setlistID
        self.setNumber = setNumber
        self.songIndex = songIndex
        self.overallIndex = overallIndex
        self.title = title
        self.normalizedTitle = normalizedTitle
        self.artist = artist
        self.setName = setName
        self.isEncore = isEncore
        self.isTape = isTape
        self.notes = notes
    }
}

public struct ConcertCandidate: Identifiable, Codable, Hashable {
    public let id: String
    public let artistName: String
    public let venueName: String?
    public let city: String?
    public let eventDate: Date?
    public let confidenceScore: Double
    public let attributionURL: URL?

    public init(
        id: String,
        artistName: String,
        venueName: String?,
        city: String?,
        eventDate: Date?,
        confidenceScore: Double,
        attributionURL: URL?
    ) {
        self.id = id
        self.artistName = artistName
        self.venueName = venueName
        self.city = city
        self.eventDate = eventDate
        self.confidenceScore = confidenceScore
        self.attributionURL = attributionURL
    }
}

public struct ConcertSetlist: Identifiable, Codable, Hashable {
    public let id: String
    public let artistName: String
    public let venueName: String?
    public let eventDate: Date?
    public let occurrences: [SetlistOccurrence]
    public let attributionURL: URL?
    public let versionID: String

    public init(
        id: String,
        artistName: String,
        venueName: String?,
        eventDate: Date?,
        occurrences: [SetlistOccurrence],
        attributionURL: URL?,
        versionID: String
    ) {
        self.id = id
        self.artistName = artistName
        self.venueName = venueName
        self.eventDate = eventDate
        self.occurrences = occurrences
        self.attributionURL = attributionURL
        self.versionID = versionID
    }
}

public struct PreparedAudio: Codable, Hashable {
    public let audioURL: URL
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
    public let sourceVideoID: UUID
    public let temporaryFiles: [URL]

    public init(
        audioURL: URL,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        sourceVideoID: UUID,
        temporaryFiles: [URL] = []
    ) {
        self.audioURL = audioURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sourceVideoID = sourceVideoID
        self.temporaryFiles = temporaryFiles
    }
}

public struct RecognitionConfiguration: Codable, Hashable {
    public var windowLength: TimeInterval
    public var stepSize: TimeInterval
    public var refinedWindowLength: TimeInterval
    public var refinedStepSize: TimeInterval
    public var minimumSupportingWindowsForChange: Int
    public var minimumStrongMatchedDuration: TimeInterval
    public var mergeUnknownGapThreshold: TimeInterval
    public var processingVersion: String

    public init(
        windowLength: TimeInterval = 10,
        stepSize: TimeInterval = 5,
        refinedWindowLength: TimeInterval = 8,
        refinedStepSize: TimeInterval = 2,
        minimumSupportingWindowsForChange: Int = 2,
        minimumStrongMatchedDuration: TimeInterval = 12,
        mergeUnknownGapThreshold: TimeInterval = 3,
        processingVersion: String = "mvp-1"
    ) {
        self.windowLength = windowLength
        self.stepSize = stepSize
        self.refinedWindowLength = refinedWindowLength
        self.refinedStepSize = refinedStepSize
        self.minimumSupportingWindowsForChange = minimumSupportingWindowsForChange
        self.minimumStrongMatchedDuration = minimumStrongMatchedDuration
        self.mergeUnknownGapThreshold = mergeUnknownGapThreshold
        self.processingVersion = processingVersion
    }

    public static let `default` = RecognitionConfiguration()
}

public struct RawRecognitionMatch: Identifiable, Codable, Hashable {
    public let id: UUID
    public let windowStart: TimeInterval
    public let windowEnd: TimeInterval
    public let song: SongIdentity
    public let matchOffset: TimeInterval?
    public let providerIdentifier: String
    public let metadata: [String: String]
    public let processingVersion: String
    public let strength: Double

    public init(
        id: UUID = UUID(),
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        song: SongIdentity,
        matchOffset: TimeInterval? = nil,
        providerIdentifier: String = "shazam",
        metadata: [String: String] = [:],
        processingVersion: String = RecognitionConfiguration.default.processingVersion,
        strength: Double = 1
    ) {
        self.id = id
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.song = song
        self.matchOffset = matchOffset
        self.providerIdentifier = providerIdentifier
        self.metadata = metadata
        self.processingVersion = processingVersion
        self.strength = strength
    }
}

public struct TranscriptAlternative: Identifiable, Codable, Hashable {
    public let id: UUID
    public let text: String
    public let confidence: Double?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let languageCode: String?
    public let wordConfidences: [String: Double]

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        languageCode: String? = nil,
        wordConfidences: [String: Double] = [:]
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.startTime = startTime
        self.endTime = endTime
        self.languageCode = languageCode
        self.wordConfidences = wordConfidences
    }
}

public struct SongLyrics: Identifiable, Codable, Hashable {
    public let id: UUID
    public let song: SongIdentity
    public let lyrics: String?
    public let languageCode: String?
    public let providerAttribution: String?
    public let canDisplay: Bool

    public init(
        id: UUID = UUID(),
        song: SongIdentity,
        lyrics: String?,
        languageCode: String? = nil,
        providerAttribution: String? = nil,
        canDisplay: Bool = false
    ) {
        self.id = id
        self.song = song
        self.lyrics = lyrics
        self.languageCode = languageCode
        self.providerAttribution = providerAttribution
        self.canDisplay = canDisplay
    }
}

public struct RecognitionContext: Codable, Hashable {
    public let targetVideoID: UUID?
    public let videoOrder: Int?
    public let setlistPriorByOccurrenceID: [String: Double]
    public let neighboringSupportByOccurrenceID: [String: Double]
    public let localeIdentifier: String?

    public init(
        targetVideoID: UUID? = nil,
        videoOrder: Int? = nil,
        setlistPriorByOccurrenceID: [String: Double] = [:],
        neighboringSupportByOccurrenceID: [String: Double] = [:],
        localeIdentifier: String? = nil
    ) {
        self.targetVideoID = targetVideoID
        self.videoOrder = videoOrder
        self.setlistPriorByOccurrenceID = setlistPriorByOccurrenceID
        self.neighboringSupportByOccurrenceID = neighboringSupportByOccurrenceID
        self.localeIdentifier = localeIdentifier
    }
}

public struct SongObservation: Identifiable, Codable, Hashable {
    public let id: UUID
    public let videoID: UUID
    public let segmentID: UUID
    public let videoOrder: Int
    public let segmentStart: TimeInterval
    public let segmentEnd: TimeInterval
    public let song: SongIdentity
    public let confidenceLabel: ConfidenceLabel
    public let isUserConfirmed: Bool

    public init(
        id: UUID = UUID(),
        videoID: UUID,
        segmentID: UUID,
        videoOrder: Int,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        song: SongIdentity,
        confidenceLabel: ConfidenceLabel,
        isUserConfirmed: Bool = false
    ) {
        self.id = id
        self.videoID = videoID
        self.segmentID = segmentID
        self.videoOrder = videoOrder
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.song = song
        self.confidenceLabel = confidenceLabel
        self.isUserConfirmed = isUserConfirmed
    }
}

public struct ObservationAlignment: Identifiable, Codable, Hashable {
    public var id: UUID { observationID }
    public let observationID: UUID
    public let occurrenceID: String
    public let occurrenceOverallIndex: Int
    public let score: Double
    public let ambiguousOccurrenceIDs: [String]

    public init(
        observationID: UUID,
        occurrenceID: String,
        occurrenceOverallIndex: Int,
        score: Double,
        ambiguousOccurrenceIDs: [String] = []
    ) {
        self.observationID = observationID
        self.occurrenceID = occurrenceID
        self.occurrenceOverallIndex = occurrenceOverallIndex
        self.score = score
        self.ambiguousOccurrenceIDs = ambiguousOccurrenceIDs
    }
}

public struct SetlistAlignment: Codable, Hashable {
    public let mappings: [ObservationAlignment]
    public let unresolvedObservationIDs: [UUID]
    public let totalScore: Double
    public let isAmbiguous: Bool

    public init(
        mappings: [ObservationAlignment],
        unresolvedObservationIDs: [UUID],
        totalScore: Double,
        isAmbiguous: Bool
    ) {
        self.mappings = mappings
        self.unresolvedObservationIDs = unresolvedObservationIDs
        self.totalScore = totalScore
        self.isAmbiguous = isAmbiguous
    }
}

public struct CandidateSetlistWindow: Codable, Hashable {
    public let occurrences: [SetlistOccurrence]
    public let reason: String
    public let confidenceModifier: Double

    public init(occurrences: [SetlistOccurrence], reason: String, confidenceModifier: Double) {
        self.occurrences = occurrences
        self.reason = reason
        self.confidenceModifier = confidenceModifier
    }
}
