"""Postgres query logger -- writes every agent retrieval query to ops_search_agent.query_log.

Wrap your agent's PG access with this so drift, hallucination, and cost
blowouts become visible. The log table is created by
``scripts/03_create_query_log.sql`` (PLAYBOOK Section 8 canonical schema).

Usage:

    from pg_query_logger import PGQueryLogger

    qlog = PGQueryLogger(
        dsn="dbname=valor_consolidated user=levi host=/var/run/postgresql",
        agent_id="claude_code",
        session_id="304c9d81-...",
    )
    with qlog.measure(
        tool_name="hybrid_rrf_search",
        args={"query_text": "Carol Frederick probate", "k": 60, "rrf_k": 60},
        schema_targets=["case_26cv11493"],
        embedding_model="voyageai/voyage-context-3",
    ) as ctx:
        rows = ctx.execute(
            "SELECT * FROM ops_search_agent.hybrid_rrf_search(...)"
        )
        ctx.set_result_chunk_ids([r["chunk_id"] for r in rows])
        ctx.set_top_score(rows[0]["rrf_score"] if rows else None)
        ctx.set_confidence(0.82)
        # Later, after downstream resolves:
        # qlog.update_downstream_use(ctx.row_id, "cited_in_filing")

Connections
-----------
Two pools are used: the work connection (per-context, for the agent's query)
and the log connection (held on PGQueryLogger, reused across rows). The log
connection auto-reconnects on stale-connection errors. This avoids the prior
"two connections per query" footgun.

Confidence grade: C (synthesis pattern; pattern is sound, exercise on a live
log table before betting filings on it).
"""

from __future__ import annotations

import contextlib
import json
import logging
import time
import uuid
from typing import Any, Iterable, Iterator, Optional, Sequence

import psycopg2
import psycopg2.extras


log = logging.getLogger(__name__)

# Default warn threshold for fetchall() result-set size. Override per-call
# via PGQueryLogger.row_warn_threshold.
DEFAULT_ROW_WARN_THRESHOLD = 1000


class QueryContext:
    """Context object for one logged query.

    Use via ``PGQueryLogger.measure()``. The context opens its own work
    connection (so a rolled-back work txn does not poison the logger's own
    connection) and closes it on exit. Logging is committed via the
    PGQueryLogger's persistent log connection.
    """

    def __init__(
        self,
        logger: "PGQueryLogger",
        tool_name: str,
        args: Optional[dict[str, Any]] = None,
        embedding_model: Optional[str] = None,
        schema_targets: Optional[Sequence[str]] = None,
        notes: Optional[str] = None,
    ) -> None:
        self.logger = logger
        self.tool_name = tool_name
        self.args: dict[str, Any] = dict(args or {})
        self.embedding_model = embedding_model
        self.schema_targets = list(schema_targets) if schema_targets else None
        self.notes = notes

        # Timing
        self.start_time: Optional[float] = None
        self.end_time: Optional[float] = None

        # Result metadata (populated by caller or .execute())
        self.result_count: Optional[int] = None
        self.result_chunk_ids: Optional[list[int]] = None
        self.top_score: Optional[float] = None
        self.confidence: Optional[float] = None
        self.cache_hit: bool = False
        self.rerank_used: bool = False
        self.rerank_model: Optional[str] = None
        self.downstream_use: Optional[str] = None
        self.privilege_flag: bool = False
        self.error: Optional[str] = None

        # Inferred result_chunk_ids: if .execute() returns dict rows with a
        # 'chunk_id' column we auto-populate. Caller can override.
        self._auto_chunk_ids = True

        # Persisted row id (set by PGQueryLogger._insert)
        self.row_id: Optional[int] = None

        # Work connection (separate from log connection)
        self._work_conn: Optional[Any] = None
        self._work_cur: Optional[Any] = None

    # ---- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "QueryContext":
        self.start_time = time.monotonic()
        self._work_conn = psycopg2.connect(self.logger.dsn)
        self._work_cur = self._work_conn.cursor(
            cursor_factory=psycopg2.extras.RealDictCursor
        )
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.end_time = time.monotonic()
        if exc_val is not None:
            self.error = f"{exc_type.__name__}: {exc_val}"
        try:
            self.logger._insert(self)
        finally:
            if self._work_cur is not None:
                try:
                    self._work_cur.close()
                except Exception:
                    pass
            if self._work_conn is not None:
                try:
                    self._work_conn.close()
                except Exception:
                    pass

    # ---- query execution ---------------------------------------------------

    def execute(
        self,
        sql: str,
        params: Optional[Sequence[Any]] = None,
    ) -> Sequence[Any]:
        """Execute SQL through the logged context. Return all rows.

        WARNING: this calls ``fetchall()`` and loads the entire result set into
        memory. For agent retrieval (top-k) that is the expected pattern; for a
        ``SELECT * FROM huge_table`` use a server-side cursor instead. A warning
        is logged when the result set exceeds ``PGQueryLogger.row_warn_threshold``.
        """
        if self._work_cur is None:
            raise RuntimeError("QueryContext not entered. Use 'with' statement.")
        # Mirror the SQL into args so analysts can grep query_log by query_text.
        self.args.setdefault("query_text", sql)
        self._work_cur.execute(sql, params or ())
        # Non-SELECT (DDL/DML without RETURNING): no rows to fetch.
        if self._work_cur.description is None:
            return []
        rows = self._work_cur.fetchall()
        self.result_count = len(rows)
        if (
            self.logger.row_warn_threshold
            and self.result_count >= self.logger.row_warn_threshold
        ):
            log.warning(
                "pg_query_logger: result_count=%d exceeds row_warn_threshold=%d for tool=%s; "
                "consider a server-side cursor or LIMIT",
                self.result_count,
                self.logger.row_warn_threshold,
                self.tool_name,
            )
        if self._auto_chunk_ids and rows and isinstance(rows[0], dict):
            cid = rows[0].get("chunk_id")
            if cid is not None:
                self.result_chunk_ids = [
                    int(r["chunk_id"]) for r in rows if r.get("chunk_id") is not None
                ]
        return rows

    # ---- setters (for fields .execute() cannot infer) ----------------------

    def set_result_count(self, n: int) -> None:
        self.result_count = n

    def set_result_chunk_ids(self, ids: Optional[Sequence[int]]) -> None:
        self.result_chunk_ids = list(ids) if ids is not None else None
        self._auto_chunk_ids = False

    def set_top_score(self, score: Optional[float]) -> None:
        self.top_score = score

    def set_confidence(self, c: Optional[float]) -> None:
        self.confidence = c

    def set_cache_hit(self, hit: bool) -> None:
        self.cache_hit = hit

    def set_rerank(self, used: bool, model: Optional[str] = None) -> None:
        self.rerank_used = used
        self.rerank_model = model

    def set_privilege_flag(self, flag: bool) -> None:
        self.privilege_flag = flag

    def set_downstream_use(self, use: Optional[str]) -> None:
        self.downstream_use = use

    def add_arg(self, key: str, value: Any) -> None:
        self.args[key] = value

    # ---- derived -----------------------------------------------------------

    def latency_ms(self) -> Optional[int]:
        if self.start_time is None or self.end_time is None:
            return None
        return int((self.end_time - self.start_time) * 1000)


class PGQueryLogger:
    """Lightweight query logger -- one row per measured query.

    Holds a persistent log connection that auto-reconnects on stale-connection
    errors. Safe to share across QueryContext instances inside a single agent
    process; not thread-safe (give each thread its own PGQueryLogger).
    """

    def __init__(
        self,
        dsn: str,
        agent_id: str = "claude_code",
        session_id: Optional[str] = None,
        embedding_model: str = "voyageai/voyage-context-3",
        notes: Optional[str] = None,
        row_warn_threshold: int = DEFAULT_ROW_WARN_THRESHOLD,
    ) -> None:
        self.dsn = dsn
        self.agent_id = agent_id
        self.session_id = session_id or str(uuid.uuid4())
        self.embedding_model = embedding_model
        self.notes = notes
        self.row_warn_threshold = row_warn_threshold
        self._log_conn: Optional[Any] = None

    # ---- log connection management ----------------------------------------

    def _ensure_log_conn(self) -> Any:
        """Return the persistent log connection, reconnecting if it died."""
        if self._log_conn is None or self._log_conn.closed:
            self._log_conn = psycopg2.connect(self.dsn)
            self._log_conn.autocommit = False
        else:
            try:
                # Cheap liveness check
                with self._log_conn.cursor() as c:
                    c.execute("SELECT 1")
                self._log_conn.rollback()
            except psycopg2.Error:
                try:
                    self._log_conn.close()
                except Exception:
                    pass
                self._log_conn = psycopg2.connect(self.dsn)
                self._log_conn.autocommit = False
        return self._log_conn

    def close(self) -> None:
        """Close the log connection. Safe to call multiple times."""
        if self._log_conn is not None:
            try:
                self._log_conn.close()
            except Exception:
                pass
            self._log_conn = None

    # ---- public API --------------------------------------------------------

    @contextlib.contextmanager
    def measure(
        self,
        tool_name: str,
        args: Optional[dict[str, Any]] = None,
        embedding_model: Optional[str] = None,
        schema_targets: Optional[Sequence[str]] = None,
        notes: Optional[str] = None,
    ) -> Iterator[QueryContext]:
        """Wrap a query with measurement + logging."""
        ctx = QueryContext(
            self,
            tool_name=tool_name,
            args=args,
            embedding_model=embedding_model or self.embedding_model,
            schema_targets=schema_targets,
            notes=notes or self.notes,
        )
        with ctx:
            yield ctx

    def update_downstream_use(
        self,
        row_id: int,
        downstream_use: str,
    ) -> None:
        """Backfill the downstream_use column for an existing log row.

        Use after the agent decides whether the retrieved chunks were
        ``'cited_in_filing'``, ``'discarded'``, or ``'rewritten'``.
        """
        conn = self._ensure_log_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE ops_search_agent.query_log "
                    "SET downstream_use = %s WHERE id = %s",
                    (downstream_use, row_id),
                )
            conn.commit()
        except psycopg2.Error:
            conn.rollback()
            raise

    # ---- internal ----------------------------------------------------------

    def _insert(self, ctx: QueryContext) -> None:
        """Insert one query_log row. Called from QueryContext.__exit__."""
        conn = self._ensure_log_conn()
        # PLAYBOOK Section 8 canonical columns + useful extras kept in the
        # script. The args column is JSONB; result_chunk_ids is bigint[].
        args_blob = psycopg2.extras.Json(ctx.args)
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO ops_search_agent.query_log (
                        session_id, agent_id, tool_name, args,
                        result_count, result_chunk_ids,
                        latency_ms, cache_hit, rerank_used, rerank_model,
                        confidence, downstream_use, privilege_flag, error,
                        query_text, embedding_model, schema_targets,
                        k, rrf_k, top_score, notes
                    ) VALUES (
                        %(session_id)s, %(agent_id)s, %(tool_name)s, %(args)s,
                        %(result_count)s, %(result_chunk_ids)s,
                        %(latency_ms)s, %(cache_hit)s, %(rerank_used)s, %(rerank_model)s,
                        %(confidence)s, %(downstream_use)s, %(privilege_flag)s, %(error)s,
                        %(query_text)s, %(embedding_model)s, %(schema_targets)s,
                        %(k)s, %(rrf_k)s, %(top_score)s, %(notes)s
                    )
                    RETURNING id
                    """,
                    {
                        "session_id": self.session_id,
                        "agent_id": self.agent_id,
                        "tool_name": ctx.tool_name,
                        "args": args_blob,
                        "result_count": ctx.result_count,
                        "result_chunk_ids": ctx.result_chunk_ids,
                        "latency_ms": ctx.latency_ms(),
                        "cache_hit": ctx.cache_hit,
                        "rerank_used": ctx.rerank_used,
                        "rerank_model": ctx.rerank_model,
                        "confidence": ctx.confidence,
                        "downstream_use": ctx.downstream_use,
                        "privilege_flag": ctx.privilege_flag,
                        "error": ctx.error,
                        "query_text": ctx.args.get("query_text"),
                        "embedding_model": ctx.embedding_model or self.embedding_model,
                        "schema_targets": ctx.schema_targets,
                        "k": ctx.args.get("k"),
                        "rrf_k": ctx.args.get("rrf_k"),
                        "top_score": ctx.top_score,
                        "notes": ctx.notes or self.notes,
                    },
                )
                row = cur.fetchone()
                if row is not None:
                    ctx.row_id = int(row[0])
            conn.commit()
        except psycopg2.Error:
            try:
                conn.rollback()
            except Exception:
                pass
            raise


if __name__ == "__main__":  # pragma: no cover
    # Minimal end-to-end smoke. Requires scripts/03_create_query_log.sql to
    # have been applied to the target DB first. Set PG_DSN to override the
    # default Linux peer-auth socket.
    import os

    dsn = os.environ.get(
        "PG_DSN",
        "dbname=valor_consolidated user=levi host=/var/run/postgresql",
    )
    qlog = PGQueryLogger(dsn=dsn, agent_id="claude_code", session_id="demo")
    with qlog.measure(
        tool_name="fts",
        args={"query_text": "Bingaman APS investigation"},
        schema_targets=["case_26cv11493"],
    ) as ctx:
        rows = ctx.execute("SELECT 1 AS chunk_id, 'preview' AS preview")
        ctx.set_top_score(0.99)
        ctx.set_confidence(0.7)
    print(f"Logged row id={ctx.row_id}, result_count={ctx.result_count}, "
          f"chunk_ids={ctx.result_chunk_ids}, latency_ms={ctx.latency_ms()}")
    qlog.close()
