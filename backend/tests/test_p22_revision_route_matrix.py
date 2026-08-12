from fastapi.routing import APIRoute

from fiscal_api.main import create_app

ALLOWED_SCOPES = {
    "ledger",
    "accounts",
    "credit",
    "reimbursements",
    "cash_flow",
    "reconciliation",
    "attention",
    "reports",
    "ai",
    "statement_imports",
}
READ_ONLY_POSTS = {
    "/api/v1/auth/session",
    "/api/v1/auth/passphrase/change",
    "/api/v1/archives/export",
    "/api/v1/credit-accounts/{account_id}/schedule-change-preview",
    "/api/v1/installment-purchases/preview",
    "/api/v1/installment-plans/{plan_id}/preview",
    "/api/v1/installment-plans/{plan_id}/settlement-preview",
    "/api/v1/installment-plans/{plan_id}/reverse-settlement-preview",
    "/api/v1/installment-plans/{plan_id}/cancel-preview",
    "/api/v1/reimbursement-claims/{claim_id}/preview",
    "/api/v1/reimbursement-claims/{claim_id}/cancel-preview",
    "/api/v1/reimbursement-claims/{claim_id}/receipt-preview",
    "/api/v1/reimbursement-receipts/{receipt_id}/preview",
}


def test_p22_every_formal_write_route_declares_scopes() -> None:
    for route in create_app().routes:
        if not isinstance(route, APIRoute):
            continue
        scopes = [
            getattr(dependency.dependency, "fiscal_mutation_scopes", None)
            for dependency in route.dependencies
        ]
        mutation_scopes = next((value for value in scopes if value is not None), None)
        needs_receipt = bool({"PUT", "PATCH", "DELETE"} & route.methods) or (
            "POST" in route.methods and route.path not in READ_ONLY_POSTS
        )
        assert bool(mutation_scopes) is needs_receipt, route.path
        if mutation_scopes is not None:
            assert set(mutation_scopes) <= ALLOWED_SCOPES
