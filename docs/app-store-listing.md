# App Store Listing Copy

Paste-ready content for App Store Connect.

## Name (30 chars max)

Primary: `ConcertSongFinder`
If taken, alternates:
- `SetFinder — Concert Videos`
- `Encore: Concert Organizer`

## Subtitle (30 chars max)

`Sort concert clips by song`

## Category

Primary: Music
Secondary: Photo & Video

## Description

Turn your camera roll's concert chaos into an organized memory library.

ConcertSongFinder identifies the songs playing in your concert videos and
organizes everything — videos and photos — by song, by show, automatically.

HOW IT WORKS
• Select your concert videos and photos — that's the only step
• Songs are identified from the audio, right on your device
• The show's setlist is found and matched automatically
• Multiple concerts in one upload? They're separated for you

YOUR CONCERT LIBRARY
• Every show becomes a browsable library of labeled moments
• Thumbnails tagged with song names — find "that one song" instantly
• Search any concert by song name
• Photos are placed on the setlist timeline between identified songs

SHARE THE MOMENT
• Share any clip or photo with the song name included
• Optional caption overlay that survives Instagram and TikTok
• Song and artist embedded in the file's metadata

PRIVATE BY DESIGN
• Your videos and photos never leave your device
• Only minimal song metadata is used for setlist lookups
• No accounts, no ads, no tracking

Concert data from setlist.fm.

## Keywords (100 chars max)

`concert,setlist,song,identify,music,live,video,organizer,shazam,festival,clips,share`

## URLs

- Support URL: https://scalestone.github.io/ConcertDetectionApp/support
- Marketing URL (optional): repository page
- Privacy Policy URL: https://scalestone.github.io/ConcertDetectionApp/privacy-policy

(URLs assume GitHub Pages is enabled for the repo's /docs folder — see
checklist below. Adjust if you host elsewhere.)

## Age rating

All questionnaire answers "No" → expected rating 4+.

## App Privacy (App Store Connect questionnaire)

- Data collection: select **"Data is not collected"** — media stays
  on-device; setlist lookups send artist/date only, not linked to identity,
  not stored server-side beyond transient caches.

## Review notes (paste into App Review Information)

The app identifies songs in user-selected concert videos using on-device
ShazamKit fingerprinting, then fetches public setlist data (setlist.fm) via
our backend. To test: import any video containing commercially released
music from the photo library; analysis runs automatically and results appear
under My Concerts. No account or login is required.

## Submission checklist (your side)

1. Join the Apple Developer Program ($99/yr).
2. Register App ID `AppConcert` with the ShazamKit app service enabled
   (Certificates, Identifiers & Profiles → Identifiers).
3. Enable GitHub Pages: repo Settings → Pages → deploy from `main` /docs
   folder (makes the privacy/support URLs live).
4. Confirm setlist.fm API terms for distribution (their free tier is
   non-commercial; email them for approval if the app is public).
5. In Xcode: Signing & Capabilities → select your paid team; Product →
   Archive → Distribute App → App Store Connect.
6. Create the app record in App Store Connect, paste this listing, upload
   screenshots, answer age rating, submit for review (start with TestFlight
   on your own iPhone).
