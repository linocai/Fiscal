from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_p30b_order_revisions_conflicts_checkpoint_and_attention_actions() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL), readiness_check=ready
    )
    auth = {"Authorization": "Bearer p30b-token"}
    with TestClient(app) as client:
        accounts = []
        for name in ("P30B 甲", "P30B 乙"):
            response = client.post(
                "/api/v1/accounts",
                headers=auth,
                json={
                    "name": f"{name} {uuid4().hex[:8]}",
                    "kind": "debit",
                    "opening_balance_minor": 0,
                },
            )
            assert response.status_code == 201, response.text
            accounts.append(response.json())

        order_state = client.get("/api/v1/accounts/order-state", headers=auth)
        assert order_state.status_code == 200, order_state.text
        revision = order_state.json()["list_revision"]
        reordered = client.put(
            "/api/v1/accounts/order",
            headers=auth,
            json={
                "ordered_ids": [accounts[1]["id"], accounts[0]["id"]],
                "expected_list_revision": revision,
            },
        )
        assert reordered.status_code == 200, reordered.text
        stale_order = client.put(
            "/api/v1/accounts/order",
            headers=auth,
            json={
                "ordered_ids": [accounts[0]["id"], accounts[1]["id"]],
                "expected_list_revision": revision,
            },
        )
        assert stale_order.status_code == 409
        details = stale_order.json()["error"]["details"]
        assert details["reason"] == "list_changed"
        assert details["reload_path"] == "/api/v1/accounts/order-state"

        stale_patch = client.patch(
            f"/api/v1/accounts/{accounts[0]['id']}",
            headers=auth,
            json={"expected_version": 999, "name": "stale"},
        )
        assert stale_patch.status_code == 409
        details = stale_patch.json()["error"]["details"]
        assert details["reason"] == "resource_changed"
        assert details["current_version"] == accounts[0]["version"] + 1
        assert details["expected_version"] == 999
        assert details["safe_to_reload"] is True
        assert details["resource"] == {
            "resource_type": "account",
            "resource_id": accounts[0]["id"],
            "reload_path": f"/api/v1/accounts/{accounts[0]['id']}",
        }

        transaction = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 10,
                "occurred_at": "2026-08-13T11:00:00+08:00",
                "title": "P30B action capability",
                "account_id": accounts[0]["id"],
            },
        )
        assert transaction.status_code == 201, transaction.text
        assert transaction.json()["available_actions"] == [
            {"action": "void", "enabled": True, "reason_code": None, "reason_message": None}
        ]
        voided = client.post(
            f"/api/v1/transactions/{transaction.json()['id']}/void",
            headers=auth,
            json={"expected_version": transaction.json()["version"]},
        )
        assert voided.status_code == 200, voided.text
        assert voided.json()["available_actions"] == [
            {
                "action": "void",
                "enabled": False,
                "reason_code": "transaction_already_voided",
                "reason_message": "The transaction is already voided",
            }
        ]


def test_p30b_category_order_conflicts_expose_reloadable_root_and_child_scopes() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL), readiness_check=ready
    )
    auth = {"Authorization": "Bearer p30b-category-token"}

    def create_category(
        client: TestClient, name: str, parent_id: str | None = None
    ) -> dict[str, str]:
        payload: dict[str, str] = {
            "name": f"{name} {uuid4().hex[:8]}",
            "direction": "expense",
            "icon": "tag",
            "color_hex": "#123456",
        }
        if parent_id is not None:
            payload["parent_id"] = parent_id
        response = client.post("/api/v1/categories", headers=auth, json=payload)
        assert response.status_code == 201, response.text
        return response.json()

    with TestClient(app) as client:
        parent = create_category(client, "P30B root")
        create_category(client, "P30B sibling")
        root_state = client.get("/api/v1/categories/order-state?direction=expense", headers=auth)
        assert root_state.status_code == 200, root_state.text
        root_ids = [item["id"] for item in root_state.json()["items"]]
        reversed_root_ids = list(reversed(root_ids))
        ordered = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={
                "parent_id": None,
                "ordered_ids": reversed_root_ids,
                "expected_list_revision": root_state.json()["list_revision"],
            },
        )
        assert ordered.status_code == 200, ordered.text
        root_stale = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={
                "parent_id": None,
                "ordered_ids": root_ids,
                "expected_list_revision": root_state.json()["list_revision"],
            },
        )
        assert root_stale.status_code == 409
        root_details = root_stale.json()["error"]["details"]
        assert root_details["order_scope"] == {"parent_id": None, "direction": "expense"}
        assert client.get(root_details["reload_path"], headers=auth).status_code == 200
        root_missing = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={"parent_id": None, "ordered_ids": reversed_root_ids},
        )
        assert root_missing.status_code == 409
        assert (
            client.get(
                root_missing.json()["error"]["details"]["reload_path"], headers=auth
            ).status_code
            == 200
        )

        create_category(client, "P30B child 甲", parent["id"])
        create_category(client, "P30B child 乙", parent["id"])
        child_state = client.get(
            f"/api/v1/categories/order-state?direction=expense&parent_id={parent['id']}",
            headers=auth,
        )
        assert child_state.status_code == 200, child_state.text
        child_ids = [item["id"] for item in child_state.json()["items"]]
        reversed_child_ids = list(reversed(child_ids))
        ordered = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={
                "parent_id": parent["id"],
                "ordered_ids": reversed_child_ids,
                "expected_list_revision": child_state.json()["list_revision"],
            },
        )
        assert ordered.status_code == 200, ordered.text
        child_stale = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={
                "parent_id": parent["id"],
                "ordered_ids": child_ids,
                "expected_list_revision": child_state.json()["list_revision"],
            },
        )
        assert child_stale.status_code == 409
        child_details = child_stale.json()["error"]["details"]
        assert child_details["order_scope"] == {
            "parent_id": parent["id"],
            "direction": "expense",
        }
        assert client.get(child_details["reload_path"], headers=auth).status_code == 200
        child_missing = client.put(
            "/api/v1/categories/order",
            headers=auth,
            json={"parent_id": parent["id"], "ordered_ids": reversed_child_ids},
        )
        assert child_missing.status_code == 409
        assert (
            client.get(
                child_missing.json()["error"]["details"]["reload_path"], headers=auth
            ).status_code
            == 200
        )
