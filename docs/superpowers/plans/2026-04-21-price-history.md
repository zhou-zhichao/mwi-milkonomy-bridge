# Price History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record historical marketplace prices from MWI's public `marketplace.json` into a local SQLite database and provide a CLI to query history and scan for items currently at historical lows.

**Architecture:** One shared pure-Python library (`mwi_prices.py`) holds DB access and analysis helpers. Two CLI entry points (`mwi-price-logger.py`, `mwi-price-query.py`) wrap the library. A cron entry runs the logger every 30 minutes; it no-ops when the API `timestamp` hasn't changed.

**Tech Stack:** Python 3 stdlib only — `sqlite3`, `urllib.request`, `argparse`, `unittest`. No external dependencies.

---

## File Structure

| File | Responsibility |
|---|---|
| `mwi_prices.py` | Library: DB open/schema, insert snapshot, fuzzy item match, history fetch, pure stats functions. Importable by scripts and tests. |
| `mwi-price-logger.py` | CLI entry: fetch `marketplace.json`, dedup by timestamp, call `insert_snapshot`. |
| `mwi-price-query.py` | CLI entry: argparse; single-item mode and `--cheap` scan mode. |
| `tests/__init__.py` | Empty, marks package. |
| `tests/test_prices.py` | All unit tests for `mwi_prices.py` and both scripts (logger uses urlopen mock). |
| `data/prices.db` | Created at runtime; not committed. |
| `.gitignore` | Add `data/`. |
| `README.md` | Add a short section documenting the new feature + cron install command. |

All paths relative to `/home/sam/mwi-milkonomy-bridge/`.

---

### Task 1: Scaffold — gitignore, tests dir, DB open & schema

**Files:**
- Modify: `.gitignore`
- Create: `tests/__init__.py`
- Create: `tests/test_prices.py`
- Create: `mwi_prices.py`

- [ ] **Step 1: Add `data/` to `.gitignore`**

Edit `.gitignore` — add a new line `data/` after the existing `logs/` line.

- [ ] **Step 2: Create empty `tests/__init__.py`**

```bash
: > tests/__init__.py
```

- [ ] **Step 3: Write the failing test**

Create `tests/test_prices.py`:

```python
import sqlite3
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import mwi_prices


class TestOpenDb(unittest.TestCase):
    def test_open_db_creates_table_and_index(self):
        conn = mwi_prices.open_db(":memory:")
        cur = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='price_history'"
        )
        self.assertIsNotNone(cur.fetchone())

        cur = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_item_time'"
        )
        self.assertIsNotNone(cur.fetchone())

        cols = {row[1] for row in conn.execute("PRAGMA table_info(price_history)")}
        self.assertEqual(
            cols,
            {"timestamp", "item_hrid", "level", "ask", "bid", "last_price", "volume"},
        )
        conn.close()


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `python3 -m unittest tests.test_prices -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'mwi_prices'`.

- [ ] **Step 5: Create `mwi_prices.py` with minimal `open_db`**

```python
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
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `python3 -m unittest tests.test_prices -v`
Expected: 1 test passes, OK.

- [ ] **Step 7: Commit**

```bash
git add .gitignore tests/__init__.py tests/test_prices.py mwi_prices.py
git commit -m "Add price history DB schema and test scaffold"
```

---

### Task 2: Insert snapshot + timestamp dedup

**Files:**
- Modify: `mwi_prices.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py` (before `if __name__ == "__main__":`):

```python
SAMPLE_MARKET = {
    "/items/cheese": {"0": {"a": 180, "b": 175, "p": 175, "v": 916124}},
    "/items/milking_tool": {
        "0": {"a": -1, "b": -1, "p": 0, "v": 0},
        "1": {"a": 5000, "b": 4800, "p": 4900, "v": 12},
    },
}


class TestInsertSnapshot(unittest.TestCase):
    def setUp(self):
        self.conn = mwi_prices.open_db(":memory:")

    def tearDown(self):
        self.conn.close()

    def test_insert_writes_all_levels(self):
        inserted = mwi_prices.insert_snapshot(self.conn, 1000, SAMPLE_MARKET)
        self.assertEqual(inserted, 3)
        rows = list(self.conn.execute(
            "SELECT timestamp, item_hrid, level, ask, bid, last_price, volume "
            "FROM price_history ORDER BY item_hrid, level"
        ))
        self.assertEqual(rows, [
            (1000, "/items/cheese", 0, 180, 175, 175, 916124),
            (1000, "/items/milking_tool", 0, -1, -1, 0, 0),
            (1000, "/items/milking_tool", 1, 5000, 4800, 4900, 12),
        ])

    def test_duplicate_timestamp_inserts_zero(self):
        mwi_prices.insert_snapshot(self.conn, 1000, SAMPLE_MARKET)
        inserted = mwi_prices.insert_snapshot(self.conn, 1000, SAMPLE_MARKET)
        self.assertEqual(inserted, 0)
        (count,) = self.conn.execute(
            "SELECT COUNT(*) FROM price_history"
        ).fetchone()
        self.assertEqual(count, 3)

    def test_latest_timestamp(self):
        self.assertIsNone(mwi_prices.latest_timestamp(self.conn))
        mwi_prices.insert_snapshot(self.conn, 1000, SAMPLE_MARKET)
        mwi_prices.insert_snapshot(self.conn, 2000, SAMPLE_MARKET)
        self.assertEqual(mwi_prices.latest_timestamp(self.conn), 2000)
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python3 -m unittest tests.test_prices -v`
Expected: `TestOpenDb` passes; `TestInsertSnapshot` fails with `AttributeError: module 'mwi_prices' has no attribute 'insert_snapshot'`.

- [ ] **Step 3: Implement `insert_snapshot` and `latest_timestamp`**

Append to `mwi_prices.py`:

```python
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
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 -m unittest tests.test_prices -v`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add mwi_prices.py tests/test_prices.py
git commit -m "Implement snapshot insert with timestamp-based dedup"
```

---

### Task 3: Fuzzy item match, latest row, history fetch

**Files:**
- Modify: `mwi_prices.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py`:

```python
class TestQueries(unittest.TestCase):
    def setUp(self):
        self.conn = mwi_prices.open_db(":memory:")
        snaps = {
            1000: {
                "/items/cheese": {"0": {"a": 200, "b": 190, "p": 195, "v": 1000}},
                "/items/bronze_bar": {"0": {"a": 50, "b": 48, "p": 49, "v": 500}},
                "/items/iron_bar": {"0": {"a": 100, "b": 95, "p": 98, "v": 300}},
            },
            2000: {
                "/items/cheese": {"0": {"a": 180, "b": 175, "p": 175, "v": 900}},
                "/items/bronze_bar": {"0": {"a": 45, "b": 43, "p": 44, "v": 600}},
                "/items/iron_bar": {"0": {"a": 105, "b": 100, "p": 102, "v": 310}},
            },
        }
        for ts, data in snaps.items():
            mwi_prices.insert_snapshot(self.conn, ts, data)

    def tearDown(self):
        self.conn.close()

    def test_fuzzy_match_unique(self):
        self.assertEqual(mwi_prices.fuzzy_match(self.conn, "cheese"), ["/items/cheese"])

    def test_fuzzy_match_exact_hrid(self):
        self.assertEqual(
            mwi_prices.fuzzy_match(self.conn, "/items/cheese"),
            ["/items/cheese"],
        )

    def test_fuzzy_match_ambiguous(self):
        self.assertEqual(
            sorted(mwi_prices.fuzzy_match(self.conn, "bar")),
            ["/items/bronze_bar", "/items/iron_bar"],
        )

    def test_fuzzy_match_none(self):
        self.assertEqual(mwi_prices.fuzzy_match(self.conn, "nonexistent"), [])

    def test_latest_row(self):
        row = mwi_prices.latest_row(self.conn, "/items/cheese", 0)
        self.assertEqual(row, (2000, 180, 175, 175, 900))

    def test_latest_row_missing(self):
        self.assertIsNone(mwi_prices.latest_row(self.conn, "/items/missing", 0))

    def test_history_returns_desc(self):
        rows = mwi_prices.history(self.conn, "/items/cheese", 0, since_ts=0)
        self.assertEqual(rows, [
            (2000, 180, 175, 175, 900),
            (1000, 200, 190, 195, 1000),
        ])

    def test_history_since(self):
        rows = mwi_prices.history(self.conn, "/items/cheese", 0, since_ts=1500)
        self.assertEqual(rows, [(2000, 180, 175, 175, 900)])

    def test_items_with_data(self):
        items = mwi_prices.items_with_data(self.conn, level=0)
        self.assertEqual(
            sorted(items),
            ["/items/bronze_bar", "/items/cheese", "/items/iron_bar"],
        )
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m unittest tests.test_prices -v`
Expected: earlier tests pass; `TestQueries` fails with `AttributeError: ... fuzzy_match`.

- [ ] **Step 3: Implement the query helpers**

Append to `mwi_prices.py`:

```python
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
```

- [ ] **Step 4: Run tests**

Run: `python3 -m unittest tests.test_prices -v`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add mwi_prices.py tests/test_prices.py
git commit -m "Add query helpers: fuzzy_match, latest_row, history, items_with_data"
```

---

### Task 4: Pure stats — percentile and summary

**Files:**
- Modify: `mwi_prices.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py`:

```python
class TestPercentile(unittest.TestCase):
    def test_single_value(self):
        self.assertEqual(mwi_prices.percentile([100], 100), 50.0)

    def test_lowest(self):
        self.assertEqual(mwi_prices.percentile([100, 200, 300], 100), 0.0)

    def test_highest(self):
        self.assertEqual(mwi_prices.percentile([100, 200, 300], 300), 100.0)

    def test_middle(self):
        self.assertEqual(mwi_prices.percentile([100, 200, 300], 200), 50.0)

    def test_current_not_in_list(self):
        self.assertEqual(mwi_prices.percentile([100, 200, 300], 150), 25.0)

    def test_empty_returns_none(self):
        self.assertIsNone(mwi_prices.percentile([], 100))


class TestSummarize(unittest.TestCase):
    def test_summary_includes_current_min_max_avg_percentile(self):
        rows = [
            (3000, 180, 175, 175, 100),
            (2000, 165, 160, 162, 100),
            (1000, 240, 230, 235, 100),
        ]
        s = mwi_prices.summarize(rows)
        self.assertEqual(s["current_ask"], 180)
        self.assertEqual(s["current_bid"], 175)
        self.assertEqual(s["ask_min"], 165)
        self.assertEqual(s["ask_min_ts"], 2000)
        self.assertEqual(s["ask_max"], 240)
        self.assertEqual(s["ask_max_ts"], 1000)
        self.assertEqual(s["ask_avg"], round((180 + 165 + 240) / 3, 2))
        self.assertEqual(s["ask_percentile"], 50.0)

    def test_summary_ignores_negative(self):
        rows = [
            (3000, 100, 90, 95, 50),
            (2000, -1, -1, 0, 0),
            (1000, 200, 180, 190, 50),
        ]
        s = mwi_prices.summarize(rows)
        self.assertEqual(s["ask_min"], 100)
        self.assertEqual(s["ask_max"], 200)

    def test_summary_empty(self):
        self.assertIsNone(mwi_prices.summarize([]))
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m unittest tests.test_prices -v`
Expected: new tests fail (`no attribute 'percentile'`).

- [ ] **Step 3: Implement `percentile` and `summarize`**

Append to `mwi_prices.py`:

```python
def percentile(values: list[int], current: int) -> float | None:
    """Rank of `current` in sorted `values`, as a 0-100 percentile.

    Formula: (rank - 1) / (n - 1) * 100, rank counted by strictly-less-than.
    n == 1 -> 50.0 (no spread to compare against).
    Empty -> None.
    """
    if not values:
        return None
    n = len(values)
    if n == 1:
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
        "ask_percentile": percentile(asks, current_ask) if current_ask > 0 else None,
        "sample_size": len(asks),
    }
```

- [ ] **Step 4: Run tests**

Run: `python3 -m unittest tests.test_prices -v`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add mwi_prices.py tests/test_prices.py
git commit -m "Add percentile and summarize helpers"
```

---

### Task 5: Logger script with mocked HTTP

**Files:**
- Create: `mwi-price-logger.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py`:

```python
import importlib.util
import io
import json
from unittest.mock import patch


def _load_logger():
    spec = importlib.util.spec_from_file_location(
        "mwi_price_logger",
        Path(__file__).resolve().parents[1] / "mwi-price-logger.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestLogger(unittest.TestCase):
    def setUp(self):
        self.logger = _load_logger()
        self.tmp_db = Path(self.id() + ".db")
        if self.tmp_db.exists():
            self.tmp_db.unlink()

    def tearDown(self):
        if self.tmp_db.exists():
            self.tmp_db.unlink()

    def _fake_urlopen(self, payload):
        body = json.dumps(payload).encode()
        class Resp:
            def __enter__(self_): return self_
            def __exit__(self_, *a): return False
            def read(self_): return body
        return Resp()

    def test_first_run_inserts(self):
        payload = {"timestamp": 1000, "marketData": SAMPLE_MARKET}
        with patch.object(self.logger.urllib.request, "urlopen",
                          return_value=self._fake_urlopen(payload)):
            rc = self.logger.run(db_path=str(self.tmp_db))
        self.assertEqual(rc, 0)
        conn = mwi_prices.open_db(str(self.tmp_db))
        (count,) = conn.execute("SELECT COUNT(*) FROM price_history").fetchone()
        self.assertEqual(count, 3)
        conn.close()

    def test_duplicate_timestamp_is_noop(self):
        payload = {"timestamp": 1000, "marketData": SAMPLE_MARKET}
        with patch.object(self.logger.urllib.request, "urlopen",
                          return_value=self._fake_urlopen(payload)):
            self.logger.run(db_path=str(self.tmp_db))
            rc = self.logger.run(db_path=str(self.tmp_db))
        self.assertEqual(rc, 0)
        conn = mwi_prices.open_db(str(self.tmp_db))
        (count,) = conn.execute("SELECT COUNT(*) FROM price_history").fetchone()
        self.assertEqual(count, 3)
        conn.close()

    def test_new_timestamp_adds_rows(self):
        p1 = {"timestamp": 1000, "marketData": SAMPLE_MARKET}
        p2 = {"timestamp": 2000, "marketData": SAMPLE_MARKET}
        with patch.object(self.logger.urllib.request, "urlopen",
                          return_value=self._fake_urlopen(p1)):
            self.logger.run(db_path=str(self.tmp_db))
        with patch.object(self.logger.urllib.request, "urlopen",
                          return_value=self._fake_urlopen(p2)):
            self.logger.run(db_path=str(self.tmp_db))
        conn = mwi_prices.open_db(str(self.tmp_db))
        (count,) = conn.execute("SELECT COUNT(*) FROM price_history").fetchone()
        self.assertEqual(count, 6)
        conn.close()
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m unittest tests.test_prices -v`
Expected: `FileNotFoundError` or `ModuleNotFoundError` from `_load_logger`.

- [ ] **Step 3: Create `mwi-price-logger.py`**

```python
#!/usr/bin/env python3
"""Fetch MWI marketplace.json and append a snapshot to the local DB.

Skips insertion when the API timestamp is unchanged.

Usage:
    python3 mwi-price-logger.py [--db PATH]
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mwi_prices

MARKET_URL = "https://www.milkywayidle.com/game_data/marketplace.json"
USER_AGENT = "mwi-price-logger/1.0"
TIMEOUT = 30


def fetch_marketplace(url: str = MARKET_URL) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read())


def run(db_path: str | Path = mwi_prices.DEFAULT_DB_PATH) -> int:
    try:
        payload = fetch_marketplace()
    except Exception as e:
        print(f"ERROR: fetch failed: {e}", file=sys.stderr)
        return 1

    ts = payload.get("timestamp")
    market = payload.get("marketData") or {}
    if not isinstance(ts, int) or not market:
        print(f"ERROR: malformed response (timestamp={ts!r}, items={len(market)})",
              file=sys.stderr)
        return 1

    conn = mwi_prices.open_db(db_path)
    try:
        latest = mwi_prices.latest_timestamp(conn)
        if latest == ts:
            print(f"skipped: timestamp unchanged ({ts})")
            return 0
        n = mwi_prices.insert_snapshot(conn, ts, market)
        human = _dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
        print(f"inserted {n} rows at timestamp={ts} (snapshot {human})")
        return 0
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--db", default=str(mwi_prices.DEFAULT_DB_PATH))
    args = p.parse_args(argv)
    return run(db_path=args.db)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests**

Run: `python3 -m unittest tests.test_prices -v`
Expected: all tests pass.

- [ ] **Step 5: Manual smoke test — real API call**

Run: `python3 mwi-price-logger.py`
Expected: prints `inserted N rows at timestamp=...` (N should be around 900-1000 for level 0 items plus equipment levels). DB file created at `data/prices.db`.

Run it again immediately: `python3 mwi-price-logger.py`
Expected: `skipped: timestamp unchanged (...)`.

- [ ] **Step 6: Commit**

```bash
git add mwi-price-logger.py tests/test_prices.py
git commit -m "Add price logger script with timestamp dedup"
```

---

### Task 6: Query CLI — single-item mode

**Files:**
- Create: `mwi-price-query.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py`:

```python
def _load_query():
    spec = importlib.util.spec_from_file_location(
        "mwi_price_query",
        Path(__file__).resolve().parents[1] / "mwi-price-query.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestQueryCLI(unittest.TestCase):
    def setUp(self):
        self.q = _load_query()
        self.tmp_db = Path(self.id() + ".db")
        if self.tmp_db.exists():
            self.tmp_db.unlink()
        conn = mwi_prices.open_db(str(self.tmp_db))
        base = 1_700_000_000
        step = 4 * 3600
        prices = [240, 220, 210, 200, 195, 190, 185, 180, 170, 165, 180]
        for i, ask in enumerate(prices):
            mwi_prices.insert_snapshot(conn, base + i * step, {
                "/items/cheese": {"0": {"a": ask, "b": ask - 5, "p": ask - 5, "v": 1000}},
                "/items/bronze_bar": {"0": {"a": 50, "b": 48, "p": 49, "v": 500}},
            })
        conn.close()

    def tearDown(self):
        if self.tmp_db.exists():
            self.tmp_db.unlink()

    def _capture(self, argv):
        buf = io.StringIO()
        with patch("sys.stdout", buf):
            rc = self.q.main(argv + ["--db", str(self.tmp_db)])
        return rc, buf.getvalue()

    def test_single_item_output(self):
        rc, out = self._capture(["cheese", "--days", "30"])
        self.assertEqual(rc, 0)
        self.assertIn("/items/cheese", out)
        self.assertIn("current", out.lower())
        self.assertIn("180", out)   # current ask
        self.assertIn("165", out)   # min
        self.assertIn("240", out)   # max

    def test_ambiguous_match_lists_candidates(self):
        rc, out = self._capture(["ar"])
        self.assertNotEqual(rc, 0)
        self.assertIn("bronze_bar", out)

    def test_no_match_errors(self):
        rc, out = self._capture(["nonexistent_thing_xyz"])
        self.assertNotEqual(rc, 0)
        self.assertIn("no match", out.lower())
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m unittest tests.test_prices -v`
Expected: `FileNotFoundError` for `mwi-price-query.py`.

- [ ] **Step 3: Create `mwi-price-query.py` (single-item mode only first)**

```python
#!/usr/bin/env python3
"""Query MWI historical price database.

Usage:
    mwi-price-query.py <item>            # single item history
    mwi-price-query.py --cheap           # scan low-percentile items
"""

from __future__ import annotations

import argparse
import datetime as _dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mwi_prices

MAX_ROWS_SHOWN = 50


def _fmt_ts(ts: int) -> str:
    return _dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def _fmt_int(v) -> str:
    if v is None or v < 0:
        return "—"
    if v >= 1_000_000:
        return f"{v / 1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v / 1_000:.0f}k"
    return str(v)


def _since_ts(days: int) -> int:
    return int(_dt.datetime.now().timestamp()) - days * 86400


def _print_single(conn, item_hrid: str, level: int, days: int, out=sys.stdout):
    rows = mwi_prices.history(conn, item_hrid, level, _since_ts(days))
    if not rows:
        print(f"No data for {item_hrid} (lv {level}) in last {days} days.", file=out)
        return
    s = mwi_prices.summarize(rows)
    print(f"{item_hrid} (lv {level}) — last {days} days, {s['sample_size']} samples",
          file=out)
    print("─" * 60, file=out)
    print(f"current:   ask {_fmt_int(s['current_ask'])}   "
          f"bid {_fmt_int(s['current_bid'])}   "
          f"at {_fmt_ts(s['current_ts'])}", file=out)
    if s["ask_avg"] is not None:
        print(f"{days}d avg:   ask {s['ask_avg']}", file=out)
        print(f"{days}d low:   ask {s['ask_min']}  ({_fmt_ts(s['ask_min_ts'])})",
              file=out)
        print(f"{days}d high:  ask {s['ask_max']}  ({_fmt_ts(s['ask_max_ts'])})",
              file=out)
        print(f"percentile: current ask at {s['ask_percentile']}%  "
              f"({'低位可考虑买入' if s['ask_percentile'] <= 20 else 'neutral'})",
              file=out)
    print("", file=out)
    print(f"{'time':<18}{'ask':>8}{'bid':>8}{'vol':>10}", file=out)
    for ts, ask, bid, _p, vol in rows[:MAX_ROWS_SHOWN]:
        print(f"{_fmt_ts(ts):<18}{_fmt_int(ask):>8}{_fmt_int(bid):>8}"
              f"{_fmt_int(vol):>10}", file=out)
    if len(rows) > MAX_ROWS_SHOWN:
        print(f"... ({len(rows) - MAX_ROWS_SHOWN} more rows)", file=out)


def _resolve_item(conn, query: str, out=sys.stdout) -> str | None:
    matches = mwi_prices.fuzzy_match(conn, query)
    if not matches:
        print(f"No match for {query!r}. (Run `mwi-price-logger.py` first?)", file=out)
        return None
    if len(matches) > 1:
        print(f"Ambiguous ({len(matches)} matches). Be more specific:", file=out)
        for m in matches[:20]:
            print(f"  {m}", file=out)
        if len(matches) > 20:
            print(f"  ... ({len(matches) - 20} more)", file=out)
        return None
    return matches[0]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("item", nargs="?", help="Item name or hrid (fuzzy match).")
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--level", type=int, default=0)
    p.add_argument("--db", default=str(mwi_prices.DEFAULT_DB_PATH))
    p.add_argument("--cheap", action="store_true",
                   help="Scan all items currently at historical lows.")
    p.add_argument("--percentile", type=float, default=20.0,
                   help="Threshold for --cheap mode (default 20).")
    args = p.parse_args(argv)

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"No database at {db_path}. Run mwi-price-logger.py first.",
              file=sys.stdout)
        return 2

    conn = mwi_prices.open_db(db_path)
    try:
        if args.cheap:
            print("--cheap mode not yet implemented.", file=sys.stdout)
            return 2
        if not args.item:
            p.print_help()
            return 2
        resolved = _resolve_item(conn, args.item)
        if not resolved:
            return 2
        _print_single(conn, resolved, args.level, args.days)
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests**

Run: `python3 -m unittest tests.test_prices -v`
Expected: all pass.

- [ ] **Step 5: Manual smoke test against real DB**

Run: `python3 mwi-price-query.py cheese --days 30`
Expected: well-formatted output; `current` / `avg` / `low` / `high` / table.

- [ ] **Step 6: Commit**

```bash
git add mwi-price-query.py tests/test_prices.py
git commit -m "Add price query CLI — single item mode"
```

---

### Task 7: Query CLI — --cheap scanner

**Files:**
- Modify: `mwi-price-query.py`
- Modify: `tests/test_prices.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_prices.py`:

```python
class TestCheapScan(unittest.TestCase):
    def setUp(self):
        self.q = _load_query()
        self.tmp_db = Path(self.id() + ".db")
        if self.tmp_db.exists():
            self.tmp_db.unlink()
        conn = mwi_prices.open_db(str(self.tmp_db))
        base = 1_700_000_000
        step = 4 * 3600
        cheap_series = [200, 210, 220, 230, 240, 210, 150]  # current at 0th percentile
        steady_series = [100, 100, 100, 100, 100, 100, 100]  # flat, 50th
        for i in range(7):
            mwi_prices.insert_snapshot(conn, base + i * step, {
                "/items/cheap_item":  {"0": {"a": cheap_series[i],  "b": cheap_series[i] - 5,  "p": 0, "v": 100}},
                "/items/steady_item": {"0": {"a": steady_series[i], "b": steady_series[i] - 5, "p": 0, "v": 100}},
            })
        conn.close()

    def tearDown(self):
        if self.tmp_db.exists():
            self.tmp_db.unlink()

    def _capture(self, argv):
        buf = io.StringIO()
        with patch("sys.stdout", buf):
            rc = self.q.main(argv + ["--db", str(self.tmp_db)])
        return rc, buf.getvalue()

    def test_cheap_lists_low_percentile_item(self):
        rc, out = self._capture(["--cheap", "--days", "30", "--percentile", "20"])
        self.assertEqual(rc, 0)
        self.assertIn("cheap_item", out)
        self.assertNotIn("steady_item", out)

    def test_cheap_respects_percentile_threshold(self):
        rc, out = self._capture(["--cheap", "--days", "30", "--percentile", "60"])
        self.assertEqual(rc, 0)
        self.assertIn("cheap_item", out)
        self.assertIn("steady_item", out)
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m unittest tests.test_prices -v`
Expected: new tests fail (`--cheap mode not yet implemented` is printed; `cheap_item` not found).

- [ ] **Step 3: Implement `--cheap` scan**

In `mwi-price-query.py`, replace the `if args.cheap:` branch in `main` and add a new helper. Specifically:

Replace:
```python
        if args.cheap:
            print("--cheap mode not yet implemented.", file=sys.stdout)
            return 2
```
with:
```python
        if args.cheap:
            _print_cheap(conn, args.level, args.days, args.percentile)
            return 0
```

And insert this helper just above `_resolve_item`:

```python
def _print_cheap(conn, level: int, days: int, threshold: float, out=sys.stdout):
    since = _since_ts(days)
    items = mwi_prices.items_with_data(conn, level=level)
    results = []
    for hrid in items:
        rows = mwi_prices.history(conn, hrid, level, since)
        s = mwi_prices.summarize(rows)
        if not s or s["ask_percentile"] is None:
            continue
        if s["sample_size"] < 2:
            continue
        if s["ask_percentile"] <= threshold:
            results.append((s["ask_percentile"], hrid, s))
    results.sort()
    print(f"Items with current ask ≤ {threshold}th percentile over last {days} days "
          f"({len(results)} hit)", file=out)
    print("─" * 80, file=out)
    print(f"{'item':<40}{'current':>10}{'min':>10}{'avg':>10}{'pct':>8}",
          file=out)
    for pct, hrid, s in results:
        print(f"{hrid:<40}{_fmt_int(s['current_ask']):>10}"
              f"{_fmt_int(s['ask_min']):>10}{s['ask_avg']!s:>10}"
              f"{pct:>7.1f}%", file=out)
```

- [ ] **Step 4: Run tests**

Run: `python3 -m unittest tests.test_prices -v`
Expected: all tests pass.

- [ ] **Step 5: Manual smoke test**

Run: `python3 mwi-price-query.py --cheap --days 30`
Expected: either empty list (if only one snapshot) or a ranked list. No errors.

- [ ] **Step 6: Commit**

```bash
git add mwi-price-query.py tests/test_prices.py
git commit -m "Add --cheap mode to price query CLI"
```

---

### Task 8: README section + cron install helper

**Files:**
- Modify: `README.md`
- Create: `install-price-logger-cron.sh`

- [ ] **Step 1: Add README section**

Append to `README.md` just before the `## License` section (or before `## Support` if present):

```markdown
## 历史价格记录

采集 MWI 公开的 `marketplace.json` 到本地 SQLite，用于查找买入时机。

### 安装 cron

```bash
./install-price-logger-cron.sh
```

这会在当前用户的 crontab 里加一条每 30 分钟运行一次的任务（官方数据 4 小时刷新一次，脚本会按 timestamp 自动去重）。

### 查询用法

```bash
# 单物品走势
python3 mwi-price-query.py cheese --days 30

# 扫描当前处于历史低位的物品（默认阈值 20 分位）
python3 mwi-price-query.py --cheap --days 30 --percentile 20
```

数据库位于 `data/prices.db`，不纳入版本控制。
```

- [ ] **Step 2: Create the cron installer**

```bash
#!/usr/bin/env bash
# Install a cron entry to run the price logger every 30 minutes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGGER="$SCRIPT_DIR/mwi-price-logger.py"
LOG_FILE="$SCRIPT_DIR/logs/mwi-price-logger.log"
PYTHON_BIN="$(command -v python3)"
ENTRY="*/30 * * * * $PYTHON_BIN $LOGGER >> $LOG_FILE 2>&1"

if [[ ! -x "$LOGGER" && ! -f "$LOGGER" ]]; then
    echo "ERROR: $LOGGER not found" >&2
    exit 1
fi

mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/data"

CURRENT="$(crontab -l 2>/dev/null || true)"
if echo "$CURRENT" | grep -Fq "$LOGGER"; then
    echo "cron entry for $LOGGER already present; skipping."
    exit 0
fi

{ echo "$CURRENT"; echo "$ENTRY"; } | crontab -
echo "installed: $ENTRY"
```

Make it executable:

```bash
chmod +x install-price-logger-cron.sh
```

- [ ] **Step 3: Run full test suite one more time**

Run: `python3 -m unittest tests.test_prices -v`
Expected: every test passes.

- [ ] **Step 4: Commit and push**

```bash
git add README.md install-price-logger-cron.sh
git commit -m "Document price history feature and add cron installer"
git push origin main
```

(Pushing because CLAUDE.md says md file changes should be committed and pushed automatically.)

- [ ] **Step 5: Install cron on this machine and verify**

```bash
./install-price-logger-cron.sh
crontab -l | grep mwi-price-logger
```

Expected: the newly installed line appears.

Wait ~30 minutes (or run once manually) and check:

```bash
tail logs/mwi-price-logger.log
```

Expected: an `inserted ... rows` or `skipped: timestamp unchanged` line.

---

## Self-Review

Spec coverage:
- Collector script with dedup → Task 5 ✓
- SQLite schema → Task 1 ✓
- Cron `*/30` → Task 8 ✓
- Single-item CLI with current / min / max / avg / percentile / table → Tasks 4, 6 ✓
- `--cheap` scanner → Task 7 ✓
- Fuzzy name match with ambiguity handling → Tasks 3, 6 ✓
- `data/` in gitignore → Task 1 ✓
- All levels stored (not just 0) → Task 2 ✓
- `-1` ask/bid handling → Tasks 2, 4 ✓
- Percentile formula matches spec (`(r-1)/(n-1)*100`, `n=1 → 50`) → Task 4 ✓
- Error handling (fetch failure, empty DB) → Tasks 5, 6 ✓
