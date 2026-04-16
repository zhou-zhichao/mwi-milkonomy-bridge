#!/usr/bin/env python3
"""MWI Production Profit Calculator v2

Faithful port of Milkonomy's ManufactureCalculator. Includes:
- Per-action skill levels
- Equipment buffs (with enhancement multipliers)
- House room bonuses
- Tea buffs (Level / Efficiency / Artisan / Gourmet / Speed)
- 2% market tax
- Essence and rare drop value

Skipped (per user request):
- Community buffs

Usage:
    python3 mwi-profit-calc-v2.py <character_data.json>

Outputs JSON with `best` and `top10`.
"""

import json
import sys
import urllib.request
from typing import Any

DATA_URL = "https://milkonomy.pages.dev/data/data.json"
MARKET_URL = "https://www.milkywayidle.com/game_data/marketplace.json"

PRODUCTION_ACTIONS = {
    "cheesesmithing", "crafting", "tailoring", "cooking", "brewing"
    # Note: alchemy uses different calculators (transmute/decompose/coinify)
    # Skipping for v2 first pass; can add later
}

# Per Milkonomy: 生产类房间 buff
HOUSE_BONUS_PER_LEVEL = {
    "Efficiency": 0.015,
    "Experience": 0.0005,
    "RareFind": 0.002,
}

MIN_VOLUME = 10  # 物品成交量门槛 (避免无人交易的物品)
COIN_HRID = "/items/coin"
TAX_RATE = 0.98  # 2% market tax
EXCLUDE_EQUIPMENT = True  # 排除装备 (装备市场深度不够, 风险高)


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "mwi-calc/2.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


# === Buff aggregation ===

def parse_character(char_data: dict) -> dict:
    """Extract a flat config from MWI's init_character_data."""
    cfg = {
        "skill_levels": {},     # action -> level
        "equipment": [],        # list of {hrid, enhanceLevel, location}
        "house_levels": {},     # action -> house level
        "tea": {},              # action -> [tea_hrid, ...]
        "inventory": {},        # item_hrid -> count (库存)
    }

    # Skills
    for s in char_data.get("characterSkills", []):
        skill = s["skillHrid"].replace("/skills/", "")
        cfg["skill_levels"][skill] = s.get("level", 0)

    # Equipment + Inventory
    for item in char_data.get("characterItems", []):
        loc = item.get("itemLocationHrid", "")
        if not loc:
            continue
        if loc == "/item_locations/inventory":
            cfg["inventory"][item["itemHrid"]] = item.get("count", 0)
        else:
            cfg["equipment"].append({
                "hrid": item.get("itemHrid"),
                "enhanceLevel": item.get("enhancementLevel", 0),
                "location": loc,
            })

    # House
    for hrid, room in (char_data.get("characterHouseRoomMap") or {}).items():
        if not room:
            continue
        # Map house room → action
        # /house_rooms/forge → cheesesmithing
        # /house_rooms/brewery → brewing
        # etc.
        ROOM_TO_ACTION = {
            "/house_rooms/dairy_barn": "milking",
            "/house_rooms/garden": "foraging",
            "/house_rooms/log_shed": "woodcutting",
            "/house_rooms/forge": "cheesesmithing",
            "/house_rooms/workshop": "crafting",
            "/house_rooms/sewing_parlor": "tailoring",
            "/house_rooms/kitchen": "cooking",
            "/house_rooms/brewery": "brewing",
            "/house_rooms/laboratory": "alchemy",
            "/house_rooms/observatory": "enhancing",
        }
        action = ROOM_TO_ACTION.get(hrid)
        if action:
            cfg["house_levels"][action] = room.get("level", 0)

    # Tea
    for action_type, slots in (char_data.get("actionTypeDrinkSlotsMap") or {}).items():
        action = action_type.replace("/action_types/", "")
        teas = []
        for slot in (slots or []):
            if slot and slot.get("itemHrid"):
                teas.append(slot["itemHrid"])
        if teas:
            cfg["tea"][action] = teas

    return cfg


def build_buff_map(action: str, char_cfg: dict, game_data: dict) -> dict:
    """Build the action-specific buff map (matches Milkonomy's getBuffOf)."""
    buffs: dict[str, float] = {}
    items = game_data["itemDetailMap"]
    enh_table = game_data.get("enhancementLevelTotalBonusMultiplierTable", [])

    def add_equipment_buffs(eq_hrid: str, enh_level: int):
        item = items.get(eq_hrid)
        if not item:
            return
        ed = item.get("equipmentDetail")
        if not ed:
            return
        stats = ed.get("noncombatStats") or {}
        bonuses = ed.get("noncombatEnhancementBonuses") or {}
        mult = enh_table[enh_level] if 0 <= enh_level < len(enh_table) else 0
        for key, value in stats.items():
            bonus = bonuses.get(key, 0)
            buffs[key] = buffs.get(key, 0) + value + bonus * mult

    # 1. All equipment (tools, body, legs, etc.)
    for eq in char_cfg["equipment"]:
        add_equipment_buffs(eq["hrid"], eq["enhanceLevel"])

    # 2. House bonus (per Milkonomy: per skill * per_level)
    house_lvl = char_cfg["house_levels"].get(action, 0)
    for key, per_lvl in HOUSE_BONUS_PER_LEVEL.items():
        buff_key = f"{action}{key}"
        buffs[buff_key] = buffs.get(buff_key, 0) + per_lvl * house_lvl

    # 3. Tea (with drinkConcentration but we set it to 0)
    drink_conc = buffs.get("drinkConcentration", 0)
    for tea_hrid in char_cfg["tea"].get(action, []):
        item = items.get(tea_hrid)
        if not item:
            continue
        cd = item.get("consumableDetail") or {}
        for buff in cd.get("buffs") or []:
            type_hrid = buff.get("typeHrid", "")
            flat = buff.get("flatBoost", 0) * (1 + drink_conc)
            # 茶的 buff 类型 → action stat key
            if type_hrid == f"/buff_types/{action}_level":
                buffs[f"{action}Level"] = buffs.get(f"{action}Level", 0) + flat
            elif type_hrid == "/buff_types/efficiency":
                buffs[f"{action}Efficiency"] = buffs.get(f"{action}Efficiency", 0) + flat
            elif type_hrid == "/buff_types/artisan":
                buffs[f"{action}Artisan"] = buffs.get(f"{action}Artisan", 0) + flat
            elif type_hrid == "/buff_types/action_level":
                # 工匠茶的等级 debuff
                buffs[f"{action}Level"] = buffs.get(f"{action}Level", 0) - buff.get("flatBoost", 0)
            elif type_hrid == "/buff_types/gourmet":
                buffs[f"{action}Gourmet"] = buffs.get(f"{action}Gourmet", 0) + flat
            elif type_hrid == "/buff_types/wisdom":
                buffs[f"{action}Experience"] = buffs.get(f"{action}Experience", 0) + flat
            elif type_hrid == "/buff_types/action_speed":
                buffs[f"{action}Speed"] = buffs.get(f"{action}Speed", 0) + flat
            # processing/blessed/gathering 这里跳过 (不影响生产)

    return buffs


def get_buff(buffs: dict, action: str, key: str) -> float:
    """模仿 Milkonomy 的 getBuffOf: action-specific + global skilling."""
    return buffs.get(f"{action}{key}", 0) + buffs.get(f"skilling{key}", 0)


# === Calculator ===

def get_market_info(market_data: dict, hrid: str, level: int = 0) -> dict:
    item = market_data.get(hrid, {})
    tier = item.get(str(level), {})
    return {
        "ask": tier.get("a", -1),
        "bid": tier.get("b", -1),
        "volume": tier.get("v", 0),
    }


def calc_action_profit(action_def: dict, action: str, buffs: dict,
                       player_level: int, market_data: dict,
                       game_data: dict) -> dict | None:
    """计算单个生产动作的利润 (Milkonomy ManufactureCalculator 的 Python 版)."""
    action_level = action_def.get("levelRequirement", {}).get("level", 0)
    base_time_cost = action_def.get("baseTimeCost", 0)
    if base_time_cost <= 0:
        return None

    # 加上茶的 Level buff
    effective_player_level = player_level + get_buff(buffs, action, "Level")

    efficiency = 1 + max(0, (effective_player_level - action_level) * 0.01) \
                 + get_buff(buffs, action, "Efficiency")
    speed = 1 + get_buff(buffs, action, "Speed")
    time_cost = base_time_cost / speed
    actions_ph = (3.6e12 / time_cost) * efficiency

    artisan_buff = get_buff(buffs, action, "Artisan")
    gourmet_buff = get_buff(buffs, action, "Gourmet")
    essence_ratio = get_buff(buffs, action, "EssenceFind")
    rare_ratio = get_buff(buffs, action, "RareFind")

    # === 输入成本 ===
    input_cost = 0.0

    # upgradeItemHrid: 装备升级需要低级版本作为输入 (count=1, 不受 artisan 影响)
    upgrade_hrid = action_def.get("upgradeItemHrid")
    if upgrade_hrid:
        info = get_market_info(market_data, upgrade_hrid, level=0)
        if info["ask"] <= 0:
            return None
        input_cost += info["ask"]

    for inp in action_def.get("inputItems") or []:
        info = get_market_info(market_data, inp["itemHrid"])
        if info["ask"] <= 0:
            return None
        count = inp["count"] * (1 - artisan_buff)
        input_cost += count * info["ask"]

    # === 输出价值 ===
    output_value = 0.0
    for out in action_def.get("outputItems") or []:
        info = get_market_info(market_data, out["itemHrid"])
        if info["bid"] <= 0 or info["volume"] < MIN_VOLUME:
            return None
        count = out["count"] * (1 + gourmet_buff)
        output_value += count * info["bid"]

    # === Essence 掉落 ===
    for ess in action_def.get("essenceDropTable") or []:
        info = get_market_info(market_data, ess["itemHrid"])
        if info["bid"] > 0:
            avg_count = ess.get("maxCount", 1)  # Milkonomy 用 maxCount, 不是 avg
            rate = ess["dropRate"] * (1 + essence_ratio)
            output_value += avg_count * rate * info["bid"]

    # === Rare 掉落 ===
    for rare in action_def.get("rareDropTable") or []:
        info = get_market_info(market_data, rare["itemHrid"])
        if info["bid"] > 0:
            avg_count = rare.get("maxCount", 1)
            rate = rare["dropRate"] * (1 + rare_ratio)
            output_value += avg_count * rate * info["bid"]

    # === 茶消耗 ===
    # Milkonomy: count = 3600/300/consumePH * (1 + drinkConc)
    # consumePH = actionsPH (for production)
    drink_conc = buffs.get("drinkConcentration", 0)
    # tea_per_action_seconds = 12 (3600/300)
    tea_cost_per_hour = 0.0
    char_cfg_teas: list[str] = []  # Filled below; needs char cfg
    # We'll compute tea cost outside since we don't have char cfg here

    # 2% 市场税 (Milkonomy: income * 0.98)
    output_value *= TAX_RATE

    # === Per hour ===
    cost_ph = input_cost * actions_ph
    income_ph = output_value * actions_ph
    profit_ph = income_ph - cost_ph

    return {
        "profit_per_hour": profit_ph,
        "profit_per_day": profit_ph * 24,
        "profit_per_action": profit_ph / actions_ph if actions_ph > 0 else 0,
        "income_per_hour": income_ph,
        "cost_per_hour": cost_ph,
        "actions_per_hour": actions_ph,
        "efficiency": efficiency,
        "speed": speed,
        "time_cost_seconds": time_cost / 1e9,
        "input_cost": input_cost,
        "output_value": output_value,
    }


def add_tea_cost(profit: dict, char_cfg: dict, action: str, market_data: dict, buffs: dict):
    """从总利润里减去茶的成本 (Milkonomy 的茶 = 实时消耗)."""
    actions_ph = profit["actions_per_hour"]
    if actions_ph <= 0:
        return
    consume_ph = actions_ph
    drink_conc = buffs.get("drinkConcentration", 0)
    # tea_count_per_hour = 3600/300/consume_ph * consume_ph * (1 + drink_conc)
    #                    = 3600/300 * (1 + drink_conc) = 12 * (1 + drink_conc)
    # (note: count is per-action, but multiplied by consume_ph, so per-hour total = 12 * (1+conc))
    tea_per_hour = 12 * (1 + drink_conc)
    tea_cost_ph = 0.0
    for tea_hrid in char_cfg["tea"].get(action, []):
        info = get_market_info(market_data, tea_hrid)
        if info["ask"] > 0:
            tea_cost_ph += tea_per_hour * info["ask"]
    profit["cost_per_hour"] += tea_cost_ph
    profit["profit_per_hour"] -= tea_cost_ph
    profit["profit_per_day"] = profit["profit_per_hour"] * 24
    profit["tea_cost_per_hour"] = tea_cost_ph


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mwi-profit-calc-v2.py <char_data.json>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        char_data = json.load(f)

    char_cfg = parse_character(char_data)

    print(f"# Skills: {char_cfg['skill_levels']}", file=sys.stderr)
    print(f"# House: {char_cfg['house_levels']}", file=sys.stderr)
    print(f"# Tea: {char_cfg['tea']}", file=sys.stderr)
    print(f"# Equipment count: {len(char_cfg['equipment'])}", file=sys.stderr)

    game_data = fetch_json(DATA_URL)
    market_json = fetch_json(MARKET_URL)
    market_data = market_json.get("marketData", market_json)

    actions = game_data["actionDetailMap"]
    skill_detail_map = game_data["skillDetailMap"]
    cat_map = game_data["actionCategoryDetailMap"]

    # Pre-compute buff maps for each production action
    buff_maps = {}
    for action in PRODUCTION_ACTIONS:
        buff_maps[action] = build_buff_map(action, char_cfg, game_data)

    results = []
    for hrid, ad in actions.items():
        if ad.get("function") != "/action_functions/production":
            continue
        action_type = ad.get("type", "").replace("/action_types/", "")
        if action_type not in PRODUCTION_ACTIONS:
            continue
        req = ad.get("levelRequirement", {})
        req_skill = req.get("skillHrid", "").replace("/skills/", "")
        req_level = req.get("level", 0)
        player_level = char_cfg["skill_levels"].get(req_skill, 0)
        if player_level < req_level:
            continue
        if not ad.get("inputItems") or not ad.get("outputItems"):
            continue

        # 排除装备 (output item 的 category 是 equipment)
        if EXCLUDE_EQUIPMENT:
            out_hrid = ad["outputItems"][0]["itemHrid"]
            out_item = game_data["itemDetailMap"].get(out_hrid, {})
            if out_item.get("categoryHrid") == "/item_categories/equipment":
                continue

        # 库存检查: 必须有所有材料 (包括 upgradeItem)
        # 不然 MWI 不会让 Start
        upgrade_hrid = ad.get("upgradeItemHrid")
        if upgrade_hrid and char_cfg["inventory"].get(upgrade_hrid, 0) <= 0:
            continue
        missing = False
        for inp in ad["inputItems"]:
            if char_cfg["inventory"].get(inp["itemHrid"], 0) < inp["count"]:
                missing = True
                break
        if missing:
            continue

        buffs = buff_maps[action_type]
        profit = calc_action_profit(ad, action_type, buffs, player_level,
                                    market_data, game_data)
        if profit is None or profit["profit_per_hour"] <= 0:
            continue

        # 减去茶成本
        add_tea_cost(profit, char_cfg, action_type, market_data, buffs)
        if profit["profit_per_hour"] <= 0:
            continue

        cat_hrid = ad.get("category", "")
        cat_name = cat_map.get(cat_hrid, {}).get("name", "")
        skill_label = skill_detail_map.get(f"/skills/{req_skill}", {}).get("name", req_skill.title())

        # Output item info (for auto-sell)
        _out_hrid = ad["outputItems"][0]["itemHrid"]
        _out_name = game_data["itemDetailMap"].get(_out_hrid, {}).get("name", "")
        _out_market = get_market_info(market_data, _out_hrid)

        # Input items info (for material replenishment)
        _artisan = get_buff(buffs, action_type, "Artisan")
        _input_items = []
        for inp in ad.get("inputItems") or []:
            _inp_hrid = inp["itemHrid"]
            _inp_name = game_data["itemDetailMap"].get(_inp_hrid, {}).get("name", "")
            _input_items.append({
                "name": _inp_name,
                "hrid": _inp_hrid,
                "count": round(inp["count"] * (1 - _artisan), 4),
            })

        results.append({
            "action_hrid": hrid,
            "name": ad["name"],
            "skill": action_type,
            "skill_label": skill_label,
            "category": cat_name,
            "level_required": req_level,
            "profit_per_hour": round(profit["profit_per_hour"]),
            "profit_per_day": round(profit["profit_per_day"]),
            "profit_per_action": round(profit["profit_per_action"], 2),
            "actions_per_hour": round(profit["actions_per_hour"], 2),
            "efficiency": round(profit["efficiency"], 4),
            "speed": round(profit["speed"], 4),
            "time_cost_seconds": round(profit["time_cost_seconds"], 2),
            "input_cost": round(profit["input_cost"], 2),
            "output_value": round(profit["output_value"], 2),
            "tea_cost_per_hour": round(profit.get("tea_cost_per_hour", 0)),
            "output_item_name": _out_name,
            "output_item_hrid": _out_hrid,
            "inventory_count": char_cfg["inventory"].get(_out_hrid, 0),
            "bid_price": _out_market["bid"],
            "input_items": _input_items,
        })

    results.sort(key=lambda x: x["profit_per_hour"], reverse=True)

    if not results:
        print(json.dumps({"error": "No profitable production found"}))
        sys.exit(1)

    output = {
        "best": results[0],
        "top10": results[:10],
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
