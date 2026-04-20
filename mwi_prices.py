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
