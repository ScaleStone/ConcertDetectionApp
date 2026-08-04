# Bugfix Requirements Document

## Introduction

When a user imports a single batch of videos and photos that spans multiple different concerts, the ConcertSongFinder app fails to separate the media into distinct concerts. The entire batch is treated as one analysis unit: a single AnalysisRecord is created, the first successful recognized-artist setlist lookup labels the whole record, and everything is persisted as one ConcertRecord in My Concerts. There is no timestamp-based clustering anywhere in the pipeline, even though media timestamps are the only grouping metadata available (GPS is intentionally ignored by the import service).

The correct behavior is to run a recognition (Shazam) pass over all videos first, then group all imported media into concert clusters by timestamp (media taken close together in time belong to the same concert; large gaps indicate different concerts), then attempt to identify each cluster's concert independently. Crucially, cluster separation must be driven by timestamps alone: a failure to identify a concert for a cluster must never cause clusters to collapse together, and multiple recognized artists within one timestamp cluster (an opener plus a headliner on the same evening) must never split that cluster into multiple concerts.

The bug condition C(X): a single import batch X contains media whose timestamps form more than one temporal cluster, and the app produces fewer concert entries than temporal clusters (distinct concerts are merged into one record). Single-concert batches (the common case) are unaffected and must continue to behave exactly as they do today.

## Bug Analysis

### Current Behavior (Defect)

When an import batch spans multiple concerts, the app collapses everything into a single concert.

1.1 WHEN a user imports a batch of videos and photos whose timestamps form more than one temporal cluster THEN the system creates a single AnalysisRecord containing all media from all concerts

1.2 WHEN analysis runs on a multi-concert batch THEN the system sets the first successfully auto-selected recognized-artist setlist as the setlist for the entire record, mislabeling media that belongs to other concerts

1.3 WHEN analysis of a multi-concert batch completes THEN the system persists all media as one ConcertRecord in My Concerts, producing fewer concert entries than temporal clusters

1.4 WHEN concert identification fails for media from one of the concerts in a multi-concert batch THEN the system leaves that media merged into the single record instead of separating it into its own concert entry

### Expected Behavior (Correct)

Media from a multi-concert batch must be separated into one concert per temporal cluster, with identification attempted per cluster and separation guaranteed even when identification fails.

2.1 WHEN videos are uploaded THEN the system SHALL first run a recognition (Shazam) pass over all videos in the batch before performing any setlist lookups

2.2 WHEN the recognition pass completes THEN the system SHALL group the batch's videos and photos into concert clusters by timestamp, placing consecutive media items in the same cluster when the time gap between them is within a tunable same-evening threshold (default approximately 6 hours) and starting a new cluster when the gap exceeds it

2.3 WHEN concert clusters have been formed THEN the system SHALL attempt to identify each cluster's concert independently, using the cluster's recognized artists and the cluster's date to search for a setlist and label the concert with artist, venue, and date

2.4 WHEN multiple different artists are recognized within a single timestamp cluster THEN the system SHALL treat the cluster as one concert (opener plus headliner), and SHALL NOT split the cluster based on artist differences alone

2.5 WHEN identifying a cluster that contains multiple recognized artists THEN the system SHALL attempt identification using the headliner (typically the artist with the most recognized songs or appearing later in the evening) and SHALL fall back to the other recognized artists' setlists if the headliner lookup fails, labeling the concert with the headliner

2.6 WHEN a setlist cannot be found or a concert cannot be identified for a cluster THEN the system SHALL still create a distinct concert entry for that cluster, labeled with a fallback of the recognized artist plus date, or the date alone if no artist was recognized

2.7 WHEN analysis of a multi-concert batch completes THEN the system SHALL persist one concert entry per temporal cluster in My Concerts, so the number of concert entries equals the number of temporal clusters in the batch

### Unchanged Behavior (Regression Prevention)

Single-concert batches are the common case and the entire existing flow around them must be preserved.

3.1 WHEN a user imports a batch whose media timestamps form a single temporal cluster THEN the system SHALL CONTINUE TO produce exactly one concert entry from that batch using the existing identification flow

3.2 WHEN a video is analyzed THEN the system SHALL CONTINUE TO run the existing per-video pipeline (audio extraction, Shazam recognition, timeline building, and speech/lyrics fallback for unknown segments) and produce the same segment results

3.3 WHEN a completed analysis matches an existing concert in the library by normalized artist and calendar day THEN the system SHALL CONTINUE TO merge the analysis into that existing ConcertRecord rather than creating a duplicate

3.4 WHEN a user makes corrections to recognized songs or re-runs analysis on a concert THEN the system SHALL CONTINUE TO support user corrections and incremental re-analysis (previously completed videos are skipped and updated media replaces older copies on merge)

3.5 WHEN analysis progresses or completes THEN the system SHALL CONTINUE TO persist analysis history through the history store as it does today

3.6 WHEN media is imported THEN the system SHALL CONTINUE TO import with createdAt timestamps (PHAsset, then embedded metadata, then file date fallback) and sort media chronologically
