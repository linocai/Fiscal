from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_exact_merchant_suggestion_requires_confirmation_and_supports_correction() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer merchant-mapping-test"}
    with TestClient(app) as client:
        account_response = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={"name": "Merchant test account", "kind": "debit", "opening_balance_minor": 0},
        )
        assert account_response.status_code == 201, account_response.text
        account_id = account_response.json()["id"]

        def expense(title: str) -> dict[str, object]:
            response = client.post(
                "/api/v1/transactions",
                headers={**auth, "Idempotency-Key": str(uuid4())},
                json={
                    "kind": "expense",
                    "amount_minor": 1_000,
                    "occurred_at": "2026-09-26T12:00:00+08:00",
                    "title": title,
                    "account_id": account_id,
                },
            )
            assert response.status_code == 201, response.text
            return response.json()

        first, alias_match, unmatched = (
            expense("瑞幸咖啡"),
            expense("  LUCKIN  "),
            expense("瑞幸咖啡 买咖啡"),
        )
        path = f"/api/v1/transactions/{first['id']}/merchant-mapping"
        empty = client.get(path, headers=auth)
        assert empty.status_code == 200
        assert empty.json() == {"mapping": None, "suggested_merchant": None}

        def merchant_totals() -> dict[str, int]:
            report = client.get("/api/v1/reports/v2/monthly/2026-09", headers=auth)
            assert report.status_code == 200, report.text
            return {
                item["merchant_name"]: item["transaction_count"]
                for item in report.json()["merchants"]
            }

        assert merchant_totals() == {"未映射商户": 3}

        key = str(uuid4())
        payload = {"merchant_name": "瑞幸咖啡", "aliases": ["Luckin"]}
        confirmed = client.put(path, headers={**auth, "Idempotency-Key": key}, json=payload)
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()["action"] == "confirmed"
        assert confirmed.json()["mapping"]["provenance"] == "user_confirmed"
        merchant_id = confirmed.json()["mapping"]["merchant"]["id"]
        assert merchant_totals() == {"瑞幸咖啡": 1, "未映射商户": 2}
        replay_confirmation = client.put(
            path, headers={**auth, "Idempotency-Key": key}, json=payload
        )
        assert replay_confirmation.json() == confirmed.json()

        alias_path = f"/api/v1/transactions/{alias_match['id']}/merchant-mapping"
        suggestion = client.get(alias_path, headers=auth)
        assert suggestion.status_code == 200
        assert suggestion.json()["mapping"] is None
        assert suggestion.json()["suggested_merchant"]["id"] == merchant_id
        assert client.get(
            f"/api/v1/transactions/{unmatched['id']}/merchant-mapping", headers=auth
        ).json() == {"mapping": None, "suggested_merchant": None}

        accepted = client.put(
            alias_path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"merchant_name": "LUCKIN"},
        )
        assert accepted.status_code == 200, accepted.text
        assert accepted.json()["mapping"]["merchant"]["id"] == merchant_id
        assert client.get(alias_path, headers=auth).json()["suggested_merchant"] is None
        assert merchant_totals() == {"瑞幸咖啡": 2, "未映射商户": 1}

        stale = client.put(
            path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"merchant_name": "另一商户", "expected_mapping_version": 999},
        )
        assert stale.status_code == 409
        original_version = confirmed.json()["mapping"]["mapping_version"]
        corrected = client.put(
            path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "merchant_name": "另一商户",
                "expected_mapping_version": original_version,
            },
        )
        assert corrected.status_code == 200, corrected.text
        assert corrected.json()["action"] == "corrected"
        assert corrected.json()["mapping"]["merchant"]["id"] != merchant_id
        corrected_version = corrected.json()["mapping"]["mapping_version"]
        assert corrected_version > original_version

        conflict = client.put(
            path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "merchant_name": "另一商户",
                "aliases": ["Luckin"],
                "expected_mapping_version": corrected_version,
            },
        )
        assert conflict.status_code == 409
        released_key = str(uuid4())
        released = client.request(
            "DELETE",
            path,
            headers={**auth, "Idempotency-Key": released_key},
            json={"expected_mapping_version": corrected_version},
        )
        assert released.status_code == 200, released.text
        assert released.json()["action"] == "released"
        assert released.json()["mapping"] is None
        replay = client.request(
            "DELETE",
            path,
            headers={**auth, "Idempotency-Key": released_key},
            json={"expected_mapping_version": corrected_version},
        )
        assert replay.json() == released.json()
        assert client.get(path, headers=auth).json()["suggested_merchant"]["id"] == merchant_id
        # A deleted mapping cannot be recreated with an old mapping version.
        stale_recreate = client.put(
            path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"merchant_name": "瑞幸咖啡", "expected_mapping_version": corrected_version},
        )
        assert stale_recreate.status_code == 409
        again = client.put(
            path,
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"merchant_name": "瑞幸咖啡"},
        )
        assert again.status_code == 200, again.text
        assert again.json()["mapping"]["mapping_version"] > corrected_version
