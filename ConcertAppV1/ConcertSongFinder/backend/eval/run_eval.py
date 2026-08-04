"""Golden-set eval runner for post suggestions (task 4.2).

Run whenever CORE_PROMPT or the trend brief changes:

    # Plumbing check with a deterministic mock (no API key, free):
    .venv/bin/python -m eval.run_eval --mode mock

    # Live check against the real provider (needs LLM_API_KEY):
    LLM_API_KEY=... .venv/bin/python -m eval.run_eval --mode live

Gates (hard failures) are CORRECTNESS ONLY, per the metric design:
- the pipeline returns a structurally valid response
- every candidateId exists in the request (no hallucinated IDs)
- exact suggestion count, unique IDs, ranks 1..N
- captions within limits

Taste ("did it pick the moment a human would?") is intentionally NOT gated
here — trends move too fast for a frozen fixture to judge. Each fixture's
"expectations" block is checked and REPORTED but never fails the run; real
taste measurement comes from live accept/dismiss telemetry per
(promptVersion, trendBriefVersion).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import pathlib
import sys

# Allow running from the backend directory.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from app.models.suggestions import SuggestionsRequest  # noqa: E402
from app.services import suggestions as suggestions_service  # noqa: E402
from app.services.suggestions import generate_suggestions  # noqa: E402
from app.services.trend_brief import current_trend_brief  # noqa: E402

GOLDEN_DIR = pathlib.Path(__file__).parent / "golden"


class DeterministicMockLLM:
    """Ranks by metadata (rare > encore > identified video > rest) and emits
    exactly the JSON shape the contract requires. Verifies the full assemble→
    call→parse→validate pipeline without spending provider budget."""

    async def rank(self, request: SuggestionsRequest, system_prompt: str, user_prompt: str) -> str:
        count = min(3, len(request.candidates))

        def score(candidate):
            return (
                (8 if candidate.isRareSong else 0)
                + (4 if candidate.isEncore else 0)
                + (2 if candidate.songTitle else 0)
                + (1 if candidate.kind == "video" else 0)
            )

        ranked = sorted(request.candidates, key=score, reverse=True)[:count]
        suggestions = [
            {
                "candidateId": candidate.id,
                "rank": index + 1,
                "reason": f"Mock pick: {candidate.songTitle or 'unlabeled media'} scored highest on rarity/encore metadata.",
                "caption": f"that {candidate.songTitle or 'moment'} live >>>",
                "hashtags": ["concert", "livemusic"],
            }
            for index, candidate in enumerate(ranked)
        ]
        payload = {"suggestions": suggestions}
        if request.debug:
            payload["evaluations"] = [
                {
                    "candidateId": candidate.id,
                    "score": min(100, score(candidate) * 10),
                    "reasoning": "Mock score from rarity/encore/identified metadata.",
                }
                for candidate in request.candidates
            ]
        return json.dumps(payload)


def load_fixtures() -> list[dict]:
    fixtures = []
    for path in sorted(GOLDEN_DIR.glob("*.json")):
        with open(path) as handle:
            fixtures.append(json.load(handle))
    return fixtures


async def run_fixture(fixture: dict, client) -> dict:
    """Returns a result dict; 'passed' reflects correctness gates only."""
    name = fixture["name"]
    request = SuggestionsRequest(**fixture["request"])
    valid_ids = {candidate.id for candidate in request.candidates}
    expected_count = min(3, len(request.candidates))

    # Fresh guardrail state per fixture so one failure cannot cascade.
    suggestions_service.reset_budget_for_tests()
    suggestions_service.reset_breaker_for_tests()

    failures: list[str] = []
    advisories: list[str] = []
    response = None
    try:
        response = await generate_suggestions(
            request, client=client, brief=current_trend_brief(), daily_limit=10_000
        )
    except Exception as exc:  # HTTPException or anything else = validity failure
        failures.append(f"pipeline raised {type(exc).__name__}: {exc}")

    if response is not None:
        ids = [item.candidateId for item in response.suggestions]
        if len(response.suggestions) != expected_count:
            failures.append(f"expected {expected_count} suggestions, got {len(response.suggestions)}")
        if len(set(ids)) != len(ids):
            failures.append("duplicate candidate ids")
        for suggestion in response.suggestions:
            if suggestion.candidateId not in valid_ids:
                failures.append(f"hallucinated id {suggestion.candidateId!r}")
            if not suggestion.caption.strip():
                failures.append(f"empty caption for {suggestion.candidateId}")
            if len(suggestion.caption) > 300:
                failures.append(f"caption over limit for {suggestion.candidateId}")
        if sorted(item.rank for item in response.suggestions) != list(range(1, len(response.suggestions) + 1)):
            failures.append(f"ranks not 1..N: {[item.rank for item in response.suggestions]}")

        # Advisory taste expectations: reported, never gated.
        expectations = fixture.get("expectations", {})
        should_include = expectations.get("should_include_any") or []
        if should_include and not (set(should_include) & set(ids)):
            advisories.append(
                f"none of the advisory picks {should_include} were chosen (got {ids})"
            )

    return {"name": name, "passed": not failures, "failures": failures, "advisories": advisories, "response": response}


async def main() -> int:
    parser = argparse.ArgumentParser(description="Post-suggestions golden eval")
    parser.add_argument("--mode", choices=["mock", "live"], default="mock")
    args = parser.parse_args()

    if args.mode == "live":
        from app.config import get_settings
        from app.services.llm_client import make_llm_client

        settings = get_settings()
        if not settings.llm_api_key:
            print("ERROR: live mode requires LLM_API_KEY to be set")
            return 2
        client = make_llm_client(settings)
    else:
        client = DeterministicMockLLM()

    fixtures = load_fixtures()
    if not fixtures:
        print(f"ERROR: no fixtures found in {GOLDEN_DIR}")
        return 2

    brief = current_trend_brief()
    print(f"mode={args.mode} fixtures={len(fixtures)} prompt={suggestions_service.PROMPT_VERSION} brief={brief.version}\n")

    results = [await run_fixture(fixture, client) for fixture in fixtures]

    passed = sum(1 for result in results if result["passed"])
    for result in results:
        status = "PASS" if result["passed"] else "FAIL"
        print(f"[{status}] {result['name']}")
        for failure in result["failures"]:
            print(f"    correctness: {failure}")
        for advisory in result["advisories"]:
            print(f"    advisory   : {advisory}")
        if result["response"] is not None:
            for suggestion in result["response"].suggestions:
                print(f"    #{suggestion.rank} {suggestion.candidateId}: {suggestion.reason[:80]}")

    print(f"\nvalidity rate: {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
