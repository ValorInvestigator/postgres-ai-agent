"""BigQuery service-account authentication boilerplate.

For the 27 tables in valorinvestigates.valor_investigations that are NOT
mirrored to local Postgres (see feedback_query_bigquery_for_specialized_tables
memory rule). Includes patty_text_messages (2,383 rows), null_550_for_vertex
(13,771 rows), recording_transcripts (402 rows), oregon_legal_cases (1,670 rows).

Confidence grade: A (BigQuery REST API is documented + stable).
"""

from __future__ import annotations

import json
import os
import urllib.request
from typing import Any, Optional

from google.oauth2 import service_account
import google.auth.transport.requests as tr


DEFAULT_KEY_PATH = "/home/levi/.claude/keys/valorinvestigates-bigquery.json"
DEFAULT_PROJECT = "valorinvestigates"
DEFAULT_DATASET = "valor_investigations"
DEFAULT_LOCATION = "us-west1"


class BigQueryClient:
    """Lightweight BigQuery REST client using service-account auth.

    For heavy use, switch to the google-cloud-bigquery library. For one-off
    queries in agent code, this is enough and zero dependencies beyond what
    is already installed.
    """

    def __init__(
        self,
        key_path: str = DEFAULT_KEY_PATH,
        project: str = DEFAULT_PROJECT,
        dataset: str = DEFAULT_DATASET,
    ) -> None:
        self.project = project
        self.dataset = dataset
        self.creds = service_account.Credentials.from_service_account_file(
            key_path, scopes=["https://www.googleapis.com/auth/bigquery"]
        )

    def _token(self) -> str:
        if not self.creds.valid:
            self.creds.refresh(tr.Request())
        return self.creds.token

    def list_tables(self) -> list[str]:
        """Return all table IDs in the dataset."""
        url = (
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{self.project}"
            f"/datasets/{self.dataset}/tables?maxResults=200"
        )
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self._token()}"})
        resp = urllib.request.urlopen(req, timeout=30).read().decode()
        j = json.loads(resp)
        return [t["tableReference"]["tableId"] for t in j.get("tables", [])]

    def query(self, sql: str, timeout_ms: int = 30000) -> list[dict[str, Any]]:
        """Execute SQL and return rows as dicts (column name -> string value)."""
        body = json.dumps({"query": sql, "useLegacySql": False, "timeoutMs": timeout_ms}).encode()
        req = urllib.request.Request(
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{self.project}/queries",
            data=body,
            headers={
                "Authorization": f"Bearer {self._token()}",
                "Content-Type": "application/json",
            },
        )
        resp = urllib.request.urlopen(req, timeout=timeout_ms / 1000 + 5).read().decode()
        j = json.loads(resp)
        if "rows" not in j:
            return []
        schema = [field["name"] for field in j["schema"]["fields"]]
        rows: list[dict[str, Any]] = []
        for r in j["rows"]:
            row: dict[str, Any] = {}
            for i, cell in enumerate(r["f"]):
                row[schema[i]] = cell["v"]
            rows.append(row)
        return rows

    def count(self, table: str) -> int:
        """Quick row count for a table in the configured dataset."""
        sql = f"SELECT COUNT(*) c FROM `{self.project}.{self.dataset}.{table}`"
        rows = self.query(sql)
        if not rows:
            return 0
        return int(rows[0]["c"])


# Recipe: patty_text_messages search
# bq = BigQueryClient()
# rows = bq.query("""
#     SELECT sender, recipient, body, timestamp
#     FROM `valorinvestigates.valor_investigations.patty_text_messages`
#     WHERE LOWER(body) LIKE '%bartell%'
#     ORDER BY timestamp DESC
#     LIMIT 50
# """)

# Recipe: null_550 OCR full-text search
# rows = bq.query("""
#     SELECT case_id, page, LEFT(content, 200) AS preview
#     FROM `valorinvestigates.valor_investigations.null_550_for_vertex`
#     WHERE REGEXP_CONTAINS(LOWER(content), r'\\bguardianship\\b')
#     LIMIT 100
# """)

# Recipe: oregon_legal_cases citation lookup
# rows = bq.query("""
#     SELECT case_name, citation, decision_date
#     FROM `valorinvestigates.valor_investigations.oregon_legal_cases`
#     WHERE LOWER(case_name) LIKE '%merrick%city of portland%'
# """)
