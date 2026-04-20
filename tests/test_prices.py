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


if __name__ == "__main__":
    unittest.main()
