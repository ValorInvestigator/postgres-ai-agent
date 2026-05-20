"""Postgres query logger -- writes every agent retrieval query to ops_search_agent.query_log.

Wrap your agent's PG access with this so drift, hallucination, and cost blowouts become visible.

Usage:
    from pg_query_logger import PGQueryLogger
    qlog = PGQueryLogger(dsn='dbname=valor_consolidated user=levi host=/var/run/postgresql',
                        agent_name='claude-code', session_id='304c9d81-...')
    with qlog.measure('hybrid_rrf', query_text='Carol Frederick probate', k=60, rrf_k=60, schemas=['case_26cv11493']) as ctx:
        rows = ctx.execute('SELECT * FROM ops_search_agent.hybrid_rrf_search(...)')
        ctx.set_rows_returned(len(rows))
        ctx.set_top_score(rows[0]['rrf_score'] if rows else None)

Confidence grade: C (synthesis pattern; pattern is sound, untested in production).
"""

from __future__ import annotations

import contextlib
import time
from typing import Any, Iterable, Optional, Sequence

import psycopg2
import psycopg2.extras


class QueryContext:
    """Context object for a single logged query. Use as a context manager via PGQueryLogger.measure()."""

    def __init__(self, logger: "PGQueryLogger", query_kind: str, **kwargs: Any) -> None:
        self.logger = logger
        self.query_kind = query_kind
        self.kwargs = kwargs
        self.start_time: Optional[float] = None
        self.end_time: Optional[float] = None
        self.rows_returned: Optional[int] = None
        self.top_score: Optional[float] = None
        self.error: Optional[str] = None
        self._conn: Optional[Any] = None
        self._cur: Optional[Any] = None

    def __enter__(self) -> "QueryContext":
        self.start_time = time.monotonic()
        self._conn = psycopg2.connect(self.logger.dsn)
        self._cur = self._conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.end_time = time.monotonic()
        if exc_val is not None:
            self.error = f"{exc_type.__name__}: {exc_val}"
        try:
            self.logger._insert(self)
        finally:
            if self._cur is not None:
                self._cur.close()
            if self._conn is not None:
                self._conn.close()

    def execute(self, sql: str, params: Optional[Sequence[Any]] = None) -> Sequence[Any]:
        """Execute SQL through the logged context. Return all rows."""
        if self._cur is None:
            raise RuntimeError("QueryContext not entered. Use 'with' statement.")
        self.kwargs.setdefault("query_text", sql)
        self._cur.execute(sql, params or ())
        # If no rows (e.g. DDL), guard
        if self._cur.description is None:
            return []
        rows = self._cur.fetchall()
        self.rows_returned = len(rows)
        return rows

    def set_rows_returned(self, n: int) -> None:
        self.rows_returned = n

    def set_top_score(self, score: Optional[float]) -> None:
        self.top_score = score

    def latency_ms(self) -> Optional[int]:
        if self.start_time is None or self.end_time is None:
            return None
        return int((self.end_time - self.start_time) * 1000)


class PGQueryLogger:
    """Lightweight query logger -- inserts one row into ops_search_agent.query_log per query."""

    def __init__(
        self,
        dsn: str,
        agent_name: str = "claude-code",
        session_id: Optional[str] = None,
        embedding_model: str = "sentence-transformers/all-MiniLM-L6-v2",
        notes: Optional[str] = None,
    ) -> None:
        self.dsn = dsn
        self.agent_name = agent_name
        self.session_id = session_id
        self.embedding_model = embedding_model
        self.notes = notes

    @contextlib.contextmanager
    def measure(self, query_kind: str, **kwargs: Any) -> Iterable[QueryContext]:
        """Wrap a query with measurement + logging."""
        ctx = QueryContext(self, query_kind, **kwargs)
        with ctx:
            yield ctx

    def _insert(self, ctx: QueryContext) -> None:
        """Insert one query_log row. Called from QueryContext.__exit__."""
        # Open a fresh connection because ctx._conn may have been rolled back
        with psycopg2.connect(self.dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO ops_search_agent.query_log (
                        agent_name, session_id, query_kind, query_text,
                        embedding_model, schema_targets, k, rrf_k,
                        rerank_used, rerank_model,
                        latency_ms, rows_returned, top_score,
                        notes, error
                    ) VALUES (
                        %(agent_name)s, %(session_id)s, %(query_kind)s, %(query_text)s,
                        %(embedding_model)s, %(schema_targets)s, %(k)s, %(rrf_k)s,
                        %(rerank_used)s, %(rerank_model)s,
                        %(latency_ms)s, %(rows_returned)s, %(top_score)s,
                        %(notes)s, %(error)s
                    )
                    """,
                    {
                        "agent_name": self.agent_name,
                        "session_id": self.session_id,
                        "query_kind": ctx.query_kind,
                        "query_text": ctx.kwargs.get("query_text"),
                        "embedding_model": ctx.kwargs.get("embedding_model", self.embedding_model),
                        "schema_targets": ctx.kwargs.get("schemas") or ctx.kwargs.get("schema_targets"),
                        "k": ctx.kwargs.get("k"),
                        "rrf_k": ctx.kwargs.get("rrf_k"),
                        "rerank_used": ctx.kwargs.get("rerank_used", False),
                        "rerank_model": ctx.kwargs.get("rerank_model"),
                        "latency_ms": ctx.latency_ms(),
                        "rows_returned": ctx.rows_returned,
                        "top_score": ctx.top_score,
                        "notes": self.notes or ctx.kwargs.get("notes"),
                        "error": ctx.error,
                    },
                )
                conn.commit()


# Simple usage demo (commented; uncomment to run)
# if __name__ == "__main__":
#     qlog = PGQueryLogger(
#         dsn="dbname=valor_consolidated user=levi host=/var/run/postgresql",
#         agent_name="claude-code-demo",
#         session_id="demo-session",
#     )
#     with qlog.measure("fts", query_text="Bingaman APS investigation", schemas=["case_26cv11493"]) as ctx:
#         rows = ctx.execute(
#             """
#             SELECT chunk_id, LEFT(text, 100) AS text_preview
#             FROM case_26cv11493.text_chunks
#             WHERE to_tsvector('english', text) @@ plainto_tsquery('english', %s)
#             LIMIT 10
#             """,
#             ("Bingaman APS investigation",),
#         )
#         print(f"Returned {len(rows)} rows")
