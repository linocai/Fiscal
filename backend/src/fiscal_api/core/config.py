from functools import lru_cache
from typing import Literal, Self
from urllib.parse import urlparse

from pydantic import SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["local", "test", "staging", "production"]
DEFAULT_DEVELOPMENT_TOKEN = "development-device-token-change-me"  # noqa: S105


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="FISCAL_",
        extra="ignore",
    )

    environment: Environment = "local"
    service_name: str = "fiscal-api"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    database_url: str = "postgresql+asyncpg://fiscal:fiscal@localhost:5432/fiscal"
    device_token: SecretStr = SecretStr(DEFAULT_DEVELOPMENT_TOKEN)
    ai_provider: Literal["disabled", "openai_compatible"] = "disabled"
    ai_provider_base_url: str | None = None
    ai_provider_model: str | None = None
    ai_provider_api_key: SecretStr | None = None
    ai_provider_timeout_seconds: float = 15.0
    ai_provider_max_response_bytes: int = 65_536

    @model_validator(mode="after")
    def reject_unsafe_deployed_defaults(self) -> Self:
        if self.environment in {"staging", "production"}:
            if self.device_token.get_secret_value() == DEFAULT_DEVELOPMENT_TOKEN:
                raise ValueError("FISCAL_DEVICE_TOKEN must be set outside local/test environments")
            if len(self.device_token.get_secret_value()) < 32:
                raise ValueError("FISCAL_DEVICE_TOKEN must contain at least 32 characters")
        if not 1 <= self.ai_provider_timeout_seconds <= 60:
            raise ValueError("FISCAL_AI_PROVIDER_TIMEOUT_SECONDS must be between 1 and 60")
        if not 1_024 <= self.ai_provider_max_response_bytes <= 1_048_576:
            raise ValueError(
                "FISCAL_AI_PROVIDER_MAX_RESPONSE_BYTES must be between 1024 and 1048576"
            )
        if self.ai_provider_base_url is not None:
            parsed = urlparse(self.ai_provider_base_url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ValueError("FISCAL_AI_PROVIDER_BASE_URL must be an absolute HTTP(S) URL")
            if parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise ValueError(
                    "FISCAL_AI_PROVIDER_BASE_URL must not contain credentials, query, or fragment"
                )
            if self.environment in {"staging", "production"} and parsed.scheme != "https":
                raise ValueError("FISCAL_AI_PROVIDER_BASE_URL must use HTTPS when deployed")
        return self

    @property
    def ai_provider_configured(self) -> bool:
        return self.ai_provider == "openai_compatible" and all(
            (self.ai_provider_base_url, self.ai_provider_model, self.ai_provider_api_key)
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
