from __future__ import annotations

import asyncio
import json
from os import environ
from uuid import UUID, uuid4

import httpx
import pytest

from fiscal_api.db.models.statement_import import StatementImport, StatementImportAttempt
from fiscal_api.db.session import create_engine, create_session_factory
from test_p26_statement_provider_postgres import _client, _ledger_counts
from test_v221_statement_provider import adapter, result

pytestmark = pytest.mark.skipif(
    not environ.get("FISCAL_TEST_DATABASE_URL"), reason="requires PostgreSQL"
)
AUTH = {"Authorization": "Bearer v221-statement-token"}


def seed(client):
    batch = client.post(
        "/api/v1/statement-imports",
        headers=AUTH,
        json={
            "document_sha256": uuid4().hex * 2,
            "byte_size": 512,
            "page_count": 1,
            "mime_type": "application/pdf",
            "display_name": "statement.pdf",
        },
    ).json()
    path = f"/api/v1/statement-imports/{batch['id']}"
    started = client.post(
        path + "/attempts", headers=AUTH, json={"expected_version": batch["version"]}
    )
    text = "[REDACTED]\n2026-08-12 Grocery 18.50\n2026-08-12 Grocery 18.50"
    accepted = client.post(
        path + "/evidence",
        headers=AUTH,
        json={
            "expected_version": int(started.headers["X-Fiscal-Statement-Import-Version"]),
            "attempt_id": started.json()["id"],
            "pages": [
                {
                    "page_number": 1,
                    "source_kind": "text",
                    "evidence_text_masked": text,
                    "bounding_boxes": [],
                }
            ],
            "rows": [
                {
                    "row_number": n,
                    "page_number": 1,
                    "evidence_text_masked": "2026-08-12 Grocery 18.50",
                    "bounding_box": {"x": 0.1, "y": 0.1 * n, "width": 0.5, "height": 0.1},
                }
                for n in [1, 2]
            ],
        },
    )
    assert accepted.status_code == 200, accepted.text
    info = client.get(path + "/provider-authorization", headers=AUTH)
    assert info.headers["Cache-Control"] == "no-store"
    info = info.json()
    authorization = {
        k: v for k, v in info.items() if k not in {"batch_version", "configured", "description"}
    }
    return path, {
        "expected_version": info["batch_version"],
        "evidence_sha256": info["evidence_sha256"],
        "authorization": {**authorization, "confirmed": True},
    }


def test_v221_real_adapter_snapshot_partial_edit_and_receipt():
    calls = []

    def handle(request):
        calls.append(json.loads(request.content))
        parsed = result()
        parsed["candidates"] = [
            parsed["candidates"][0],
            {**parsed["candidates"][0], "source_row_numbers": [2]},
        ]
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(parsed)}}]})

    with _client(adapter(handle)) as client:
        path, request = seed(client)
        assert (
            client.get(path + "/recovery", headers=AUTH).json()["next_action"]
            == "authorize_provider"
        )
        key = str(uuid4())
        parsed = client.post(
            path + "/provider-attempts", headers={**AUTH, "Idempotency-Key": key}, json=request
        )
        assert parsed.status_code == 201, parsed.text
        parsed = parsed.json()
        assert parsed["provider_snapshot_id"] != parsed["provider_attempt_id"]
        assert parsed["provider_status"] == "succeeded"
        assert (
            client.get(path + f"/provider-attempts/by-idempotency/{key}", headers=AUTH).json()[
                "provider_snapshot_id"
            ]
            == parsed["provider_snapshot_id"]
        )
        review = client.post(
            path + "/validation-runs",
            headers=AUTH,
            json={
                "expected_batch_version": parsed["version"],
                "provider_snapshot_id": parsed["provider_snapshot_id"],
            },
        )
        assert review.status_code == 201, review.text
        assert asyncio.run(_ledger_counts()) == (0, 0)
        account = client.post(
            "/api/v1/accounts",
            headers=AUTH,
            json={"name": "V221 cash", "kind": "cash", "opening_balance_minor": 0},
        ).json()
        rows = client.get(path + "/review-workbench", headers=AUTH).json()["rows"]
        for index, row in enumerate(rows):
            current = client.get(path, headers=AUTH).json()
            resolution = client.put(
                path + f"/rows/{row['id']}/draft-resolution",
                headers=AUTH,
                json={
                    "expected_batch_version": current["version"],
                    "expected_row_version": row["row_version"],
                    "expected_resolution_version": 0,
                    "resolution": "create_new",
                },
            )
            assert resolution.status_code == 200, resolution.text
            final = client.put(
                path + f"/rows/{row['id']}/final-create-draft",
                headers=AUTH,
                json={
                    "expected_version": 0,
                    "expected_batch_version": resolution.json()["batch_version"],
                    "expected_row_version": row["row_version"],
                    "transaction": {
                        "kind": "expense",
                        "amount_minor": 1850,
                        "occurred_at": "2026-08-12T12:00:00+08:00",
                        "title": "Grocery",
                        "account_id": account["id"],
                    },
                },
            )
            assert final.status_code == 200, final.text
            preview = client.post(
                path + "/confirmation-preview", headers=AUTH, json={"row_ids": [row["id"]]}
            )
            assert preview.status_code == 200, preview.text
            confirm_key = str(uuid4())
            receipt = client.post(
                path + "/confirm",
                headers={**AUTH, "Idempotency-Key": confirm_key},
                json=preview.json()["request"],
            )
            assert receipt.status_code == 200, receipt.text
            assert receipt.json()["status"] == (
                "partially_confirmed" if index == 0 else "confirmed"
            )
            assert client.get(
                path + "/confirmation-receipt", headers={**AUTH, "Idempotency-Key": confirm_key}
            ).json()["confirmed_row_ids"] == [row["id"]]
            frozen = client.put(
                path + f"/rows/{row['id']}/final-create-draft",
                headers=AUTH,
                json={"expected_version": 1, "transaction": final.json()["transaction"]},
            )
            assert frozen.status_code == 409
        assert asyncio.run(_ledger_counts()) == (2, 2)
        assert len(calls) == 1
        assert client.get(path + "/recovery", headers=AUTH).json()["next_action"] == "completed"


def test_v221_orphan_started_is_finalized_only_by_original_post():
    def handle(_):
        return httpx.Response(
            200, json={"choices": [{"message": {"content": json.dumps(result())}}]}
        )

    with _client(adapter(handle)) as client:
        path, request = seed(client)
        key = str(uuid4())
        parsed = client.post(
            path + "/provider-attempts", headers={**AUTH, "Idempotency-Key": key}, json=request
        ).json()

        async def orphan():
            engine = create_engine(environ["FISCAL_TEST_DATABASE_URL"])
            try:
                async with create_session_factory(engine)() as session:
                    attempt = await session.get(StatementImportAttempt, UUID(parsed["attempt_id"]))
                    attempt.status = "started"
                    attempt.completed_at = None
                    batch = await session.get(StatementImport, UUID(parsed["id"]))
                    batch.status = "parsing"
                    await session.commit()
            finally:
                await engine.dispose()

        asyncio.run(orphan())
        assert (
            client.get(path + "/recovery", headers=AUTH).json()["next_action"] == "recover_provider"
        )
        replay = client.post(
            path + "/provider-attempts", headers={**AUTH, "Idempotency-Key": key}, json=request
        )
        assert replay.status_code == 200, replay.text
        assert replay.json()["provider_status"] == "failed"
        assert (
            client.get(path + "/recovery", headers=AUTH).json()["failure_reason"]
            == "statement_provider_interrupted"
        )


def test_v221_unconfigured_provider_has_no_synthetic_fallback():
    with _client(None) as client:
        path, _ = seed(client)
        info = client.get(path + "/provider-authorization", headers=AUTH).json()
        assert info["configured"] is False and info["provider"] is None


def test_v221_matching_scales_by_candidates_and_rechecks_revision(monkeypatch):
    from datetime import datetime
    from time import perf_counter

    from sqlalchemy import event, update

    from fiscal_api.api.p26_schemas import StatementProviderResult
    from fiscal_api.api.p27_schemas import StatementImportValidationRunCreate
    from fiscal_api.core.errors import APIError
    from fiscal_api.db.models.ledger import LedgerTransaction, Posting
    from fiscal_api.db.models.revision import DataRevision
    from fiscal_api.services.common import acquire_mutation_lock
    from fiscal_api.services.statement_import_review import StatementImportReviewService

    def handle(_):
        return httpx.Response(
            200, json={"choices": [{"message": {"content": json.dumps(result())}}]}
        )

    with _client(adapter(handle)) as client:
        path, request = seed(client)
        parsed = client.post(
            path + "/provider-attempts",
            headers={**AUTH, "Idempotency-Key": str(uuid4())},
            json=request,
        ).json()
        account = client.post(
            "/api/v1/accounts",
            headers=AUTH,
            json={"name": "Scale fixture cash", "kind": "cash", "opening_balance_minor": 0},
        ).json()

    async def exercise():
        engine = create_engine(environ["FISCAL_TEST_DATABASE_URL"])
        factory = create_session_factory(engine)
        statements = []
        timings = []

        def captured(_conn, _cursor, statement, parameters, _context, _many):
            statements.append((statement, parameters))

        event.listen(engine.sync_engine, "before_cursor_execute", captured)

        async def add(count, relevant):
            async with factory() as session:
                for _ in range(count):
                    session.add(
                        LedgerTransaction(
                            kind="expense",
                            occurred_at=datetime.fromisoformat(
                                "2026-08-12T12:00:00+08:00"
                                if relevant
                                else "2020-01-01T12:00:00+08:00"
                            ),
                            title="Scale fixture",
                            idempotency_key=uuid4(),
                            request_hash="0" * 64,
                            postings=[
                                Posting(
                                    account_id=UUID(account["id"]),
                                    role="account",
                                    amount_minor=-1850,
                                    position=0,
                                )
                            ],
                        )
                    )
                await session.commit()

        async def measured(candidates):
            statements.clear()
            async with factory() as session:
                started = perf_counter()
                matched = await StatementImportReviewService(session)._matching_transactions(
                    candidates
                )
                timings.append(round((perf_counter() - started) * 1000, 2))
            return len(statements), sum(map(len, matched.values()))

        try:
            one = StatementProviderResult.model_validate(result())
            await add(1, True)
            baseline = await measured(one)
            await add(2499, False)
            unrelated = await measured(one)
            many_result = result()
            many_result["candidates"] = [
                {**many_result["candidates"][0], "raw_amount": f"{n}.50"} for n in range(1, 201)
            ]
            many = await measured(StatementProviderResult.model_validate(many_result))
            assert baseline == unrelated == many == (1, 1)
            statement, parameters = statements[0]
            async with engine.connect() as connection:
                plan = (
                    await connection.exec_driver_sql(
                        "EXPLAIN (FORMAT JSON) " + statement, parameters
                    )
                ).scalar_one()
            print(
                {
                    "matching_scale": {
                        "one": baseline,
                        "2500_history": unrelated,
                        "200_candidates": many,
                        "milliseconds": timings,
                    },
                    "explain": plan,
                }
            )
            statements.clear()

            class InterleavedReview(StatementImportReviewService):
                async def _matching_transactions(self, value):
                    matched = await super()._matching_transactions(value)
                    async with factory() as writer:
                        await acquire_mutation_lock(writer)
                        await writer.execute(
                            update(DataRevision).values(revision=DataRevision.revision + 1)
                        )
                        await writer.commit()
                    return matched

            async with factory() as session:
                with pytest.raises(APIError) as failure:
                    await InterleavedReview(session).start_run(
                        UUID(parsed["id"]),
                        StatementImportValidationRunCreate(
                            expected_batch_version=parsed["version"],
                            provider_snapshot_id=UUID(parsed["provider_snapshot_id"]),
                        ),
                    )
                assert failure.value.code == "statement_import_matching_stale"
            sql = [entry[0] for entry in statements]
            matching = next(i for i, query in enumerate(sql) if "JOIN postings" in query)
            lock = next(i for i, query in enumerate(sql) if "pg_advisory_xact_lock" in query)
            assert matching < lock
        finally:
            event.remove(engine.sync_engine, "before_cursor_execute", captured)
            await engine.dispose()

    asyncio.run(exercise())
