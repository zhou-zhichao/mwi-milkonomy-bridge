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


def _print_single(conn, item_hrid: str, level: int, days: int, out=None):
    if out is None:
        out = sys.stdout
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


def _resolve_item(conn, query: str, out=None) -> str | None:
    if out is None:
        out = sys.stdout
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
