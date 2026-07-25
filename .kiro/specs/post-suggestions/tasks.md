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
