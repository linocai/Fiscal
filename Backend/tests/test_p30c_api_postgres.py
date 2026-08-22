import base64
import json
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event
from sqlalchemy.engine import Engine

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.repositories.accounts import AccountRepository
from fiscal_api.services import reimbursements as reimbursements_service_module

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
        {"Authorization": "Bearer p30c-token"},
    )


def _encode_cursor_payload(payload: object) -> str:
    return (
        base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode())
        .decode()
        .rstrip("=")
    )


def _create_account(
    client: TestClient, auth: dict[str, str], name: str, kind: str
) -> dict[str, object]:
    payload: dict[str, object] = {
        "name": f"{name} {uuid4().hex[:8]}",
        "kind": kind,
        "opening_balance_minor": 0,
    }
    if kind == "credit":
        payload.update(
            {
                "credit_limit_minor": 10_000,
                "statement_day": 1,
                "due_day": 2,
            }
        )
    response = client.post(
        "/api/v1/accounts",
        headers=auth,
        json=payload,
    )
    assert response.status_code == 201, response.text
    return response.json()


def _create_expense(
    client: TestClient,
    auth: dict[str, str],
    account_id: str,
    *,
    amount_minor: int,
    title: str,
    occurred_at: str = "2026-08-14T09:00:00+08:00",
) -> dict[str, object]:
    response = client.post(
        "/api/v1/transactions",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json={
            "kind": "expense",
            "amount_minor": amount_minor,
            "occurred_at": occurred_at,
            "title": title,
            "account_id": account_id,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _claim_payload(transaction_id: str, amount_minor: int) -> dict[str, object]:
    return {
        "title": "P30-C 报销",
        "parties": [
            {
                "name": "公司",
                "expected_date": "2026-08-31",
                "allocations": [{"transaction_id": transaction_id, "amount_minor": amount_minor}],
            }
        ],
    }


def _assert_validation_path(response: object, path: list[object]) -> None:
    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    assert any(item["loc"] == ["body", *path] for item in body["error"]["details"])


def test_p30c_uncategorized_candidate_and_draft_diagnostics() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        debit = _create_account(client, auth, "P30-C 借记", "debit")
        expense = _create_expense(
            client,
            auth,
            str(debit["id"]),
            amount_minor=10_000,
            title="未分类垫付",
        )

        candidates = client.get("/api/v1/reimbursement-expense-candidates", headers=auth)
        assert candidates.status_code == 200, candidates.text
        candidate = next(
            item for item in candidates.json()["items"] if item["transaction_id"] == expense["id"]
        )
        assert candidate["category_id"] is None
        assert candidate["eligibility"] == {
            "eligible": True,
            "transaction_id": expense["id"],
            "canonical_amount_minor": 10_000,
            "allocated_minor": 0,
            "available_minor": 10_000,
            "reasons": [],
            "reason_details": [],
        }
        legacy_options = client.get("/api/v1/reimbursement-expense-options", headers=auth)
        assert legacy_options.status_code == 200, legacy_options.text
        assert expense["id"] not in {item["transaction_id"] for item in legacy_options.json()}

        for mutate, path in (
            (lambda payload: payload.update(title=" "), ["title"]),
            (lambda payload: payload.update(parties=[]), ["parties"]),
            (
                lambda payload: payload["parties"][0].update(name=" "),
                ["parties", 0, "name"],
            ),
            (
                lambda payload: payload["parties"][0].update(allocations=[]),
                ["parties", 0, "allocations"],
            ),
            (
                lambda payload: payload["parties"][0]["allocations"][0].update(amount_minor=0),
                ["parties", 0, "allocations", 0, "amount_minor"],
            ),
        ):
            malformed = _claim_payload(str(expense["id"]), 1)
            mutate(malformed)
            _assert_validation_path(
                client.post(
                    "/api/v1/reimbursement-claims",
                    headers={**auth, "Idempotency-Key": str(uuid4())},
                    json=malformed,
                ),
                path,
            )

        duplicate = _claim_payload(str(expense["id"]), 5_000)
        duplicate["parties"] = [
            duplicate["parties"][0],
            {
                "name": "同一交易",
                "allocations": [{"transaction_id": expense["id"], "amount_minor": 5_000}],
            },
        ]
        duplicate_response = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=duplicate,
        )
        assert duplicate_response.status_code == 422
        assert duplicate_response.json()["error"] == {
            "code": "reimbursement_duplicate_transaction",
            "message": "A source transaction can be allocated only once in a claim",
            "request_id": duplicate_response.json()["error"]["request_id"],
            "details": {
                "reason": "duplicate_transaction",
                "field_path": "parties[1].allocations[0].transaction_id",
                "duplicate_of": "parties[0].allocations[0].transaction_id",
                "transaction_id": expense["id"],
            },
        }

        created = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=_claim_payload(str(expense["id"]), 10_000),
        )
        assert created.status_code == 201, created.text
        replace_duplicate = _claim_payload(str(expense["id"]), 5_000)
        replace_duplicate["parties"] = [
            replace_duplicate["parties"][0],
            {
                "name": "替换重复",
                "allocations": [{"transaction_id": expense["id"], "amount_minor": 5_000}],
            },
        ]
        replace_duplicate["expected_version"] = created.json()["version"]
        revision_before_duplicate_preview = client.get(
            "/api/v1/data-revision", headers=auth
        ).json()["revision"]
        replace_preview = client.post(
            f"/api/v1/reimbursement-claims/{created.json()['id']}/preview",
            headers=auth,
            json=replace_duplicate,
        )
        assert replace_preview.status_code == 422
        replace_error = replace_preview.json()["error"]
        assert replace_error["code"] == "reimbursement_duplicate_transaction"
        assert replace_error["details"]["field_path"] == (
            "parties[1].allocations[0].transaction_id"
        )
        assert "preview_token" not in replace_preview.json()
        unchanged = client.get(f"/api/v1/reimbursement-claims/{created.json()['id']}", headers=auth)
        assert unchanged.status_code == 200, unchanged.text
        assert unchanged.json()["version"] == created.json()["version"]
        assert unchanged.json()["total_claimed_minor"] == created.json()["total_claimed_minor"]
        assert client.get("/api/v1/data-revision", headers=auth).json()["revision"] == (
            revision_before_duplicate_preview
        )
        unavailable = client.get(
            f"/api/v1/transactions/{expense['id']}/reimbursement-eligibility", headers=auth
        )
        assert unavailable.status_code == 200, unavailable.text
        assert unavailable.json()["reasons"] == ["fully_allocated"]
        assert unavailable.json()["reason_details"] == [
            {
                "code": "fully_allocated",
                "message": "No reimbursable capacity remains for this transaction",
                "field_path": "amount_minor",
            }
        ]
        disabled_candidate = next(
            item
            for item in client.get("/api/v1/reimbursement-expense-candidates", headers=auth).json()[
                "items"
            ]
            if item["transaction_id"] == expense["id"]
        )
        assert disabled_candidate["eligibility"] == unavailable.json()

        income = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "income",
                "amount_minor": 1,
                "occurred_at": "2026-08-14T10:00:00+08:00",
                "title": "报销不可选收入",
                "account_id": debit["id"],
            },
        )
        assert income.status_code == 201, income.text
        ineligible = client.get(
            f"/api/v1/transactions/{income.json()['id']}/reimbursement-eligibility",
            headers=auth,
        )
        assert ineligible.json()["reasons"] == ["not_eligible_expense"]

        voidable = _create_expense(
            client,
            auth,
            str(debit["id"]),
            amount_minor=1,
            title="报销已作废支出",
        )
        voided = client.post(
            f"/api/v1/transactions/{voidable['id']}/void",
            headers=auth,
            json={"expected_version": voidable["version"]},
        )
        assert voided.status_code == 200, voided.text
        voided_eligibility = client.get(
            f"/api/v1/transactions/{voidable['id']}/reimbursement-eligibility",
            headers=auth,
        )
        assert voided_eligibility.json()["reasons"] == ["not_eligible_expense"]

        over_capacity_expense = _create_expense(
            client,
            auth,
            str(debit["id"]),
            amount_minor=100,
            title="容量校验",
        )
        over_capacity = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=_claim_payload(str(over_capacity_expense["id"]), 101),
        )
        assert over_capacity.status_code == 409
        assert over_capacity.json()["error"]["details"] == {
            "reason": "insufficient_reimbursable_capacity",
            "field_path": "parties[0].allocations[0].amount_minor",
            "transaction_id": over_capacity_expense["id"],
            "available_minor": 100,
        }

        malformed_date = _claim_payload(str(over_capacity_expense["id"]), 1)
        malformed_date["parties"][0]["expected_date"] = "2026-08-31T00:00:00+08:00"
        date_error = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=malformed_date,
        )
        _assert_validation_path(
            date_error,
            [
                "parties",
                0,
                "expected_date",
            ],
        )


def test_p30c_candidate_page_is_cursor_stable_and_constant_query_count() -> None:
    app, auth = _app()
    marker = f"P30C-page-{uuid4().hex[:8]}"
    with TestClient(app) as client:
        debit = _create_account(client, auth, "P30-C 分页借记", "debit")
        entries = [
            _create_expense(
                client,
                auth,
                str(debit["id"]),
                amount_minor=100 + offset,
                title=f"{marker}-{offset}",
                occurred_at=f"2026-08-{10 + offset:02d}T09:00:00+08:00",
            )
            for offset in range(4)
        ]
        fully_allocated = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=_claim_payload(str(entries[1]["id"]), 101),
        )
        assert fully_allocated.status_code == 201, fully_allocated.text

        first = client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={"limit": 2, "query": marker},
        )
        assert first.status_code == 200, first.text
        first_page = first.json()
        assert [item["transaction_id"] for item in first_page["items"]] == [
            entries[3]["id"],
            entries[2]["id"],
        ]
        assert first_page["next_cursor"]

        second = client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={"limit": 2, "query": marker, "cursor": first_page["next_cursor"]},
        )
        assert second.status_code == 200, second.text
        assert [item["transaction_id"] for item in second.json()["items"]] == [
            entries[1]["id"],
            entries[0]["id"],
        ]
        assert second.json()["next_cursor"] is None
        assert second.json()["items"][0]["eligibility"]["reasons"] == ["fully_allocated"]

        dated = client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={"query": marker, "date_from": "2026-08-12", "date_to": "2026-08-12"},
        )
        assert [item["transaction_id"] for item in dated.json()["items"]] == [entries[2]["id"]]
        mismatched = client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={
                "limit": 2,
                "query": f"{marker}-other",
                "cursor": first_page["next_cursor"],
            },
        )
        assert mismatched.status_code == 422
        assert mismatched.json()["error"]["code"] == "invalid_reimbursement_candidate_cursor"

        raw_cursor = first_page["next_cursor"]
        decoded_cursor = json.loads(
            base64.urlsafe_b64decode(raw_cursor + "=" * (-len(raw_cursor) % 4))
        )
        decoded_cursor["filters"] = "0" * 64
        tampered_fingerprint = (
            base64.urlsafe_b64encode(json.dumps(decoded_cursor, separators=(",", ":")).encode())
            .decode()
            .rstrip("=")
        )
        for invalid_cursor in ("x", "abcde", "_w", "bm90LWpzb24", tampered_fingerprint):
            cursor_error = client.get(
                "/api/v1/reimbursement-expense-candidates",
                headers=auth,
                params={"limit": 2, "query": marker, "cursor": invalid_cursor},
            )
            assert cursor_error.status_code == 422, cursor_error.text
            assert cursor_error.json()["error"]["code"] == "invalid_reimbursement_candidate_cursor"
        for invalid_limit in (0, 101):
            limit_error = client.get(
                "/api/v1/reimbursement-expense-candidates",
                headers=auth,
                params={"limit": invalid_limit},
            )
            assert limit_error.status_code == 422
            assert limit_error.json()["error"]["code"] == "validation_error"

        statements: list[str] = []

        def count_statement(*args: object) -> None:
            statements.append(str(args[2]))

        event.listen(Engine, "before_cursor_execute", count_statement)
        try:
            one_item = client.get(
                "/api/v1/reimbursement-expense-candidates",
                headers=auth,
                params={"limit": 1, "query": marker},
            )
            assert one_item.status_code == 200, one_item.text
            single_count = len(statements)
            statements.clear()
            four_items = client.get(
                "/api/v1/reimbursement-expense-candidates",
                headers=auth,
                params={"limit": 4, "query": marker},
            )
            assert four_items.status_code == 200, four_items.text
            page_count = len(statements)
        finally:
            event.remove(Engine, "before_cursor_execute", count_statement)
        assert single_count <= 4
        assert page_count <= single_count + 1


@pytest.mark.parametrize(
    "payload",
    [
        {"v": 1, "filters": "__current__", "occurred_at": "2026-08-14T00:00:00+00:00", "id": 1},
        {"v": 1, "filters": "__current__", "occurred_at": "2026-08-14T00:00:00+00:00", "id": []},
        {"v": 1, "filters": "__current__", "occurred_at": "2026-08-14T00:00:00+00:00", "id": {}},
        {"v": 1, "filters": "__current__", "occurred_at": "2026-08-14T00:00:00+00:00", "id": True},
        {
            "v": 1,
            "filters": "__current__",
            "occurred_at": "2026-08-14T00:00:00+00:00",
            "id": "not-a-uuid",
        },
        {"v": 1, "filters": "__current__", "occurred_at": 1, "id": str(uuid4())},
        {"v": 1, "filters": "__current__", "occurred_at": "not-a-date", "id": str(uuid4())},
        {"v": 1, "filters": 1, "occurred_at": "2026-08-14T00:00:00+00:00", "id": str(uuid4())},
        {
            "v": True,
            "filters": "__current__",
            "occurred_at": "2026-08-14T00:00:00+00:00",
            "id": str(uuid4()),
        },
        {
            "v": "1",
            "filters": "__current__",
            "occurred_at": "2026-08-14T00:00:00+00:00",
            "id": str(uuid4()),
        },
        {
            "v": 2,
            "filters": "__current__",
            "occurred_at": "2026-08-14T00:00:00+00:00",
            "id": str(uuid4()),
        },
        {"v": 1, "filters": "__current__", "occurred_at": "2026-08-14T00:00:00+00:00"},
        [],
        None,
    ],
)
def test_p30c_candidate_cursor_schema_rejects_invalid_payloads(payload: object) -> None:
    app, auth = _app()
    if isinstance(payload, dict) and payload.get("filters") == "__current__":
        current_filters = (
            reimbursements_service_module.ReimbursementService._candidate_filter_fingerprint(
                query=None,
                date_from=None,
                date_to=None,
            )
        )
        payload = {
            **payload,
            "filters": current_filters,
        }
    with TestClient(app) as client:
        response = client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={"cursor": _encode_cursor_payload(payload)},
        )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "invalid_reimbursement_candidate_cursor"


def test_p30c_candidate_cursor_does_not_mask_unexpected_decoder_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app, auth = _app()

    def unexpected_decoder_error(_: str) -> bytes:
        raise RuntimeError("decoder unavailable")

    monkeypatch.setattr(
        reimbursements_service_module.base64,
        "urlsafe_b64decode",
        unexpected_decoder_error,
    )
    with TestClient(app) as client, pytest.raises(RuntimeError, match="decoder unavailable"):
        client.get(
            "/api/v1/reimbursement-expense-candidates",
            headers=auth,
            params={"cursor": "x"},
        )


def test_p30c_receipt_account_options_distinguish_empty_and_load_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app, auth = _app()
    with TestClient(app) as client:
        empty = client.get("/api/v1/reimbursement-receipt-account-options", headers=auth)
        assert empty.status_code == 200, empty.text
        assert empty.json() == {"items": []}

        cash = _create_account(client, auth, "P30-C 现金", "cash")
        debit = _create_account(client, auth, "P30-C 借记", "debit")
        credit = _create_account(client, auth, "P30-C 信用", "credit")
        archived = _create_account(client, auth, "P30-C 已归档", "cash")
        archived_response = client.post(
            f"/api/v1/accounts/{archived['id']}/archive",
            headers=auth,
            json={"expected_version": archived["version"]},
        )
        assert archived_response.status_code == 200, archived_response.text

        options = client.get("/api/v1/reimbursement-receipt-account-options", headers=auth)
        assert options.status_code == 200, options.text
        assert {item["id"] for item in options.json()["items"]} == {cash["id"], debit["id"]}
        assert {item["kind"] for item in options.json()["items"]} == {"cash", "debit"}
        assert credit["id"] not in {item["id"] for item in options.json()["items"]}
        assert archived["id"] not in {item["id"] for item in options.json()["items"]}

    async def unavailable(_self: AccountRepository) -> list[object]:
        raise RuntimeError("database unavailable")

    monkeypatch.setattr(AccountRepository, "receipt_destination_accounts", unavailable)
    with TestClient(app, raise_server_exceptions=False) as client:
        failed = client.get("/api/v1/reimbursement-receipt-account-options", headers=auth)
    assert failed.status_code == 500
    assert failed.json()["error"]["code"] == "internal_error"
    assert "items" not in failed.json()
