import asyncio
import unicodedata
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, text

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


def test_p31_merchant_mapping_is_idempotent_and_keeps_ledger_evidence() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        transaction = _expense(client, auth, str(account["id"]), title="Original shop evidence")
        merchant = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": "Merchant A", "aliases": ["Shop A", "A Pay"]},
        )
        assert merchant.status_code == 201, merchant.text
        merchant_body = merchant.json()
        mapping_key = str(uuid4())
        mapping_payload = {"merchant_id": merchant_body["id"]}
        confirmed = client.put(
            f"/api/v1/transactions/{transaction['id']}/merchant-mapping",
            headers={**auth, "Idempotency-Key": mapping_key},
            json=mapping_payload,
        )
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()["action"] == "confirmed"
        assert confirmed.json()["mapping"]["merchant"]["aliases"] == ["A Pay", "Shop A"]
        replay = client.put(
            f"/api/v1/transactions/{transaction['id']}/merchant-mapping",
            headers={**auth, "Idempotency-Key": mapping_key},
            json=mapping_payload,
        )
        assert replay.status_code == 200
        assert replay.json() == confirmed.json()
        unchanged = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert unchanged.status_code == 200
        assert unchanged.json()["title"] == "Original shop evidence"
        assert unchanged.json()["amount_minor"] == 1_234
        assert unchanged.json()["postings"] == transaction["postings"]
        password = f"p31-{uuid4().hex}"
        exported = client.post(
            "/api/v1/archives/export",
            headers=auth,
            json={"password": password},
        )
        assert exported.status_code == 200, exported.text
        _, payload = ArchiveService.open(exported.content, password=password)
        entities = payload["entities"]
        assert isinstance(entities, dict)
        assert any(row["id"] == merchant_body["id"] for row in entities["merchants"])
        assert any(
            row["transaction_id"] == transaction["id"]
            for row in entities["transaction_merchant_mappings"]
        )

        corrected_merchant = client.post(
            "/api/v1/merchants", headers=auth, json={"name": "Merchant B", "aliases": []}
        )
        assert corrected_merchant.status_code == 201
        corrected = client.put(
            f"/api/v1/transactions/{transaction['id']}/merchant-mapping",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "merchant_id": corrected_merchant.json()["id"],
                "expected_mapping_version": confirmed.json()["mapping"]["mapping_version"],
            },
        )
        assert corrected.status_code == 200, corrected.text
        assert corrected.json()["action"] == "corrected"
        released = client.request(
            "DELETE",
            f"/api/v1/transactions/{transaction['id']}/merchant-mapping",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"expected_mapping_version": corrected.json()["mapping"]["mapping_version"]},
        )
        assert released.status_code == 200, released.text
        assert released.json()["mapping"] is None


def test_p31_merchant_namespace_and_keyset_page_are_stable() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        first = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": "\uff21 Store", "aliases": ["Shop A"]},
        )
        assert first.status_code == 201, first.text
        # NFKC + casefold makes canonical names and aliases a single namespace.
        collision = client.post(
            "/api/v1/merchants", headers=auth, json={"name": "shop a", "aliases": []}
        )
        assert collision.status_code == 409
        second = client.post(
            "/api/v1/merchants", headers=auth, json={"name": "Z Store", "aliases": []}
        )
        assert second.status_code == 201
        page = client.get("/api/v1/merchants", headers=auth, params={"limit": 1})
        assert page.status_code == 200, page.text
        assert len(page.json()["items"]) == 1
        cursor = page.json()["next_cursor"]
        assert cursor
        following = client.get(
            "/api/v1/merchants", headers=auth, params={"limit": 1, "cursor": cursor}
        )
        assert following.status_code == 200, following.text
        assert following.json()["items"][0]["id"] != page.json()["items"][0]["id"]
        tampered = client.get(
            "/api/v1/merchants", headers=auth, params={"cursor": cursor, "query": "other"}
        )
        assert tampered.status_code == 422


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
        unrelated = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": f"Independent {uuid4().hex}", "aliases": []},
        )
        assert unrelated.status_code == 201, unrelated.text
        committed = client.post(
            f"/api/v1/categories/{source['id']}/merge-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": preview.json()["preview_token"], "child_mappings": []},
        )
        assert committed.status_code == 200, committed.text


def test_p31_merchant_page_batches_aliases_without_n_plus_one() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        for index in range(4):
            created = client.post(
                "/api/v1/merchants",
                headers=auth,
                json={"name": f"Batch {index}", "aliases": [f"Alias {index}"]},
            )
            assert created.status_code == 201, created.text
        statements: list[str] = []

        def counted(*args: object) -> None:
            statements.append(str(args[2]))

        event.listen(app.state.db_engine.sync_engine, "before_cursor_execute", counted)
        try:
            small = client.get("/api/v1/merchants", headers=auth, params={"limit": 1})
            small_count = len(statements)
            statements.clear()
            large = client.get("/api/v1/merchants", headers=auth, params={"limit": 4})
            large_count = len(statements)
        finally:
            event.remove(app.state.db_engine.sync_engine, "before_cursor_execute", counted)
        assert small.status_code == large.status_code == 200
        assert small_count == large_count
        assert large_count <= 3
        assert len(large.json()["items"]) == 4


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

        split_root = _category(client, auth, "Split root")
        split_transaction = _expense(
            client, auth, str(account["id"]), category_id=str(split_root["id"])
        )
        split_preview = client.post(
            f"/api/v1/categories/{split_root['id']}/split-preview",
            headers=auth,
            json={
                "root_expected_version": split_root["version"],
                "children": [
                    {
                        "name": "One",
                        "direction": "expense",
                        "icon": "tag",
                        "color_hex": "#123456",
                        "aliases": [],
                        "examples": [],
                    },
                    {
                        "name": "Two",
                        "direction": "expense",
                        "icon": "tag",
                        "color_hex": "#654321",
                        "aliases": [],
                        "examples": [],
                    },
                ],
            },
        )
        assert split_preview.status_code == 200, split_preview.text
        split_commit = client.post(
            f"/api/v1/categories/{split_root['id']}/split-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "preview_token": split_preview.json()["preview_token"],
                "assignments": [{"transaction_id": split_transaction["id"], "child_name": "One"}],
            },
        )
        assert split_commit.status_code == 200, split_commit.text
        one_id = next(
            item["id"] for item in split_commit.json()["categories"] if item["name"] == "One"
        )
        assert (
            client.get(f"/api/v1/transactions/{split_transaction['id']}", headers=auth).json()[
                "category_id"
            ]
            == one_id
        )


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


@pytest.mark.parametrize("mutation", ["add", "delete", "archive"])
def test_p31_split_preview_stales_for_any_captured_child_set_change(mutation: str) -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _account(client, auth)
        root = _category(client, auth, f"Split root {mutation}")
        existing_child = _category(
            client, auth, f"Split child {mutation}", parent_id=str(root["id"])
        )
        transaction = _expense(client, auth, str(account["id"]), category_id=str(root["id"]))
        preview = client.post(
            f"/api/v1/categories/{root['id']}/split-preview",
            headers=auth,
            json={
                "root_expected_version": root["version"],
                "children": [
                    {
                        "name": "Split one",
                        "direction": "expense",
                        "icon": "tag",
                        "color_hex": "#123456",
                        "aliases": [],
                        "examples": [],
                    },
                    {
                        "name": "Split two",
                        "direction": "expense",
                        "icon": "tag",
                        "color_hex": "#654321",
                        "aliases": [],
                        "examples": [],
                    },
                ],
            },
        )
        assert preview.status_code == 200, preview.text
        if mutation == "add":
            _category(client, auth, "Split added child", parent_id=str(root["id"]))
        elif mutation == "delete":
            deleted = client.delete(
                f"/api/v1/categories/{existing_child['id']}?expected_version={existing_child['version']}",
                headers=auth,
            )
            assert deleted.status_code == 204, deleted.text
        else:
            archived = client.post(
                f"/api/v1/categories/{existing_child['id']}/archive",
                headers=auth,
                json={"expected_version": existing_child["version"]},
            )
            assert archived.status_code == 200, archived.text
        before_commit = _transform_write_counts()
        rejected = client.post(
            f"/api/v1/categories/{root['id']}/split-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "preview_token": preview.json()["preview_token"],
                "assignments": [{"transaction_id": transaction["id"], "child_name": "Split one"}],
            },
        )
        assert rejected.status_code == 409, rejected.text
        assert rejected.json()["error"]["code"] == "category_preview_stale"
        assert _transform_write_counts() == before_commit
        unchanged = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert unchanged.status_code == 200
        assert unchanged.json()["category_id"] == root["id"]
        assert unchanged.json()["version"] == transaction["version"]


def test_p31_merchant_identifier_normalization_has_stable_bounds_errors() -> None:
    app, auth = _app()
    boundary = "\ufdfa" * 13
    too_long = "\ufdfa" * 14
    with TestClient(app) as client:
        created = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": boundary, "aliases": ["\uff33\uff48\uff4f\uff50"]},
        )
        assert created.status_code == 201, created.text
        normalized_boundary = unicodedata.normalize("NFKC", boundary).casefold()
        assert _merchant_identifier_keys(created.json()["id"]) == ["shop", normalized_boundary]
        assert len(normalized_boundary) == 234

        long_name = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": too_long, "aliases": []},
        )
        assert long_name.status_code == 422, long_name.text
        assert long_name.json()["error"]["code"] == "merchant_identifier_too_long"
        assert long_name.json()["error"]["details"] == {"field": "name", "max_length": 240}

        long_alias = client.post(
            "/api/v1/merchants",
            headers=auth,
            json={"name": "ordinary unicode Café", "aliases": [too_long]},
        )
        assert long_alias.status_code == 422, long_alias.text
        assert long_alias.json()["error"]["code"] == "merchant_identifier_too_long"
        assert long_alias.json()["error"]["details"] == {
            "field": "aliases[0]",
            "max_length": 240,
        }

        before_update = client.get(f"/api/v1/merchants/{created.json()['id']}", headers=auth)
        rejected_update = client.patch(
            f"/api/v1/merchants/{created.json()['id']}",
            headers=auth,
            json={"expected_version": before_update.json()["version"], "aliases": [too_long]},
        )
        assert rejected_update.status_code == 422, rejected_update.text
        assert rejected_update.json()["error"]["code"] == "merchant_identifier_too_long"
        assert client.get(f"/api/v1/merchants/{created.json()['id']}", headers=auth).json() == (
            before_update.json()
        )
