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
    "/api/v1/statement-imports/{statement_import_id}/confirmation-preview",
    "/api/v1/categories/{source_id}/merge-preview",
    "/api/v1/categories/{root_id}/split-preview",
}


def _api_routes(router: object) -> list[APIRoute]:
    routes = getattr(router, "routes", [])
    result: list[APIRoute] = []
    for route in routes:
        if isinstance(route, APIRoute):
            result.append(route)
        elif hasattr(route, "original_router"):
            result.extend(_api_routes(route.original_router))
    return result


def test_p22_every_formal_write_route_declares_scopes() -> None:
    app = create_app()
    included = [route for route in app.routes if hasattr(route, "original_router")]
    assert len(included) == 1
    routes = _api_routes(included[0].original_router)
    assert len(routes) >= 40
    seen_operational_posts: set[str] = set()
    for route in routes:
        scopes = [
            getattr(dependency.dependency, "fiscal_mutation_scopes", None)
            for dependency in route.dependencies
        ]
        mutation_scopes = next((value for value in scopes if value is not None), None)
        path = f"/api/v1{route.path}"
        needs_receipt = bool({"PUT", "PATCH", "DELETE"} & route.methods) or (
            "POST" in route.methods and path not in READ_ONLY_POSTS
        )
        if "POST" in route.methods and path in READ_ONLY_POSTS:
            seen_operational_posts.add(path)
        assert bool(mutation_scopes) is needs_receipt, path
        if mutation_scopes is not None:
            assert set(mutation_scopes) <= ALLOWED_SCOPES
    assert READ_ONLY_POSTS <= seen_operational_posts
