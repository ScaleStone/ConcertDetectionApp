# Design: Multi-Concert Media Separation

## Pipeline restructure (AnalysisViewModel.analyze)

Old: per-video [extract → Shazam → (setlist lookup mid-loop) → timeline → fallback]
New, phased:

1. **Shazam pass** — for every video: extract audio → Shazam windows → store
   raw matches. Prepared audio is retained (temp files deleted at the very
   end) so the fallback phase doesn't re-extract.
2. **Clustering** — `ConcertClusterer.cluster(videos:photos:)` groups all
   media by timestamp (gap > 6h ⇒ new cluster; undated media ⇒ separate
   undated cluster). Stored on the record as `clusters:
   [ConcertClusterAssignment]`. A manually pre-selected concert (setup flow)
   is assigned to the cluster(s) matching its event day.
3. **Per-cluster identification** — for each cluster without a setlist:
   rank recognized artists (distinct songs desc, later-evening videos win
   ties ⇒ headliner preference), try up to 3 artists against
   `searchConcerts(artist:date:)`, auto-select + fetch setlist. On failure the
   cluster keeps a fallback label ("Artist — date" / "Concert — date" /
   "Undated media"). Failure never merges clusters.
4. **Timeline + fallback** — per video as before, but setlist context and
   alignment observations are scoped to the video's cluster.
5. **Consensus + media classification** — artist-consensus filter and photo
   classification run per cluster (sub-record in, results written back).

## Data model

- `ConcertClusterAssignment` (core, Codable): id, videoIDs, photoIDs,
  clusterDate, isUndated, selectedConcert, selectedSetlist, fallbackLabel.
- `AnalysisRecord` gains `clusters` + `fallbackTitle` (backward-compatible
  decodeIfPresent) and `perClusterAnalysisRecords()` which splits a
  multi-cluster record into per-cluster sub-records (cluster.id becomes the
  sub-record id). Single-cluster records return `[self]` — preserving
  today's behavior exactly.
- `ConcertRecord` gains `fallbackTitle`; `displayTitle` falls back to it
  before "Untitled Concert".

## Persistence & UI

- `RootView.persistCompletedConcert` iterates
  `record.perClusterAnalysisRecords()` and upserts/merges one ConcertRecord
  per cluster (existing artist+day matching preserved).
- `ResultsView` groups videos/photos by cluster with a header per concert
  when there is more than one cluster; single-cluster layout unchanged.
- `ResultsViewModel.deleteHistory`/`syncConcertLibrary` operate per cluster.

## Testing

- New `ClusteringTests` (core, XCTest via `swift test`): gap split, midnight
  crossing stays together, undated separation, photo/video co-clustering,
  per-cluster record splitting, fallback titles.
