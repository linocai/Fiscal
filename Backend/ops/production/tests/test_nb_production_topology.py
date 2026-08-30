from __future__ import annotations

import unittest
from pathlib import Path

PRODUCTION = Path(__file__).parents[1]
NB_README = (PRODUCTION / "nb" / "README.md").read_text(encoding="utf-8")
NB_API = (PRODUCTION / "nb" / "systemd" / "fiscal-api.service").read_text(
    encoding="utf-8"
)


class NBProductionTopologyTests(unittest.TestCase):
    def test_nb_api_uses_npm_bridge_without_changing_public_edge(self) -> None:
        self.assertIn("--host 0.0.0.0 --port 8010", NB_API)
        self.assertIn("--forwarded-allow-ips=172.18.0.2", NB_API)
        self.assertIn("Requires=postgresql.service docker.service", NB_API)
        self.assertNotIn("ExecStart=/usr/sbin/nginx", NB_API)

    def test_nb_contract_keeps_public_port_closed_and_postgres_loopback_only(self) -> None:
        self.assertIn("UFW allows TCP 8010 only from `172.18.0.0/16`", NB_README)
        self.assertIn("PostgreSQL 16 listens only on loopback", NB_README)
        self.assertIn("System Nginx remains inactive and disabled", NB_README)

    def test_nb_contract_is_fiscal_only_and_has_no_observation_period(self) -> None:
        self.assertIn("Fiscal-only target overlay", NB_README)
        self.assertIn("There is no observation period", NB_README)
        self.assertIn("all non-Fiscal resources remain untouched", NB_README)
        self.assertIn("DNS alone must not be pointed back to HZ", NB_README)

    def test_nb_contract_uses_npm_management_surface(self) -> None:
        self.assertIn("edit the NPM database or generated `proxy_host/*.conf` files", NB_README)
        self.assertIn("Forward host: `172.18.0.1`", NB_README)
        self.assertIn("Forward port: `8010`", NB_README)


if __name__ == "__main__":
    unittest.main()
