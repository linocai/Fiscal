"""Personal access passphrase and opaque access-key primitives.

The passphrase is stored only as a PBKDF2-HMAC-SHA256 slow hash with a per-row
random salt. Access keys are opaque bearer secrets; only their HMAC-SHA256
digest (keyed by the deployment pepper) is persisted. Nothing here logs or
returns plaintext.
"""

import hashlib
import hmac
import secrets
import unicodedata

ACCESS_KEY_PREFIX = "fiscal_ak_v1_"
ACCESS_KEY_MIN_LENGTH = len(ACCESS_KEY_PREFIX) + 43
ACCESS_KEY_MAX_LENGTH = 256

PASSPHRASE_MIN_LENGTH = 8
PASSPHRASE_MAX_LENGTH = 128
SALT_BYTES = 16
DERIVED_KEY_BYTES = 32


def generate_access_key() -> str:
    return f"{ACCESS_KEY_PREFIX}{secrets.token_urlsafe(32)}"


def access_key_digest(raw_key: str, pepper: str) -> bytes:
    return hmac.digest(pepper.encode(), raw_key.encode(), "sha256")


def access_key_fingerprint(raw_key: str) -> str:
    return hashlib.sha256(raw_key.encode()).hexdigest()[:12]


def is_well_formed_access_key(raw_key: str) -> bool:
    secret = raw_key[len(ACCESS_KEY_PREFIX) :] if raw_key.startswith(ACCESS_KEY_PREFIX) else ""
    return (
        ACCESS_KEY_MIN_LENGTH <= len(raw_key) <= ACCESS_KEY_MAX_LENGTH
        and bool(secret)
        and all(character.isalnum() or character in "-_" for character in secret)
    )


def generate_salt() -> bytes:
    return secrets.token_bytes(SALT_BYTES)


def normalize_passphrase(passphrase: str) -> str:
    return unicodedata.normalize("NFC", passphrase)


def is_valid_passphrase_length(passphrase: str) -> bool:
    return PASSPHRASE_MIN_LENGTH <= len(normalize_passphrase(passphrase)) <= PASSPHRASE_MAX_LENGTH


def derive_passphrase_hash(passphrase: str, salt: bytes, iterations: int) -> bytes:
    return hashlib.pbkdf2_hmac(
        "sha256",
        normalize_passphrase(passphrase).encode("utf-8"),
        salt,
        iterations,
        dklen=DERIVED_KEY_BYTES,
    )


def verify_passphrase(passphrase: str, salt: bytes, iterations: int, expected_hash: bytes) -> bool:
    candidate = derive_passphrase_hash(passphrase, salt, iterations)
    return hmac.compare_digest(candidate, expected_hash)
