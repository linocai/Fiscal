import asyncio
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def _app() -> tuple[object, dict[str, str]]:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    return (
        create_app(
            settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
            readiness_check=ready,
        ),
        {"Authorization": "Bearer p31-token"},
    )


def _transform_write_counts() -> tuple[int, int, int]:
    async def read() -> tuple[int, int, int]:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.connect() as connection:
                return (
                    int(
                        await connection.scalar(text("SELECT count(*) FROM transaction_revisions"))
                        or 0
                    ),
                    int(
                        await connection.scalar(
                            text("SELECT count(*) FROM category_transform_operations")
                        )
                        or 0
                    ),
                    int(
                        await connection.scalar(
                            text("SELECT revision FROM data_revision WHERE id = 1")
                        )
                        or 0
                    ),
                )
        finally:
            await engine.dispose()

    return asyncio.run(read())


def _merchant_identifier_keys(merchant_id: str) -> list[str]:
    async def read() -> list[str]:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.connect() as connection:
                return list(
                    (
                        await connection.scalars(
                            text(
                                "SELECT normalized_key FROM merchant_identifiers "
                                "WHERE merchant_id = :merchant_id ORDER BY kind, normalized_key"
                            ),
                            {"merchant_id": merchant_id},
                        )
                    ).all()
                )
        finally:
            await engine.dispose()

    return asyncio.run(read())


def _account(client: TestClient, auth: dict[str, str]) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts",
        headers=auth,
        json={
            "name": f"P31 Account {uuid4().hex[:8]}",
            "kind": "debit",
            "opening_balance_minor": 0,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _category(
    client: TestClient,
    auth: dict[str, str],
    name: str,
    *,
    parent_id: str | None = None,
) -> dict[str, object]:
    response = client.post(
        "/api/v1/categories",
        headers=auth,
        json={
            "name": f"{name} {uuid4().hex[:6]}",
            "direction": "expense",
            "parent_id": parent_id,
            "icon": "tag",
            "color_hex": "#123456",
            "aliases": [],
            "examples": [],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _expense(
    client: TestClient,
    auth: dict[str, str],
    account_id: str,
    *,
    category_id: str | None = None,
    title: str = "P31 expense",
) -> dict[str, object]:
    response = client.post(
        "/api/v1/transactions",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json={
            "kind": "expense",
            "amount_minor": 1_234,
            "occurred_at": "2026-08-14T10:00:00+08:00",
            "title": title,
            "account_id": account_id,
            "category_id": category_id,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_p31_transaction_revisions_and_privacy_safe_provenance() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        transaction = _expense(client, auth, str(account["id"]))
        updated = client.put(
            f"/api/v1/transactions/{transaction['id']}",
            headers=auth,
            json={
                "expected_version": transaction["version"],
                "kind": "expense",
                "amount_minor": 1_234,
                "occurred_at": "2026-08-14T10:00:00+08:00",
                "title": "P31 revised",
                "account_id": account["id"],
            },
        )
        assert updated.status_code == 200, updated.text
        history = client.get(
            f"/api/v1/transactions/{transaction['id']}/revisions",
            headers=auth,
            params={"limit": 1},
        )
        assert history.status_code == 200, history.text
        assert [item["version"] for item in history.json()["items"]] == [2]
        assert history.json()["next_cursor"] == "2"
        prior = client.get(
            f"/api/v1/transactions/{transaction['id']}/revisions",
            headers=auth,
            params={"cursor": history.json()["next_cursor"]},
        )
        assert [item["version"] for item in prior.json()["items"]] == [1]
        provenance = client.get(
            f"/api/v1/transactions/{transaction['id']}/provenance", headers=auth
        )
        assert provenance.status_code == 200, provenance.text
        assert provenance.json()["links"][0]["source_type"] == "manual"
        assert "raw" not in str(provenance.json()).lower()


def test_p31_preview_is_ephemeral_and_stale_commit_writes_nothing() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        source = _category(client, auth, "Stale source")
        target = _category(client, auth, "Stale target")
        original = _expense(client, auth, str(account["id"]), category_id=str(source["id"]))
        before = client.get("/api/v1/reports/facts", headers=auth)
        assert before.status_code == 200, before.text
        preview = client.post(
            f"/api/v1/categories/{source['id']}/merge-preview",
            headers=auth,
            json={
                "target_id": target["id"],
                "source_expected_version": source["version"],
                "target_expected_version": target["version"],
            },
        )
        assert preview.status_code == 200, preview.text
        after_preview = client.get("/api/v1/reports/facts", headers=auth)
        assert (
            after_preview.json()["meta"]["data_revision"] == before.json()["meta"]["data_revision"]
        )
        password = f"preview-{uuid4().hex}"
        archive = client.post("/api/v1/archives/export", headers=auth, json={"password": password})
        assert archive.status_code == 200, archive.text
        _, payload = ArchiveService.open(archive.content, password=password)
        assert "category_transform_previews" not in payload["entities"]
        _expense(client, auth, str(account["id"]), category_id=str(source["id"]))
        stale = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": preview.json()["preview_token"], "child_mappings": []},
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "category_preview_stale"
        unchanged = client.get(f"/api/v1/transactions/{original['id']}", headers=auth)
        assert unchanged.json()["category_id"] == source["id"]


def test_p31_preview_survives_unrelated_formal_mutation() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        source = _category(client, auth, "Independent source")
        target = _category(client, auth, "Independent target")
        preview = client.post(
            f"/api/v1/categories/{source['id']}/merge-preview",
            headers=auth,
            json={
                "target_id": target["id"],
                "source_expected_version": source["version"],
                "target_expected_version": target["version"],
            },
        )
        assert preview.status_code == 200, preview.text
        _account(client, auth)
        committed = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": preview.json()["preview_token"], "child_mappings": []},
        )
        assert committed.status_code == 200, committed.text


def test_p31_category_preview_commit_is_atomic_and_replayable() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        source = _category(client, auth, "Source")
        target = _category(client, auth, "Target")
        source_child = _category(client, auth, "Source child", parent_id=str(source["id"]))
        target_child = _category(client, auth, "Target child", parent_id=str(target["id"]))
        direct = _expense(client, auth, str(account["id"]), category_id=str(source["id"]))
        child = _expense(client, auth, str(account["id"]), category_id=str(source_child["id"]))

        preview = client.post(
            f"/api/v1/categories/{source['id']}/merge-preview",
            headers=auth,
            json={
                "target_id": target["id"],
                "source_expected_version": source["version"],
                "target_expected_version": target["version"],
            },
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["source"]["transaction_count"] == 1
        commit_key = str(uuid4())
        commit = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": commit_key},
            json={
                "preview_token": preview.json()["preview_token"],
                "child_mappings": [
                    {"source_child_id": source_child["id"], "target_child_id": target_child["id"]}
                ],
            },
        )
        assert commit.status_code == 200, commit.text
        assert commit.json()["reclassified_transaction_count"] == 2
        assert (
            client.get(f"/api/v1/transactions/{direct['id']}", headers=auth).json()["category_id"]
            == target["id"]
        )
        assert (
            client.get(f"/api/v1/transactions/{child['id']}", headers=auth).json()["category_id"]
            == target_child["id"]
        )
        replay = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": commit_key},
            json={
                "preview_token": preview.json()["preview_token"],
                "child_mappings": [
                    {"source_child_id": source_child["id"], "target_child_id": target_child["id"]}
                ],
            },
        )
        assert replay.status_code == 200
        assert replay.json() == commit.json()


@pytest.mark.parametrize(
    "mutation",
    [
        "target_add",
        "target_delete",
        "target_archive",
        "target_unarchive",
        "source_delete",
        "source_archive",
    ],
)
def test_p31_merge_preview_stales_for_any_captured_child_set_change(mutation: str) -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        source = _category(client, auth, f"Merge source {mutation}")
        target = _category(client, auth, f"Merge target {mutation}")
        source_child = _category(
            client, auth, f"Merge source child {mutation}", parent_id=str(source["id"])
        )
        target_child = _category(
            client, auth, f"Merge target child {mutation}", parent_id=str(target["id"])
        )
        transaction = _expense(client, auth, str(account["id"]), category_id=str(source["id"]))
        preview = client.post(
            f"/api/v1/categories/{source['id']}/merge-preview",
            headers=auth,
            json={
                "target_id": target["id"],
                "source_expected_version": source["version"],
                "target_expected_version": target["version"],
            },
        )
        assert preview.status_code == 200, preview.text
        if mutation == "target_add":
            _category(client, auth, "Merge added target child", parent_id=str(target["id"]))
        elif mutation == "target_delete":
            deleted = client.delete(
                f"/api/v1/categories/{target_child['id']}?expected_version={target_child['version']}",
                headers=auth,
            )
            assert deleted.status_code == 204, deleted.text
        elif mutation == "target_archive":
            archived = client.post(
                f"/api/v1/categories/{target_child['id']}/archive",
                headers=auth,
                json={"expected_version": target_child["version"]},
            )
            assert archived.status_code == 200, archived.text
        elif mutation == "target_unarchive":
            archived = client.post(
                f"/api/v1/categories/{target_child['id']}/archive",
                headers=auth,
                json={"expected_version": target_child["version"]},
            )
            assert archived.status_code == 200, archived.text
            restored = client.post(
                f"/api/v1/categories/{target_child['id']}/restore",
                headers=auth,
                json={"expected_version": archived.json()["version"]},
            )
            assert restored.status_code == 200, restored.text
        elif mutation == "source_delete":
            deleted = client.delete(
                f"/api/v1/categories/{source_child['id']}?expected_version={source_child['version']}",
                headers=auth,
            )
            assert deleted.status_code == 204, deleted.text
        else:
            archived = client.post(
                f"/api/v1/categories/{source_child['id']}/archive",
                headers=auth,
                json={"expected_version": source_child["version"]},
            )
            assert archived.status_code == 200, archived.text
        before_commit = _transform_write_counts()
        rejected = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "preview_token": preview.json()["preview_token"],
                "child_mappings": [
                    {"source_child_id": source_child["id"], "target_child_id": target_child["id"]}
                ],
            },
        )
        assert rejected.status_code == 409, rejected.text
        assert rejected.json()["error"]["code"] == "category_preview_stale"
        assert _transform_write_counts() == before_commit
        unchanged = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert unchanged.status_code == 200
        assert unchanged.json()["category_id"] == source["id"]
        assert unchanged.json()["version"] == transaction["version"]


def test_creation_receipt_is_original_snapshot_and_no_store():
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        key = str(uuid4())
        created = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": key},
            json={
                "kind": "expense",
                "amount_minor": 123,
                "occurred_at": "2026-08-14T10:00:00+08:00",
                "title": "Original",
                "account_id": account["id"],
            },
        )
        assert created.status_code == 201, created.text
        voided = client.post(
            f"/api/v1/transactions/{created.json()['id']}/void",
            headers=auth,
            json={"expected_version": 1},
        )
        assert voided.status_code == 200, voided.text
        receipt = client.get(f"/api/v1/transactions/by-idempotency/{key}", headers=auth)
        assert receipt.status_code == 200, receipt.text
        assert receipt.headers["cache-control"] == "no-store"
        assert receipt.json() == created.json()
        missing = client.get(f"/api/v1/transactions/by-idempotency/{uuid4()}", headers=auth)
        assert missing.status_code == 404
        assert missing.json()["error"]["code"] == "transaction_operation_not_found"


def test_legacy_merge_advances_transaction_version_and_revision():
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        source = _category(client, auth, "source")
        target = _category(client, auth, "target")
        transaction = _expense(client, auth, str(account["id"]), category_id=str(source["id"]))
        merged = client.post(
            f"/api/v1/categories/{source['id']}/merge",
            headers=auth,
            json={
                "target_id": target["id"],
                "source_expected_version": source["version"],
                "target_expected_version": target["version"],
            },
        )
        assert merged.status_code == 200, merged.text
        actual = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth).json()
        assert actual["category_id"] == target["id"]
        assert actual["version"] == transaction["version"] + 1
        history = client.get(f"/api/v1/transactions/{transaction['id']}/revisions", headers=auth)
        assert history.status_code == 200, history.text
        assert any(row["version"] == actual["version"] for row in history.json()["items"])
        stale = client.post(
            f"/api/v1/transactions/{transaction['id']}/void",
            headers=auth,
            json={"expected_version": transaction["version"]},
        )
        assert stale.status_code == 409, stale.text
