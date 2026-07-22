# ConcertSongFinder Privacy Policy

**Last updated: July 21, 2026**

ConcertSongFinder ("the app") helps you organize concert videos and photos by
identifying the songs playing in them. This policy explains what information
the app handles and where it goes.

## The short version

Your videos and photos never leave your device. The app sends only minimal
song and concert metadata (like an artist name and a date) to look up concert
setlists. We do not run analytics, advertising, or tracking of any kind, and
we do not sell or share data with anyone.

## What stays on your device

- **Your videos and photos.** All media you select is copied into the app's
  private storage on your device and processed there. Media files are never
  uploaded anywhere.
- **Audio analysis.** Song recognition works by generating short acoustic
  fingerprints from your videos' audio on-device.
- **Your concert library.** Organized concerts, song timelines, and your
  corrections are stored locally on your device and can be deleted at any
  time by deleting the concert or the app.

## What leaves your device

1. **Apple ShazamKit.** Acoustic fingerprints (not the audio itself) are
   matched against Apple's song catalog using Apple's ShazamKit service.
   This is governed by [Apple's privacy policy](https://www.apple.com/legal/privacy/).
2. **Apple Speech Recognition.** For unclear audio segments, short audio
   clips may be transcribed using Apple's speech recognition service, subject
   to Apple's privacy policy. The app asks your permission before using it.
3. **Concert lookups.** To find a concert's setlist, the app sends the
   recognized artist name and the recording date to our lookup service,
   which queries [setlist.fm](https://www.setlist.fm). No media, transcripts,
   photos, precise location, or personal identifiers are included in these
   requests.

## What we collect

Nothing. Our lookup service does not store user accounts, device identifiers,
or request histories beyond short-lived operational caches. There are no
third-party analytics or advertising SDKs in the app.

## Permissions the app requests

- **Photo library** — so you can select concert videos and photos to import.
- **Speech recognition** — to transcribe unclear audio segments for song
  matching. Optional; recognition still works without it.

## Data retention and deletion

Everything the app creates lives on your device. Deleting a concert removes
its media copies from app storage, and deleting the app removes everything.

## Children

The app is not directed at children under 13 and does not knowingly collect
personal information from anyone.

## Changes

If this policy changes, the updated version will be posted at this address
with a new "last updated" date.

## Contact

Questions? Open an issue at
[github.com/ScaleStone/ConcertDetectionApp](https://github.com/ScaleStone/ConcertDetectionApp/issues).
