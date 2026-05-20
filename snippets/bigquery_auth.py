"""BigQuery service-account authentication boilerplate.

For corpora that live in BigQuery rather than (or in addition to) the local
Postgres workhorse schemas. The skill is Postgres-first, but BQ tables exist
that are not yet mirrored to PG; this snippet is the minimal auth surface
those agents need.

Credentials resolve in this order (first wins):

  1. Explicit ``key_path`` argument passed to ``BigQueryClient(...)``.
  2. The ``GOOGLE_APPLICATION_CREDENTIALS`` environment variable.
  3. ``None`` -- raises a clear error so the caller fixes the wiring.

Set ``GOOGLE_APPLICATION_CREDENTIALS`` in your shell or .env file pointing at
your service-account JSON key (e.g., ``export
GOOGLE_APPLICATION_CREDENTIALS=$HOME/.config/gcp/my-bq-sa.json``). The skill
ships no default path on purpose: a redistributable skill should not leak
the author's local credential layout.

Confidence grade: A (BigQuery REST API is documented + stable).
"""

from __future__ import annotations

import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from google.oauth2 import service_account
import google.auth.transport.requests as tr


DEFAULT_PROJECT = os.environ.get("BQ_PROJECT", "")
DEFAULT_DATASET = os.environ.get("BQ_DATASET", "")
DEFAULT_LOCATION = os.environ.get("BQ_LOCATION", "us-west1")

# Refresh tokens before they cross this skew margin. 5 minutes is enough to
# survive most clock drift + the round-trip on the next request.
TOKEN_REFRESH_SKEW = timedelta(minutes=5)


def _resolve_key_path(key_path: Optional[str]) -> str:
    """Return a credentials path or raise a clear error.

    Order: explicit arg, then GOOGLE_APPLICATION_CREDENTIALS env var.
    """
    if key_path:
        return key_path
    env_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if env_path:
        return env_path
    raise RuntimeError(
        "No service-account key path supplied. Pass key_path=... to "
        "BigQueryClient(), or set GOOGLE_APPLICATION_CREDENTIALS in the "
        "environment to point at your service-account JSON file."
    )


class BigQueryClient:
    """Lightweight BigQuery REST client using service-account auth.

    For heavy use, switch to the google-cloud-bigquery library. For one-off
    queries in agent code, this is enough and zero dependencies beyond
    google-auth.
    """

    def __init__(
        self,
        key_path: Optional[str] = None,
        project: str = "",
        dataset: str = "",
    ) -> None:
        resolved_path = _resolve_key_path(key_path)
        self.project = project or DEFAULT_PROJECT
        self.dataset = dataset or DEFAULT_DATASET
        if not self.project:
            raise RuntimeError(
                "BigQueryClient requires a project. Pass project=... or set "
                "BQ_PROJECT in the environment."
            )
        self.creds = service_account.Credentials.from_service_account_file(
            resolved_path, scopes=["https://www.googleapis.com/auth/bigquery"]
        )

    def _token(self) -> str:
        """Return a fresh access token, refreshing if near expiry."""
        if self._needs_refresh():
            self.creds.refresh(tr.Request())
        return self.creds.token

    def _needs_refresh(self) -> bool:
        """True if the credential is invalid or within TOKEN_REFRESH_SKEW of expiry."""
        if not self.creds.valid:
            return True
        expiry = getattr(self.creds, "expiry", None)
        if expiry is None:
            return True
        # google-auth stores naive UTC; normalize for the comparison.
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        return expiry <= datetime.now(timezone.utc) + TOKEN_REFRESH_SKEW

    def list_tables(self) -> list[str]:
        """Return all table IDs in the dataset (paginates to fetch every page)."""
        url = (
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{self.project}"
            f"/datasets/{self.dataset}/tables?maxResults=200"
        )
        ids: list[str] = []
        next_url: Optional[str] = url
        while next_url:
            req = urllib.request.Request(
                next_url, headers={"Authorization": f"Bearer {self._token()}"}
            )
            resp = urllib.request.urlopen(req, timeout=30).read().decode()
            j = json.loads(resp)
            ids.extend(t["tableReference"]["tableId"] for t in j.get("tables", []))
            token = j.get("nextPageToken")
            if token:
                next_url = f"{url}&pageToken={token}"
            else:
                next_url = None
        return ids

    def query(self, sql: str, timeout_ms: int = 30000) -> list[dict[str, Any]]:
        """Execute SQL and return rows as dicts (column name -> string value).

        Synchronous-only: if the job does not finish within timeout_ms,
        BigQuery returns ``jobComplete=false`` and this raises. For longer
        jobs use the official google-cloud-bigquery library and poll the
        jobReference yourself.
        """
        body = json.dumps(
            {"query": sql, "useLegacySql": False, "timeoutMs": timeout_ms}
        ).encode()
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
        if not j.get("jobComplete", True):
            raise TimeoutError(
                f"BigQuery job did not complete within {timeout_ms}ms; switch to "
                "google-cloud-bigquery + poll the jobReference for long jobs."
            )
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
        if not self.dataset:
            raise RuntimeError(
                "count() requires a dataset. Pass dataset=... to BigQueryClient() "
                "or set BQ_DATASET in the environment."
            )
        sql = f"SELECT COUNT(*) c FROM `{self.project}.{self.dataset}.{table}`"
        rows = self.query(sql)
        if not rows:
            return 0
        return int(rows[0]["c"])


# Usage notes (uncomment + adapt for your project/dataset):
#
# Recipe: full-text-ish search
#   bq = BigQueryClient(project="my-project", dataset="my_dataset")
#   rows = bq.query("""
#       SELECT col_a, col_b, LEFT(content, 200) AS preview
#       FROM `my-project.my_dataset.some_table`
#       WHERE LOWER(content) LIKE '%search-term%'
#       LIMIT 50
#   """)
#
# Recipe: regex search
#   rows = bq.query("""
#       SELECT id, page, LEFT(content, 200) AS preview
#       FROM `my-project.my_dataset.some_table`
#       WHERE REGEXP_CONTAINS(LOWER(content), r'\\bsearch_term\\b')
#       LIMIT 100
#   """)
