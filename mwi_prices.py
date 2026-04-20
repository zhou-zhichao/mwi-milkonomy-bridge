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
