import base64
import binascii
import hashlib
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from fiscal_api.core.config import Settings

_AAD = b"fiscal-ai-provider-key-v1"


class ProviderCredentialCipher:
    version = 1

    def __init__(self, secret: str) -> None:
        if len(secret.encode()) < 32:
            raise ValueError("provider credential root secret must contain at least 32 bytes")
        self._key = hashlib.sha256(b"fiscal-provider-credentials-v1\0" + secret.encode()).digest()

    @classmethod
    def from_settings(cls, settings: Settings) -> "ProviderCredentialCipher":
        secret = (
            settings.token_pepper.get_secret_value()
            if settings.token_pepper is not None
            else settings.legacy_device_token
        )
        return cls(secret)

    def encrypt(self, plaintext: str) -> str:
        nonce = os.urandom(12)
        ciphertext = AESGCM(self._key).encrypt(nonce, plaintext.encode(), _AAD)
        return base64.urlsafe_b64encode(nonce + ciphertext).decode()

    def decrypt(self, encoded: str, version: int) -> str:
        if version != self.version:
            raise ValueError("unsupported provider credential version")
        try:
            payload = base64.urlsafe_b64decode(encoded.encode())
            if len(payload) < 29:
                raise ValueError("malformed provider credential")
            return AESGCM(self._key).decrypt(payload[:12], payload[12:], _AAD).decode()
        except (binascii.Error, InvalidTag, UnicodeDecodeError) as error:
            raise ValueError("malformed provider credential") from error
