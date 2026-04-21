"""MWI historical price tracking — shared library.

Pure stdlib. Consumed by mwi-price-logger.py and mwi-price-query.py.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

DEFAULT_DB_PATH = Path(__file__).resolve().parent / "data" / "prices.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS price_history (
    timestamp   INTEGER NOT NULL,
    item_hrid   TEXT NOT NULL,
    level       INTEGER NOT NULL,
    ask         INTEGER,
    bid         INTEGER,
    last_price  INTEGER,
    volume      INTEGER,
    PRIMARY KEY (timestamp, item_hrid, level)
);
CREATE INDEX IF NOT EXISTS idx_item_time
    ON price_history(item_hrid, level, timestamp DESC);
"""


def open_db(path: str | Path = DEFAULT_DB_PATH) -> sqlite3.Connection:
    """Open (and create if needed) the price history database."""
    if path != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn


def latest_timestamp(conn: sqlite3.Connection) -> int | None:
    row = conn.execute("SELECT MAX(timestamp) FROM price_history").fetchone()
    return row[0] if row and row[0] is not None else None


def insert_snapshot(
    conn: sqlite3.Connection,
    timestamp: int,
    market_data: dict,
) -> int:
    """Insert one full snapshot. Returns number of rows inserted.

    `market_data` maps item_hrid -> { level_str -> {a, b, p, v} }.
    Uses INSERT OR IGNORE, so re-running with the same timestamp is a no-op.
    """
    rows = []
    for item_hrid, levels in market_data.items():
        for level_str, tier in levels.items():
            try:
                level = int(level_str)
            except (TypeError, ValueError):
                continue
            rows.append((
                timestamp,
                item_hrid,
                level,
                tier.get("a"),
                tier.get("b"),
                tier.get("p"),
                tier.get("v"),
            ))
    before = conn.total_changes
    with conn:
        conn.executemany(
            "INSERT OR IGNORE INTO price_history "
            "(timestamp, item_hrid, level, ask, bid, last_price, volume) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            rows,
        )
    return conn.total_changes - before


def fuzzy_match(conn: sqlite3.Connection, query: str) -> list[str]:
    """Return item_hrids containing `query` as substring (case-insensitive).

    Exact match on full hrid short-circuits to [query].
    """
    row = conn.execute(
        "SELECT 1 FROM price_history WHERE item_hrid = ? LIMIT 1", (query,)
    ).fetchone()
    if row:
        return [query]
    pattern = f"%{query.lower()}%"
    rows = conn.execute(
        "SELECT DISTINCT item_hrid FROM price_history "
        "WHERE LOWER(item_hrid) LIKE ? ORDER BY item_hrid",
        (pattern,),
    ).fetchall()
    return [r[0] for r in rows]


def latest_row(
    conn: sqlite3.Connection, item_hrid: str, level: int
) -> tuple | None:
    """Return (timestamp, ask, bid, last_price, volume) for newest row, or None."""
    return conn.execute(
        "SELECT timestamp, ask, bid, last_price, volume FROM price_history "
        "WHERE item_hrid = ? AND level = ? ORDER BY timestamp DESC LIMIT 1",
        (item_hrid, level),
    ).fetchone()


def history(
    conn: sqlite3.Connection,
    item_hrid: str,
    level: int,
    since_ts: int,
) -> list[tuple]:
    """Rows newer than since_ts, newest first."""
    return conn.execute(
        "SELECT timestamp, ask, bid, last_price, volume FROM price_history "
        "WHERE item_hrid = ? AND level = ? AND timestamp >= ? "
        "ORDER BY timestamp DESC",
        (item_hrid, level, since_ts),
    ).fetchall()


def items_with_data(conn: sqlite3.Connection, level: int = 0) -> list[str]:
    rows = conn.execute(
        "SELECT DISTINCT item_hrid FROM price_history WHERE level = ?",
        (level,),
    ).fetchall()
    return [r[0] for r in rows]


def percentile(values: list[int], current: int) -> float | None:
    """Rank of `current` in sorted `values`, as a 0-100 percentile.

    Formula: (rank - 1) / (n - 1) * 100, rank counted by strictly-less-than.
    Returns 50.0 when there is no spread (single value or all equal), since
    rank is not meaningful. Empty -> None.
    """
    if not values:
        return None
    n = len(values)
    if n == 1 or min(values) == max(values):
        return 50.0
    rank = sum(1 for v in values if v < current) + 1
    rank = max(1, min(rank, n))
    return round((rank - 1) / (n - 1) * 100, 2)


def summarize(rows: list[tuple]) -> dict | None:
    """Compute current / min / max / avg / percentile for ask.

    `rows` is history() output: (timestamp, ask, bid, last_price, volume), newest first.
    Ignores rows with ask <= 0 for ask stats. Returns None if no rows.
    """
    if not rows:
        return None
    current_ts, current_ask, current_bid, *_ = rows[0]
    ask_rows = [(ts, a) for ts, a, *_ in rows if a is not None and a > 0]
    if not ask_rows:
        return {
            "current_ts": current_ts,
            "current_ask": current_ask,
            "current_bid": current_bid,
            "ask_min": None, "ask_min_ts": None,
            "ask_max": None, "ask_max_ts": None,
            "ask_avg": None, "ask_percentile": None,
            "sample_size": 0,
        }
    asks = [a for _, a in ask_rows]
    min_ts, min_v = min(ask_rows, key=lambda r: r[1])
    max_ts, max_v = max(ask_rows, key=lambda r: r[1])
    return {
        "current_ts": current_ts,
        "current_ask": current_ask,
        "current_bid": current_bid,
        "ask_min": min_v,
        "ask_min_ts": min_ts,
        "ask_max": max_v,
        "ask_max_ts": max_ts,
        "ask_avg": round(sum(asks) / len(asks), 2),
        "ask_percentile": percentile(asks, current_ask) if (current_ask is not None and current_ask > 0) else None,
        "sample_size": len(asks),
    }
