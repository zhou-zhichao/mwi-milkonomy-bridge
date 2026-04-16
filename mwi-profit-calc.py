#!/usr/bin/env python3
"""MWI Production Profit Calculator

Fetches game data + market prices, calculates profit/hour for all production
actions, filters by character skill levels, returns the most profitable item.

Usage:
    # Pass skill levels as JSON string
    python3 mwi-profit-calc.py '{"cheesesmithing":125,"brewing":126,"crafting":65,...}'

    # Or pass individual skill=level pairs
    python3 mwi-profit-calc.py cheesesmithing=125 brewing=126 crafting=65

Output (JSON):
    {
        "action_hrid": "/actions/cheesesmithing/crimson_cheese",
        "name": "Crimson Cheese",
        "skill": "cheesesmithing",
        "skill_label": "Cheesesmithing",
        "category": "Material",
        "level_required": 50,
        "profit_per_hour": 1234567,
        "profit_per_day": 29629608
    }
"""

import json
import sys
import urllib.request

DATA_URL = "https://milkonomy.pages.dev/data/data.json"
MARKET_URL = "https://www.milkywayidle.com/game_data/marketplace.json"


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "mwi-profit-calc/1.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


MIN_VOLUME = 10  # Minimum trading volume to trust the price


def get_market_info(market_data, item_hrid):
    """Get item market info: ask, bid, volume."""
    item = market_data.get(item_hrid, {})
    tier = item.get("0", {})
    return {
        "ask": tier.get("a", -1),
        "bid": tier.get("b", -1),
        "volume": tier.get("v", 0),
    }


def get_market_price(market_data, item_hrid, price_type="bid"):
    """Get item price. price_type: 'bid' (sell price) or 'ask' (buy price)."""
    info = get_market_info(market_data, item_hrid)
    key = "bid" if price_type == "bid" else "ask"
    price = info[key]
    return price if price > 0 else -1


def calc_profit(action, market_data):
    """Calculate profit per hour for a production action.

    Returns None if any required price is unavailable.
    """
    # Input cost (buy at ask price)
    input_cost = 0
    for inp in action.get("inputItems") or []:
        price = get_market_price(market_data, inp["itemHrid"], "ask")
        if price < 0:
            return None
        input_cost += price * inp["count"]

    # Output value (sell at bid price, must have sufficient volume)
    output_value = 0
    for out in action.get("outputItems") or []:
        info = get_market_info(market_data, out["itemHrid"])
        if info["bid"] <= 0 or info["volume"] < MIN_VOLUME:
            return None
        output_value += info["bid"] * out["count"]

    # Essence drop value
    for ess in action.get("essenceDropTable") or []:
        price = get_market_price(market_data, ess["itemHrid"], "bid")
        if price > 0:
            avg_count = (ess["minCount"] + ess["maxCount"]) / 2
            output_value += price * ess["dropRate"] * avg_count

    # Rare drop value
    for rare in action.get("rareDropTable") or []:
        price = get_market_price(market_data, rare["itemHrid"], "bid")
        if price > 0:
            avg_count = (rare["minCount"] + rare["maxCount"]) / 2
            output_value += price * rare["dropRate"] * avg_count

    profit_per_action = output_value - input_cost
    # baseTimeCost is in nanoseconds
    time_sec = action["baseTimeCost"] / 1e9
    actions_per_hour = 3600 / time_sec
    profit_per_hour = profit_per_action * actions_per_hour

    return {
        "profit_per_action": profit_per_action,
        "profit_per_hour": profit_per_hour,
        "profit_per_day": profit_per_hour * 24,
        "input_cost": input_cost,
        "output_value": output_value,
    }


def parse_skill_levels(args):
    """Parse skill levels from CLI args."""
    if len(args) == 1 and args[0].startswith("{"):
        return json.loads(args[0])
    levels = {}
    for arg in args:
        if "=" in arg:
            skill, level = arg.split("=", 1)
            levels[skill.strip()] = int(level.strip())
    return levels


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mwi-profit-calc.py cheesesmithing=125 brewing=126 ...", file=sys.stderr)
        sys.exit(1)

    skill_levels = parse_skill_levels(sys.argv[1:])

    # Normalize skill names: add /skills/ prefix if missing
    normalized = {}
    for k, v in skill_levels.items():
        key = k if k.startswith("/skills/") else f"/skills/{k}"
        normalized[key] = v
    skill_levels = normalized

    # Fetch data
    game_data = fetch_json(DATA_URL)
    market_json = fetch_json(MARKET_URL)
    market_data = market_json.get("marketData", market_json)

    actions = game_data["actionDetailMap"]
    categories = game_data["actionCategoryDetailMap"]

    results = []

    for hrid, action in actions.items():
        # Only production actions
        if action.get("function") != "/action_functions/production":
            continue

        # Check level requirement
        req = action.get("levelRequirement", {})
        req_skill = req.get("skillHrid", "")
        req_level = req.get("level", 0)

        if req_skill not in skill_levels:
            continue
        if skill_levels[req_skill] < req_level:
            continue

        # Must have input and output items
        if not action.get("inputItems") or not action.get("outputItems"):
            continue

        profit = calc_profit(action, market_data)
        if profit is None or profit["profit_per_hour"] <= 0:
            continue

        # Get category/tab name
        cat_hrid = action.get("category", "")
        cat_name = categories.get(cat_hrid, {}).get("name", "")

        # Skill name (e.g., "cheesesmithing" from "/action_types/cheesesmithing")
        action_type = action.get("type", "")
        skill_short = action_type.replace("/action_types/", "")

        # Skill display label
        skill_detail = game_data["skillDetailMap"].get(req_skill, {})
        skill_label = skill_detail.get("name", skill_short.title())

        results.append({
            "action_hrid": hrid,
            "name": action["name"],
            "skill": skill_short,
            "skill_label": skill_label,
            "category": cat_name,
            "level_required": req_level,
            "profit_per_hour": round(profit["profit_per_hour"]),
            "profit_per_day": round(profit["profit_per_day"]),
            "profit_per_action": round(profit["profit_per_action"], 2),
            "input_cost": round(profit["input_cost"], 2),
            "output_value": round(profit["output_value"], 2),
        })

    results.sort(key=lambda x: x["profit_per_hour"], reverse=True)

    if not results:
        print(json.dumps({"error": "No profitable production found"}))
        sys.exit(1)

    # Output top 10
    output = {
        "best": results[0],
        "top10": results[:10],
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
