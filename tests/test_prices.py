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
        self.assertEqual(mwi_prices.percentile([100, 200, 300], 150), 50.0)

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

    def test_summary_current_sentinel_still_reports_history(self):
        rows = [
            (3000, -1, -1, 0, 0),
            (2000, 100, 95, 98, 50),
            (1000, 200, 180, 190, 50),
        ]
        s = mwi_prices.summarize(rows)
        self.assertEqual(s["current_ask"], -1)
        self.assertEqual(s["ask_min"], 100)
        self.assertEqual(s["ask_max"], 200)
        self.assertIsNone(s["ask_percentile"])
        self.assertEqual(s["sample_size"], 2)

    def test_summary_current_none_does_not_crash(self):
        rows = [
            (3000, None, None, None, None),
            (2000, 100, 95, 98, 50),
        ]
        s = mwi_prices.summarize(rows)
        self.assertIsNone(s["current_ask"])
        self.assertEqual(s["ask_min"], 100)
        self.assertIsNone(s["ask_percentile"])
        self.assertEqual(s["sample_size"], 1)

    def test_summary_empty(self):
        self.assertIsNone(mwi_prices.summarize([]))


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


if __name__ == "__main__":
    unittest.main()
