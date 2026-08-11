# pyright: reportUnknownVariableType=false, reportUnknownArgumentType=false, reportUnknownMemberType=false, reportAttributeAccessIssue=false
"""Fiscal Archive v1: portable encrypted data, never a backup of credentials.

Threat model: an archive may be copied, modified, or opened with a guessed
password.  Scrypt with a per-archive random salt makes offline guesses costly;
AES-256-GCM authenticates the manifest and compressed payload before any data
is parsed.  The format deliberately does not promise protection from a
compromised device while an archive password is entered, a malicious client
that can ask the live API to export, or a weak user-chosen password.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import zlib
from collections.abc import Mapping
from datetime import date, datetime
from enum import Enum
from typing import Any, cast
from uuid import UUID

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from sqlalchemy import MetaData, Table, delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession

from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db import models as _models
from fiscal_api.db.base import Base
from fiscal_api.db.models.revision import DataRevision

assert (
    _models.__all__
)  # ensure every mapped archival table is registered before Base.metadata is read

ARCHIVE_MAGIC = b"FISCAL-ARCHIVE-V1\n"
ARCHIVE_SCHEMA = "fiscal-archive-v1"
API_SCHEMA = "fiscal-api-v1"
KDF_N = 2**15
KDF_R = 8
KDF_P = 1
_EXCLUDED_TABLES = {"access_credential", "access_keys", "data_revision"}
_AI_SECRET_COLUMNS = {
    "provider_api_key_ciphertext",
    "provider_key_version",
    "provider_kind",
    "provider_base_url",
    "provider_model",
}
_AI_REDACTED_RAW_INPUT = "[AI raw input excluded from Fiscal Archive]"


class ArchiveError(ValueError):
    pass


class ArchiveCompatibilityError(ArchiveError):
    pass


def _canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def _json_value(value: object) -> object:
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    return value


def _decode_value(column: object, value: object) -> object:
    # PostgreSQL/asyncpg accepts ISO dates/timestamps and UUID strings only in
    # some paths. Convert the portable JSON values explicitly before insert.
    column_type = str(getattr(column, "type", "")).upper()
    if value is None:
        return None
    if "UUID" in column_type:
        return UUID(str(value))
    if "TIMESTAMP" in column_type or "DATETIME" in column_type:
        return datetime.fromisoformat(str(value))
    if column_type == "DATE":
        return date.fromisoformat(str(value))
    return value


def _archive_tables(metadata: MetaData) -> list[Table]:
    # SQLAlchemy's dependency order means foreign keys are satisfied without
    # disabling constraints during restore.
    return [table for table in metadata.sorted_tables if table.name not in _EXCLUDED_TABLES]


def _json_object(value: object, *, error: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ArchiveError(error)
    return cast(dict[str, Any], value)


class ArchiveService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def export(
        self, *, password: str, include_ai_raw: bool
    ) -> tuple[bytes, dict[str, object]]:
        tables = _archive_tables(Base.metadata)
        entities: dict[str, list[dict[str, object]]] = {}
        for table in tables:
            rows = (await self.session.execute(select(table))).mappings().all()
            encoded_rows: list[dict[str, object]] = []
            for row in rows:
                values = {key: _json_value(value) for key, value in dict(row).items()}
                if table.name == "ai_settings":
                    for column in _AI_SECRET_COLUMNS:
                        values[column] = None
                if table.name == "ai_proposals" and not include_ai_raw:
                    values["raw_input"] = _AI_REDACTED_RAW_INPUT
                encoded_rows.append(values)
            entities[table.name] = encoded_rows
        revision = await self.session.scalar(
            select(DataRevision.revision).where(DataRevision.id == 1)
        )
        db_revision = await self.session.scalar(text("SELECT version_num FROM alembic_version"))
        if revision is None or db_revision is None:
            raise RuntimeError("archive requires an upgraded Fiscal database")
        payload: dict[str, object] = {"entities": entities, "data_revision": revision}
        payload_bytes = _canonical_json(payload)
        manifest: dict[str, object] = {
            "archive_schema": ARCHIVE_SCHEMA,
            "api_schema": API_SCHEMA,
            "exported_at": utc_now().isoformat(),
            "business_timezone": BUSINESS_TIMEZONE.key,
            "currency": "CNY",
            "database_revision": db_revision,
            "data_revision": revision,
            "entity_counts": {name: len(rows) for name, rows in entities.items()},
            "payload_sha256": hashlib.sha256(payload_bytes).hexdigest(),
            "includes_ai_raw": include_ai_raw,
            "requires_ai_provider_reconfiguration": True,
        }
        return self._seal(password=password, manifest=manifest, payload=payload_bytes), manifest

    @staticmethod
    def _seal(*, password: str, manifest: Mapping[str, object], payload: bytes) -> bytes:
        salt = secrets.token_bytes(16)
        nonce = secrets.token_bytes(12)
        key = Scrypt(salt=salt, length=32, n=KDF_N, r=KDF_R, p=KDF_P).derive(
            password.encode("utf-8")
        )
        manifest_bytes = _canonical_json(dict(manifest))
        ciphertext = AESGCM(key).encrypt(nonce, zlib.compress(payload, level=9), manifest_bytes)
        envelope = {
            "format": ARCHIVE_SCHEMA,
            "kdf": {
                "name": "scrypt",
                "n": KDF_N,
                "r": KDF_R,
                "p": KDF_P,
                "salt": base64.b64encode(salt).decode("ascii"),
            },
            "cipher": {"name": "aes-256-gcm", "nonce": base64.b64encode(nonce).decode("ascii")},
            "manifest": dict(manifest),
            "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
        }
        return ARCHIVE_MAGIC + _canonical_json(envelope)

    @staticmethod
    def open(archive: bytes, *, password: str) -> tuple[dict[str, object], dict[str, object]]:
        try:
            if not archive.startswith(ARCHIVE_MAGIC):
                raise ArchiveCompatibilityError("archive format is not Fiscal Archive v1")
            envelope = _json_object(
                json.loads(archive[len(ARCHIVE_MAGIC) :].decode("utf-8")),
                error="archive envelope is invalid",
            )
            if envelope["format"] != ARCHIVE_SCHEMA:
                raise ArchiveCompatibilityError("archive format is not supported")
            kdf = _json_object(
                envelope["kdf"], error="archive cryptographic parameters are invalid"
            )
            cipher = _json_object(
                envelope["cipher"], error="archive cryptographic parameters are invalid"
            )
            if (
                kdf.get("name") != "scrypt"
                or kdf.get("n") != KDF_N
                or kdf.get("r") != KDF_R
                or kdf.get("p") != KDF_P
                or set(kdf) != {"name", "n", "r", "p", "salt"}
                or cipher.get("name") != "aes-256-gcm"
                or set(cipher) != {"name", "nonce"}
            ):
                raise ArchiveCompatibilityError(
                    "archive cryptographic parameters are not supported"
                )
            manifest = _json_object(envelope["manifest"], error="archive manifest is invalid")
            if (
                manifest.get("archive_schema") != ARCHIVE_SCHEMA
                or manifest.get("api_schema") != API_SCHEMA
            ):
                raise ArchiveCompatibilityError("archive schema is not supported")
            salt = base64.b64decode(kdf["salt"], validate=True)
            nonce = base64.b64decode(cipher["nonce"], validate=True)
            ciphertext = base64.b64decode(envelope["ciphertext"], validate=True)
            if len(salt) != 16 or len(nonce) != 12:
                raise ArchiveCompatibilityError("archive cryptographic parameters are invalid")
            key = Scrypt(salt=salt, length=32, n=KDF_N, r=KDF_R, p=KDF_P).derive(
                password.encode("utf-8")
            )
            payload_bytes = zlib.decompress(
                AESGCM(key).decrypt(nonce, ciphertext, _canonical_json(manifest))
            )
            if hashlib.sha256(payload_bytes).hexdigest() != manifest["payload_sha256"]:
                raise ArchiveError("archive payload hash does not match manifest")
            payload = _json_object(
                json.loads(payload_bytes.decode("utf-8")), error="archive payload is invalid"
            )
        except ArchiveCompatibilityError:
            raise
        except (
            InvalidTag,
            KeyError,
            TypeError,
            ValueError,
            AttributeError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            zlib.error,
        ) as error:
            raise ArchiveError("archive cannot be decrypted or authenticated") from error
        ArchiveService._validate_payload(manifest, payload)
        return manifest, payload

    @staticmethod
    def _validate_payload(manifest: Mapping[str, object], payload: Mapping[str, object]) -> None:
        entities = payload.get("entities")
        if not isinstance(entities, dict) or not isinstance(manifest.get("entity_counts"), dict):
            raise ArchiveError("archive payload shape is invalid")
        allowed = {table.name for table in _archive_tables(Base.metadata)}
        if set(entities) != allowed:
            raise ArchiveCompatibilityError(
                "archive entity set is not supported by this Fiscal version"
            )
        counts = _json_object(manifest["entity_counts"], error="archive entity counts are invalid")
        if set(counts) != set(entities):
            raise ArchiveError("archive entity counts do not match entity set")
        for table_name, expected in counts.items():
            rows = entities.get(table_name)
            if not isinstance(expected, int) or not isinstance(rows, list) or len(rows) != expected:
                raise ArchiveError("archive entity counts do not match manifest")
            columns = {column.name for column in Base.metadata.tables[table_name].columns}
            for row in rows:
                if not isinstance(row, dict) or set(row) != columns:
                    raise ArchiveError("archive row fields do not match the schema")
        if payload.get("data_revision") != manifest.get("data_revision"):
            raise ArchiveError("archive revision does not match manifest")

    @staticmethod
    def dry_run_report(
        manifest: Mapping[str, object], payload: Mapping[str, object]
    ) -> dict[str, object]:
        ArchiveService._validate_payload(manifest, payload)
        ArchiveService._validate_relationships(payload)
        entities = _json_object(payload["entities"], error="archive entities are invalid")
        transactions = entities.get("transactions", [])
        postings = entities.get("postings", [])
        return {
            "database_revision": manifest["database_revision"],
            "data_revision": manifest["data_revision"],
            "entity_counts": manifest["entity_counts"],
            "transaction_count": len(transactions) if isinstance(transactions, list) else 0,
            "posting_count": len(postings) if isinstance(postings, list) else 0,
            "postings_total_minor": sum(
                int(row["amount_minor"])
                for row in postings
                if isinstance(row, dict) and "amount_minor" in row
            )
            if isinstance(postings, list)
            else 0,
            "postings_absolute_total_minor": sum(
                abs(int(row["amount_minor"]))
                for row in postings
                if isinstance(row, dict) and "amount_minor" in row
            )
            if isinstance(postings, list)
            else 0,
            "provider_reconfiguration_required": True,
            "relationship_errors": 0,
        }

    @staticmethod
    def _validate_relationships(payload: Mapping[str, object]) -> None:
        entities = _json_object(payload["entities"], error="archive entities are invalid")
        for table in _archive_tables(Base.metadata):
            rows = cast(list[dict[str, Any]], entities[table.name])
            primary_keys = tuple(column.name for column in table.primary_key.columns)
            seen = {tuple(str(row[key]) for key in primary_keys) for row in rows}
            if len(seen) != len(rows):
                raise ArchiveError(f"archive has duplicate primary keys ({table.name})")
            for foreign_key in table.foreign_keys:
                target = foreign_key.column.table.name
                target_rows = cast(list[dict[str, Any]], entities[target])
                target_values = {str(row[foreign_key.column.name]) for row in target_rows}
                for row in rows:
                    value = row[foreign_key.parent.name]
                    if value is not None and str(value) not in target_values:
                        raise ArchiveError(f"archive has orphan foreign key ({table.name})")

    @staticmethod
    async def restore_empty_target(
        connection: AsyncConnection,
        *,
        manifest: Mapping[str, object],
        payload: Mapping[str, object],
    ) -> None:
        """Restore only after a completed dry run and only into an empty data target."""
        ArchiveService._validate_payload(manifest, payload)
        ArchiveService._validate_relationships(payload)
        target_revision = await connection.scalar(text("SELECT version_num FROM alembic_version"))
        if target_revision != manifest["database_revision"]:
            raise ArchiveCompatibilityError(
                "restore target database revision does not match archive"
            )
        tables = _archive_tables(Base.metadata)
        for table in tables:
            count = await connection.scalar(select(func.count()).select_from(table))
            if count:
                raise ArchiveError(f"restore target is not empty ({table.name})")
        entities = _json_object(payload["entities"], error="archive entities are invalid")
        for table in tables:
            raw_rows = entities[table.name]
            assert isinstance(raw_rows, list)
            rows: list[dict[str, object]] = []
            for raw in raw_rows:
                raw = _json_object(raw, error="archive row shape is invalid")
                rows.append(
                    {
                        column.name: _decode_value(column, raw.get(column.name))
                        for column in table.columns
                    }
                )
            if rows:
                await connection.execute(table.insert(), rows)
        revision = payload["data_revision"]
        if not isinstance(revision, int):
            raise ArchiveError("archive revision is invalid")
        await connection.execute(delete(DataRevision).where(DataRevision.id == 1))
        await connection.execute(DataRevision.__table__.insert().values(id=1, revision=revision))
        restored_counts = {
            table.name: await connection.scalar(select(func.count()).select_from(table))
            for table in tables
        }
        if restored_counts != manifest["entity_counts"]:
            raise ArchiveError("restored entity counts do not match manifest")
        ArchiveService._validate_relationships(payload)
