"""The trend brief: the volatile half of the "good post" metric.

Timeless judging criteria live in the versioned core prompt
(services/suggestions.py). Everything fashion-dependent — hot formats,
caption styles, favored clip lengths — lives HERE so it can be updated in
minutes (edit this default or set the TREND_BRIEF / TREND_BRIEF_VERSION env
vars on the server) without an app release or code change.

Update cadence: skim TikTok Creative Center + current concert-clip trends
weekly and refresh. Bump the version on every edit — it is stamped on every
response and drives client cache invalidation and acceptance-rate telemetry.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

DEFAULT_TREND_BRIEF_VERSION = "2026-07-21.1"
DEFAULT_TREND_BRIEF = """Current TikTok concert-content trends (July 2026):
- Reaction-in-frame clips (fan visible reacting while artist performs) are
  outperforming clean stage-only fancams.
- Clips that open mid-moment (crowd already screaming, chorus already hit)
  strongly beat clips with build-up; assume a 3-second attention window.
- 8-15 second clips are the sweet spot; over 30 seconds underperforms.
- Text-overlay storytelling ("the way he stopped the show for this...") is
  the dominant caption style; first-person, lowercase, conversational.
- Surprise/rare moments explicitly labeled as such ("he NEVER plays this")
  travel furthest.
- Vertical, close-to-stage footage preferred; distant jumbotron footage only
  works when the moment itself is extraordinary.
"""


@dataclass(frozen=True)
class TrendBrief:
    version: str
    text: str


def current_trend_brief() -> TrendBrief:
    text = os.environ.get("TREND_BRIEF", "").strip() or DEFAULT_TREND_BRIEF
    version = os.environ.get("TREND_BRIEF_VERSION", "").strip() or DEFAULT_TREND_BRIEF_VERSION
    return TrendBrief(version=version, text=text)
