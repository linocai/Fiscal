from functools import lru_cache
from typing import Literal, Self

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

    @model_validator(mode="after")
    def reject_unsafe_deployed_defaults(self) -> Self:
        if self.environment in {"staging", "production"}:
            if self.device_token.get_secret_value() == DEFAULT_DEVELOPMENT_TOKEN:
                raise ValueError("FISCAL_DEVICE_TOKEN must be set outside local/test environments")
            if len(self.device_token.get_secret_value()) < 32:
                raise ValueError("FISCAL_DEVICE_TOKEN must contain at least 32 characters")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
