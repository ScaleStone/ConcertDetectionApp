# Lovable Design Prompt: ConcertSongFinder

Design a beautiful, full-screen, accessible iOS app UI concept for **ConcertSongFinder**.

ConcertSongFinder is a native iOS 17 SwiftUI app that helps users import concert videos, identify songs, build timelines, recover unknown sections with fallback matching, and share clips with song labels.

## Product Goal

Create an app that feels like a personal concert archive and song-identification studio. It should feel premium, fast, nightlife-inspired, and useful for people who film concerts and later want to know exactly what songs were performed.

## Visual Direction

Use this exact palette as the core theme:

- Deep night background: `#0B0B1E`
- Elevated surface: `#1A1533`
- Stage magenta: `#E84393`
- Violet light: `#8E5CF7`
- Warm amber highlight: `#FFB454`
- Soft white text: `#F5F2FF`

The vibe should be: aftershow, venue lights, violet-dark stage, magenta energy, subtle amber confidence/status accents.

Avoid cramped layouts. Make the UI feel full-screen, modern, and accessible with generous spacing, large tap targets, Dynamic Type-friendly text, clear section hierarchy, and high contrast.

## Core User Flow

- Home screen opens directly into the user’s concert library and import action.
- User imports multiple concert videos from Photos.
- App groups imported media into likely concerts using timestamps and metadata.
- User confirms or edits concert details such as artist, venue, date, city, and setlist.
- App analyzes each video with ShazamKit over overlapping windows.
- App builds a multi-song timeline for every concert/video.
- App highlights recognized songs, unknown sections, transitions, confidence, alternatives, and evidence.
- User can manually correct songs, merge/split timeline segments, and rerun matching.
- User can browse “My Concerts” as a searchable archive.
- User can open a concert and see song tiles, video thumbnails, and detected timeline segments.
- User can share clips with optional burned-in song captions.
- User can use AI-powered “Post Ideas” for caption/post suggestions, with optional testing/debug scores.

## Main Screens To Design

### 1. My Concerts / Home

This should be the first screen, not a marketing landing page.

Include:

- A strong first-viewport identity: “ConcertSongFinder” or “My Concerts”.
- Prominent import button using a plus/upload icon.
- Search field for song, artist, venue, or concert.
- Concert cards showing artist, date, venue, number of videos, number of songs found, and status.
- Empty state for first-time users.
- Recently analyzed or in-progress concert section.
- Bottom tab bar with My Concerts, Upload, Analysis, Results/Post Ideas as appropriate.

### 2. Concert Import / Setup

Include:

- Multi-video picker state.
- Ordered list of selected videos.
- Metadata confidence indicators for date/location ordering.
- Concert candidate grouping card.
- Editable artist, venue, date, city, and optional setlist fields.
- Clear primary action: “Analyze Concert”.

### 3. Analysis

Include:

- Full-screen progress state.
- Current video being processed.
- Recognition windows visualized as a timeline.
- Status labels: extracting audio, matching with ShazamKit, transcribing speech, aligning setlist, scoring lyrics.
- Unknown segment count and confidence summary.
- Resume/cancel affordances.

### 4. Results Timeline

Include:

- Video thumbnail or preview area.
- Horizontal or vertical timeline with colored song segments.
- Transition ranges preserved visually between songs.
- Unknown segments clearly marked.
- Confidence labels: Identified, Needs Review, Unknown, Corrected.
- Evidence summary for each segment: Shazam match, setlist alignment, lyric match, speech cue, timestamp anchor.
- Alternative candidate list.
- Manual correction actions: edit song, merge, split, mark unknown, rerun match.

### 5. Song Clip Library

Include:

- One tile per detected song segment.
- Thumbnail, song title, artist, time range, confidence, source video.
- Search and filter by status.
- Repeat-song-safe display, so duplicate songs in the setlist appear as separate occurrences.

### 6. Share / Export

Include:

- Clip preview.
- Toggle for burned-in song caption.
- Caption style selection.
- Share button.
- Privacy note that full videos stay on-device.

### 7. Post Ideas

Include:

- Consent-gated AI suggestions.
- Suggested social captions grouped by tone.
- Candidate scoring debug mode for testing, with visible per-candidate score/reasoning when enabled.
- Make it feel like a utility for concert posting, not a generic AI chat.

## Important Features To Represent

- Multi-video Photos import.
- Chronological ordering with selection-order fallback.
- ShazamKit song recognition across overlapping windows.
- Raw match preservation with timestamps and provider metadata.
- Timeline smoothing with transitions, unknown sections, and duplicate-safe song identity.
- Speech transcription fallback.
- Setlist alignment fallback.
- Lyric matching fallback.
- JSON history and resumability.
- Backend integration for setlist.fm and licensed lyrics providers.
- Privacy: full videos processed on-device; backend receives concert metadata and song IDs only.
- Delete analysis history from Results.

## Accessibility Requirements

- Full-screen iPhone layout.
- Large touch targets.
- Dynamic Type-friendly sizing.
- No tiny cramped cards.
- Avoid text overlap at small widths.
- Clear contrast on dark backgrounds.
- Important status should use both color and text labels.
- Timeline segments should be readable for color-blind users.

## Design Style

Use native iOS patterns and SwiftUI-friendly components:

- Bottom tab bar.
- Navigation stack headers.
- Sheets for correction/share flows.
- Segmented controls for filters and modes.
- Toggles for AI debug mode and burned-in captions.
- Sliders or steppers only where numeric controls make sense.
- Icon buttons for import, share, delete, edit, search, filter, play, pause, and rerun.

The final design should look like a polished iOS MVP, not a web landing page.

## Output Request

Create multiple possible app design directions for ConcertSongFinder using the palette above. For each direction, show the main Home/My Concerts screen plus a Results Timeline screen. Prioritize usability, accessibility, and a premium concert-night feel.
