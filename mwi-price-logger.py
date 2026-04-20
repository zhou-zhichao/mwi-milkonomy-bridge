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
import urllib.error
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
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as e:
        print(f"ERROR: fetch failed: {type(e).__name__}: {e}", file=sys.stderr)
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
