from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    setlist_fm_api_key: str | None = None
    lyrics_provider_api_key: str | None = None
    lyrics_provider_base_url: str | None = None
    backend_api_key: str | None = None
    cache_ttl_seconds: int = 900
    allowed_origins: str = "http://localhost:3000"
    # Post-suggestions (Option C) settings
    llm_api_key: str | None = None
    llm_model: str | None = None
    # "anthropic" | "gemini"; auto-detected from the key format when unset.
    llm_provider: str | None = None
    # Comma-separated fallback models tried when the primary is rate
    # limited (free-tier quotas are per model). Defaults in llm_client.
    llm_fallback_models: str | None = None
    suggestions_enabled: bool = True
    suggestions_daily_limit: int = 50

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def origins(self) -> list[str]:
        return [origin.strip() for origin in self.allowed_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
