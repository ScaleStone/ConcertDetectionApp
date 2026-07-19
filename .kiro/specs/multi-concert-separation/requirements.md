# Bugfix Requirements: Multi-Concert Media Separation

## Bug Report

**Current (broken) behavior:**
When a user uploads media (videos and photos) spanning multiple concerts in a
single batch, the app treats the entire batch as ONE concert. All media lands
in a single `AnalysisRecord`, flows through one analysis pass, and persists as
a single `ConcertRecord` in My Concerts. There is no mechanism to split a
batch into separate concerts, and a failed setlist/concert lookup leaves the
whole batch as one unlabeled blob.

**Expected behavior:**
A mixed batch is automatically separated into distinct concerts. Separation is
driven primarily by media timestamps and must succeed even when concert or
setlist identification fails.

## Corrected Workflow (as specified by user)

1. When videos are uploaded, the FIRST processing step is a Shazam
   recognition pass over the uploaded videos.
2. After the Shazam pass, ALL media (videos and photos) is grouped into
   concert clusters by timestamp.
3. For each cluster, the app attempts to find the concert and setlist
   (setlist.fm via backend) and labels the cluster accordingly.
4. If a setlist or concert cannot be found for a cluster, the cluster STILL
   remains a separate concert, labeled with whatever is known (recognized
   artist and/or date).

## Acceptance Criteria

### Requirement 1 — Shazam-first pipeline order
WHEN a batch of media is submitted for analysis
THEN the system SHALL run Shazam recognition on every video in the batch
BEFORE performing any concert/setlist lookups or concert assignment.

### Requirement 2 — Timestamp clustering
WHEN the Shazam pass completes
THEN the system SHALL group all videos and photos into clusters using their
creation timestamps, where consecutive items separated by more than a gap
threshold (default: 6 hours) belong to different clusters.

2.1 WHEN two media items are separated by less than the gap threshold but
    cross midnight (e.g. a concert running 11 PM into 1 AM) THEN they SHALL
    remain in the SAME cluster; the gap threshold is the sole split signal so
    late-night shows are not incorrectly split at midnight.
2.2 WHEN a media item has no timestamp THEN it SHALL be placed in a separate
    "undated" cluster rather than being silently merged into a dated cluster.
2.3 WHEN Shazam recognized different dominant artists for same-day videos
    with a clear separation in time THEN the artist signal MAY be used as a
    secondary split signal, but timestamp SHALL remain the primary signal.

### Requirement 3 — Per-cluster concert identification
WHEN clusters have been formed
THEN the system SHALL attempt concert/setlist identification independently
for each cluster, using that cluster's dominant recognized artist and the
cluster's date.

3.1 WHEN identification succeeds for a cluster THEN the cluster SHALL be
    labeled with the concert's artist, venue, and date.
3.2 WHEN identification fails for a cluster THEN the cluster SHALL still be
    persisted as its own concert, labeled with the recognized artist and/or
    cluster date (e.g. "Don Toliver — Jun 24, 2026" or "Concert — Jun 24,
    2026").
3.3 IF identification fails for every cluster THEN the clusters SHALL still
    be persisted as separate concerts (identification failure never collapses
    clusters).

### Requirement 4 — Per-cluster persistence and display
WHEN analysis completes (or is cancelled partway)
THEN each cluster SHALL be persisted as its own ConcertRecord in the concert
library, and My Concerts SHALL display one entry per cluster.

4.1 WHEN a cluster matches an existing concert in the library (same artist +
    same calendar day) THEN it SHALL merge into that existing concert instead
    of creating a duplicate.
4.2 WHEN the user views Results after a multi-cluster analysis THEN the
    results SHALL be presented grouped by concert cluster.

### Requirement 5 — Existing single-concert behavior preserved
WHEN a batch contains media from only one concert (one cluster)
THEN the pipeline SHALL behave as it does today: one analysis, one concert
entry, per-video timelines, and the existing fallback chain (speech →
setlist alignment → lyric matching).

## Constraints

- All code changes are local to this repository (iOS app in
  `ConcertSongFinder/`, core library in `Sources/ConcertSongFinderCore/`,
  backend in `backend/`). No Amazon-internal tooling or systems.
- Timestamp clustering logic SHALL live in the core library
  (`ConcertSongFinderCore`) so it is unit-testable with `swift test` /
  XCTest.
- The photo library metadata policy is unchanged: timestamps only, GPS
  ignored.

## Out of Scope

- Fixing the timeline builder stretch behavior (deferred critical #3 from the
  earlier review).
- Lyrics provider integration.
- Manual re-assignment UI for moving media between clusters (future work).
