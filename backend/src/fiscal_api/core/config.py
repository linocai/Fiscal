from functools import lru_cache
from pathlib import Path
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
    device_token: SecretStr | None = None
    token_pepper: SecretStr | None = None
    token_pepper_version: int = 1
    token_pending_ttl_minutes: int = 15
    rate_limit_read_per_minute: int = 120
    rate_limit_write_per_minute: int = 30
    rate_limit_ai_per_minute: int = 10
    rate_limit_failed_auth_per_minute: int = 10
    operations_status_directory: Path = Path("/var/lib/fiscal/operations")
    release_metadata_file: Path = Path("/opt/fiscal/current/RELEASE")
    backup_max_age_hours: int = 30
    restore_verify_stale_hours: int = 192
    disk_status_stale_minutes: int = 60
    ai_provider: Literal["disabled", "openai_compatible"] = "disabled"
    ai_provider_base_url: str | None = None
    ai_provider_model: str | None = None
    ai_provider_api_key: SecretStr | None = None
    ai_provider_timeout_seconds: float = 15.0
    ai_provider_max_response_bytes: int = 65_536

    @model_validator(mode="after")
    def reject_unsafe_deployed_defaults(self) -> Self:
        if self.environment in {"staging", "production"}:
            if self.device_token is not None:
                raise ValueError("FISCAL_DEVICE_TOKEN is forbidden outside local/test")
            if self.token_pepper is None or len(self.token_pepper.get_secret_value().encode()) < 32:
                raise ValueError("FISCAL_TOKEN_PEPPER must contain at least 32 bytes")
        if self.token_pepper_version < 1:
            raise ValueError("FISCAL_TOKEN_PEPPER_VERSION must be positive")
        if not 5 <= self.token_pending_ttl_minutes <= 60:
            raise ValueError("FISCAL_TOKEN_PENDING_TTL_MINUTES must be between 5 and 60")
        for name, value in (
            ("read", self.rate_limit_read_per_minute),
            ("write", self.rate_limit_write_per_minute),
            ("AI", self.rate_limit_ai_per_minute),
            ("failed-auth", self.rate_limit_failed_auth_per_minute),
        ):
            if not 1 <= value <= 10_000:
                raise ValueError(f"The {name} rate limit must be between 1 and 10000")
        if not 24 <= self.backup_max_age_hours <= 168:
            raise ValueError("FISCAL_BACKUP_MAX_AGE_HOURS must be between 24 and 168")
        if not 24 <= self.restore_verify_stale_hours <= 744:
            raise ValueError("FISCAL_RESTORE_VERIFY_STALE_HOURS must be between 24 and 744")
        if not 15 <= self.disk_status_stale_minutes <= 1_440:
            raise ValueError("FISCAL_DISK_STATUS_STALE_MINUTES must be between 15 and 1440")
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
    def uses_database_device_tokens(self) -> bool:
        return self.environment in {"staging", "production"}

    @property
    def legacy_device_token(self) -> str:
        if self.uses_database_device_tokens:
            raise RuntimeError("Legacy device tokens are disabled")
        return (
            self.device_token.get_secret_value()
            if self.device_token is not None
            else DEFAULT_DEVELOPMENT_TOKEN
        )

    @property
    def ai_provider_configured(self) -> bool:
        return self.ai_provider == "openai_compatible" and all(
            (self.ai_provider_base_url, self.ai_provider_model, self.ai_provider_api_key)
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
