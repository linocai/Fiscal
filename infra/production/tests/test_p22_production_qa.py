from __future__ import annotations

import importlib.util
import io
import unittest
from pathlib import Path
from unittest.mock import patch


PATH = Path(__file__).parents[1] / "scripts" / "p22-production-qa.py"
SPEC = importlib.util.spec_from_file_location("p22_production_qa", PATH)
assert SPEC and SPEC.loader
qa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qa)


class Response:
    def __init__(self, body: dict[str, object], headers: dict[str, str]) -> None:
        self.body, self.headers = body, headers
    def __enter__(self): return self
    def __exit__(self, *_): return None
    def read(self): import json; return json.dumps(self.body).encode()


class ProductionQATests(unittest.TestCase):
    def test_success_and_parse_failure_still_delete(self) -> None:
        headers = {"X-Fiscal-Data-Revision": "1", "X-Fiscal-Affected-Scopes": ",".join(qa.EXPECTED_SCOPES)}
        deleted = {"count": 0}
        def open_(request, timeout=20):
            if request.method == "POST": return Response({"id":"id","version":1}, headers)
            deleted["count"] += 1; return Response({}, {"X-Fiscal-Data-Revision":"2", "X-Fiscal-Affected-Scopes":headers["X-Fiscal-Affected-Scopes"]})
        with patch.object(qa, "urlopen", open_), patch("sys.stdin", io.StringIO("secret\n")), patch("sys.stdout", io.StringIO()): qa.main([])
        self.assertGreaterEqual(deleted["count"], 1)
        bad = dict(headers); bad.pop("X-Fiscal-Affected-Scopes")
        deleted["count"] = 0
        def badopen(request, timeout=20):
            if request.method == "POST": return Response({"id":"id","version":1}, bad)
            deleted["count"] += 1; return Response({}, {})
        with self.assertRaises(RuntimeError), patch.object(qa, "urlopen", badopen), patch("sys.stdin", io.StringIO("secret\n")): qa.main([])
        self.assertEqual(deleted["count"], 1)

    def test_delete_failure_is_explicit_and_secret_is_not_output(self) -> None:
        headers = {"X-Fiscal-Data-Revision": "1", "X-Fiscal-Affected-Scopes": ",".join(qa.EXPECTED_SCOPES)}
        def fail(request, timeout=20):
            if request.method == "POST": return Response({"id":"id","version":1}, headers)
            raise OSError("delete unavailable")
        output = io.StringIO()
        with self.assertRaisesRegex(RuntimeError, "cleanup delete failed"), patch.object(qa, "urlopen", fail), patch("sys.stdin", io.StringIO("SENTINEL_SECRET\n")), patch("sys.stdout", output), patch("sys.stderr", output): qa.main([])
        self.assertNotIn("SENTINEL_SECRET", output.getvalue())
