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
