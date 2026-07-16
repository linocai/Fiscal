import hashlib
import hmac
import secrets

TOKEN_PREFIX = "fiscal_dt_v1_"  # noqa: S105 -- public format marker, not a credential
TOKEN_MIN_LENGTH = len(TOKEN_PREFIX) + 43
TOKEN_MAX_LENGTH = 256


def generate_device_token() -> str:
    return f"{TOKEN_PREFIX}{secrets.token_urlsafe(32)}"


def token_digest(raw_token: str, pepper: str) -> bytes:
    return hmac.digest(pepper.encode(), raw_token.encode(), "sha256")


def token_fingerprint(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode()).hexdigest()[:12]


def is_well_formed_database_token(raw_token: str) -> bool:
    secret = raw_token[len(TOKEN_PREFIX) :] if raw_token.startswith(TOKEN_PREFIX) else ""
    return (
        TOKEN_MIN_LENGTH <= len(raw_token) <= TOKEN_MAX_LENGTH
        and bool(secret)
        and all(character.isalnum() or character in "-_" for character in secret)
    )
