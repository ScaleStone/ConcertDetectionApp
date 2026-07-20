# ConcertSongFinder

ConcertSongFinder is an iOS 17 SwiftUI MVP for importing concert videos, identifying songs with ShazamKit, building multi-song timelines, preserving transition ranges, and preparing fallback setlist/lyrics/speech matching when concert audio is too distorted for fingerprinting.

This project was added beside the existing repository contents and does not modify the existing web app.

## What Is Implemented

- SwiftUI app shell with Home, Concert Setup, Analysis, and Results screens.
- Multi-video `PhotosPicker` import with app-controlled file copies.
- Metadata extraction order:
  1. `PHAsset.creationDate`
  2. `PHAsset.location`
  3. `AVAsset` creation metadata
  4. file resource creation date
- Chronological video ordering with selection-order fallback.
- AVFoundation audio extraction to temporary `.m4a` files.
- ShazamKit recognition over overlapping windows.
- Raw match preservation with window start/end, provider metadata, and processing version.
- Timeline builder with smoothing, transitions, unknown segments, repeat-song-safe identity normalization, and merge rules.
- Speech transcription service abstraction backed by Apple Speech.
- Setlist, lyrics, alignment, and lyric matching protocols with mockable implementations.
- Dynamic-programming setlist alignment that preserves duplicate `SetlistOccurrence` entries.
- Phonetic/token/character lyric fallback scorer.
- JSON analysis history and resumability state.
- Results UI with thumbnails, timelines, confidence labels, evidence summaries, alternatives, and manual correction actions.
- FastAPI backend skeleton for setlist.fm and licensed lyric-provider integration.
- XCTest coverage for core timeline, ordering, persistence, setlist alignment, and lyric matching behavior.

## iOS Project Setup

The repository includes a Swift package for the reusable core and an XcodeGen config for the iOS app project.

Requirements:

- Xcode 15 or newer with iOS 17 SDK
- XcodeGen
- An Apple developer account for running on device
- ShazamKit entitlement availability for your bundle/team
- Speech Recognition capability
- Photo Library usage permission

Generate and open the project:

```bash
cd ConcertSongFinder
xcodegen generate
open ConcertSongFinder.xcodeproj
```

Run tests from Xcode, or from the command line on a machine with a healthy Xcode toolchain:

```bash
cd ConcertSongFinder
swift test
```

## Backend Setup

```bash
cd ConcertSongFinder/backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
.venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

When running on the iOS simulator, the app defaults to `http://127.0.0.1:8000`.
When running on a physical iPhone, set `CSFBackendBaseURL` in `ConcertSongFinder/Resources/Info.plist` to the Mac's current LAN URL, for example `http://192.168.1.23:8000`.

Run backend tests:

```bash
cd ConcertSongFinder/backend
.venv/bin/python -m pytest -q
```

## Environment Variables

Backend secrets must stay on the backend and must not be copied into the iOS app.

```text
SETLIST_FM_API_KEY=
LYRICS_PROVIDER_API_KEY=
LYRICS_PROVIDER_BASE_URL=
CACHE_TTL_SECONDS=900
ALLOWED_ORIGINS=http://localhost:3000
```

`POST /api/lyrics/batch` currently returns unavailable lyric records until a licensed provider is configured. The app can still run; fallback lyric scoring simply has no lyric evidence in that state.

## Apple Permissions

The app declares:

- `NSPhotoLibraryUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `NSMicrophoneUsageDescription`

Enable these capabilities as needed in Xcode:

- Speech Recognition
- ShazamKit
- Photo Library access through PhotosPicker

## Privacy Notes

- Full videos are processed on-device.
- Temporary extracted audio is deleted after each video analysis attempt.
- The backend receives concert metadata and song identifiers only.
- Lyrics are used internally for matching and are not displayed unless a future provider license allows it.
- Analysis history can be deleted from the Results screen.

## Current Limitations

- This is a Phase 1/early Phase 2 MVP scaffold; ShazamKit and Speech behavior must be verified on a physical iPhone.
- The backend has real setlist.fm request structure but needs `SETLIST_FM_API_KEY` for production lookups.
- Licensed lyrics integration is intentionally a placeholder until provider credentials and license terms are available.
- The local machine used to create this project only has mismatched Command Line Tools, not full Xcode, so Swift build/test verification could not run here.
- `project.yml` is the source for generating `ConcertSongFinder.xcodeproj`.

## Next Phase

The next implementation task is Phase 2 hardening:

1. Generate the Xcode project with XcodeGen on a full Xcode install.
2. Fix any device-only ShazamKit/Speech compile or entitlement issues.
3. Connect a real setlist.fm API key through the backend.
4. Expand concert confirmation with multiple plausible matches and required attribution display.
5. Store alignment results and re-run unknown-video candidate windows after every user correction.
