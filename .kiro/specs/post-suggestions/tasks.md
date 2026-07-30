# Tasks: TikTok Post Suggestions (Option C — Cloud LLM)

Metric design: two layers — timeless criteria live in the versioned core
prompt; volatile trend criteria live in a server-side trend brief that can
change without an app release. Taste is measured by live acceptance
telemetry; the golden set gates correctness only.

## Phase 0 — Privacy groundwork
- [x] 0.1 Privacy policy: opt-in AI suggestions section (frames leave device)
- [x] 0.2 Consent flow: off by default, plain-language sheet, revocable
- [x] 0.3 Provider choice documented (no-training-on-API-data terms)

## Phase 1 — Candidate extraction (on-device)
- [x] 1.1 Candidate builder from ConcertRecord (song/rarity/encore context)
- [x] 1.2 Keyframe sampler (3 frames/video, ~512px JPEG, EXIF-free), caps:
      ≤12 candidates, ≤3 frames each
- [x] 1.3 Deterministic candidate IDs for safe response joining

## Phase 2 — Backend endpoint
- [x] 2.1 POST /api/suggestions (auth required, size caps)
- [x] 2.2 Versioned core prompt + trend-brief slot; versions logged
- [x] 2.5 Trend brief: server config w/ env override, version stamped
- [x] 2.3 Strict response schema; validate; one repair retry; fail closed
- [x] 2.4 Guardrails: timeout, daily budget, circuit breaker, kill switch
- [x] 2.6 Frames processed in memory only; never logged/persisted

## Phase 3 — iOS client
- [x] 3.1 SuggestionService + DTOs (joined by candidate ID)
- [x] 3.2 Graceful degradation + per-concert cache (keyed incl. brief version)
- [x] 3.3 "Post Ideas" UI: 3 cards → preview → share via existing pipeline
- [x] 3.4 used/dismissed feedback logging (acceptance telemetry seed)

## Phase 4 — Evaluation harness
- [x] 4.1 Golden fixtures format + example (correctness-only assertions)
- [x] 4.2 Eval runner: validity rate, ID integrity, caption sanity; run on
      prompt/brief change (mock + live modes)

## Phase 5 — Observability & ops
- [x] 5.1 Structured logs: request id, versions, tokens, latency, outcome
- [x] 5.2 Failure-rate + budget conditions visible in logs
- [x] 5.3 SUGGESTIONS_ENABLED kill switch, clean client handling

## Phase 6 — Categorized suggestions v2 (replaces top-3 list)

Categories + caps: Best Quality ≤2, Unique Moments ≤3, Artist Feature ≤1,
Photo Slideshow ≤6 photos. Empty categories are legal and hidden in the UI.
Every video suggestion may carry an optional AI-suggested clip range;
exports stay full-length by default with a share-time "suggested clip only"
toggle.

### Backend
- [x] 6.1 Schema v2: `category` on each suggestion
      (bestQuality|uniqueMoment|artistFeature|photoSlideshow), per-category
      caps validated, optional clipStartSeconds/clipEndSeconds on video
      suggestions (bounds-checked against candidate duration), unique IDs
      across categories, empty categories allowed; fail-closed + repair
      retry preserved
- [x] 6.2 Prompt core-v2 rubrics: quality (artist visibility > stability
      across frames > exposure > audioClarity proxy; penalize jumbotron);
      unique (outliers relative to THIS candidate set — flashlights, mosh
      pit, pyro, artist-in-crowd; reason must name the element; "chaotic
      with no discernible subject is noise" guard); feature (prefer
      isGuestFeature-flagged candidates, only infer from frames on strong
      evidence, else empty; may narrow the provided segment clip range);
      slideshow (sharp, well-exposed, artist visible, visual variety)
- [x] 6.3 Candidate metadata: audioClarity (Shazam matched-duration ratio +
      window count), headlinerArtist, isGuestFeature + featuredArtist,
      segment bounds as default clip range
- [x] 6.4 Tests: per-category caps enforced, unknown category rejected,
      clip range outside duration rejected, empty categories pass,
      guest-feature metadata reaches the prompt, debug evaluations still
      cover all candidates
- [x] 6.5 Eval fixtures per category (guest-feature concert, flashlight
      moment, quality-split set) + deterministic mock update

### iOS
- [x] 6.6 Candidate builder v2: audioClarity from RecognitionEvidence,
      guest-feature detection (recognized artist ≠ headliner, occurrence
      notes "with …"), 4 frames per video, photos marked
      slideshow-eligible
- [x] 6.7 UI: three video category sections + slideshow section, labeled,
      empty categories hidden; clip-range label on cards ("best part:
      0:42–1:10")
- [x] 6.8 Share: "Suggested clip only" toggle in ShareMediaSheet for
      suggestions with a clip range → time-range trimmed export in
      MediaShareService; default remains full clip
- [x] 6.9 Photo slideshow: swipeable card of picked photos; share exports
      a generated slideshow video (~2s per photo) through the existing
      share pipeline
- [x] 6.10 Debug scores panel: show category fit alongside score/reasoning
