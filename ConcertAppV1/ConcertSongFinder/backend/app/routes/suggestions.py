from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from app.config import Settings, get_settings
from app.models.suggestions import SuggestionsRequest, SuggestionsResponse
from app.security import require_api_key
from app.services.llm_client import SuggestionLLMClient, make_llm_client
from app.services.suggestions import generate_suggestions
from app.services.trend_brief import current_trend_brief

router = APIRouter(prefix="/api/suggestions", tags=["suggestions"], dependencies=[Depends(require_api_key)])


def get_llm_client(settings: Settings = Depends(get_settings)) -> SuggestionLLMClient:
    return make_llm_client(settings)


@router.post("", response_model=SuggestionsResponse)
async def post_suggestions(
    request: SuggestionsRequest,
    settings: Settings = Depends(get_settings),
    client: SuggestionLLMClient = Depends(get_llm_client),
) -> SuggestionsResponse:
    # Kill switch: disable the feature without redeploying the app.
    if not settings.suggestions_enabled:
        raise HTTPException(status_code=503, detail={"code": "feature_disabled", "message": "Post suggestions are currently disabled."})

    return await generate_suggestions(
        request,
        client=client,
        brief=current_trend_brief(),
        daily_limit=settings.suggestions_daily_limit,
    )
