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


if __name__ == "__main__":
    unittest.main()
