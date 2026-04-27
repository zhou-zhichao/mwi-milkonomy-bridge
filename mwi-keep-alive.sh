#!/usr/bin/env bash
# MWI Keep-Alive Script
# 用独立 Chrome profile + remote debugging 定期刷新 MWI session
#
# 工作原理:
#   1. 启动一个独立的 Chrome 实例 (带 --remote-debugging-port)
#   2. 用 agent-browser 通过 CDP 连接操控
#   3. 打开 MWI 页面, 利用已保存的 Cookie 自动恢复 session
#   4. 如果 session 有效 → 刷新保活; 过期 → 提示手动登录
#
# 用法:
#   首次设置: ./mwi-keep-alive.sh --setup   (启动 Chrome, 手动登录保存 session)
#   定时保活: ./mwi-keep-alive.sh            (自动检查并保活)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/mwi-keep-alive-$(date '+%Y-%m-%d').log"
LAST_RUN_FILE="$SCRIPT_DIR/.mwi-last-run"
CHROME_PROFILE="$HOME/.mwi-chrome-profile"
CDP_PORT=9222
AB="$(command -v agent-browser || echo "$HOME/.npm-global/bin/agent-browser")"
MWI_URL="https://www.milkywayidle.com/"
CDP_HELPER="$SCRIPT_DIR/mwi-cdp-helper.py"
PROFIT_CALC="$SCRIPT_DIR/mwi-profit-calc-v2.py"

# 间隔配置 (秒)
MIN_INTERVAL=$((3 * 3600))   # 最少 3 小时
MAX_INTERVAL=$((5 * 3600))   # 最多 5 小时
MAX_RANDOM_DELAY=${MAX_RANDOM_DELAY:-$((55 * 60))} # 启动前随机等待 0~55 分钟 (配合非整数 cron 分钟, 覆盖整个小时)

# 自动卖出配置
SELL_RESERVE=${SELL_RESERVE:-50000000}   # 保留 50M 货值, 超出部分卖出
SELL_FRACTION=${SELL_FRACTION:-0.2}      # 每次只卖溢出部分的 20% (防砸盘)

# 挂牌配置 (v2: 挂 ask / bid 单而非直接吃单)
MAX_LISTINGS=${MAX_LISTINGS:-23}         # 游戏最大挂牌数
LISTING_RESERVE_SLOTS=${LISTING_RESERVE_SLOTS:-0}  # 预留几个槽不用 (默认 0 = 全部可用)

# 材料补货配置 (v2: 瞬间 9h + 挂 9h = 18h 总覆盖)
MATERIAL_INSTANT_HOURS=${MATERIAL_INSTANT_HOURS:-9}   # 瞬间买到的目标小时数
MATERIAL_LISTING_HOURS=${MATERIAL_LISTING_HOURS:-9}   # 挂 buy 单的目标小时数
MATERIAL_TRIGGER_HOURS=${MATERIAL_TRIGGER_HOURS:-18}  # 总覆盖低于此值触发补货

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 检查距离上次运行是否过了足够的间隔 (模拟不规律的人类行为)
should_run() {
    if [[ ! -f "$LAST_RUN_FILE" ]]; then
        return 0  # 从未运行过, 立即执行
    fi
    local last_run now elapsed
    last_run=$(cat "$LAST_RUN_FILE")
    now=$(date +%s)
    elapsed=$((now - last_run))

    # 在 MIN~MAX 之间随机选一个阈值
    local threshold=$(( MIN_INTERVAL + RANDOM % (MAX_INTERVAL - MIN_INTERVAL) ))

    if (( elapsed >= threshold )); then
        return 0
    else
        local remaining=$(( (threshold - elapsed) / 60 ))
        log "距离上次运行仅 $((elapsed / 3600))h$((elapsed % 3600 / 60))m, 再等约 ${remaining}m, 跳过"
        return 1
    fi
}

mark_run() {
    date +%s > "$LAST_RUN_FILE"
}

# 检查 CDP 端口是否可用
cdp_is_running() {
    curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1
}

# 启动独立的 Chrome 实例
start_chrome() {
    if cdp_is_running; then
        log "Chrome 已在 CDP 端口 $CDP_PORT 运行"
        return 0
    fi

    log "启动 Chrome (profile: $CHROME_PROFILE, port: $CDP_PORT)..."
    DISPLAY=:0 google-chrome \
        --remote-debugging-port="$CDP_PORT" \
        --no-sandbox \
        --user-data-dir="$CHROME_PROFILE" \
        "$@" \
        >/dev/null 2>&1 &
    disown

    # 等待 Chrome 启动
    local retries=10
    while (( retries-- > 0 )); do
        sleep 1
        if cdp_is_running; then
            log "Chrome 启动成功"
            return 0
        fi
    done

    log "错误: Chrome 启动超时"
    return 1
}

# 关闭 Chrome 和 agent-browser
# 注: 测试确认 SIGTERM 不会丢 cookie (cookie 是实时写盘的)
stop_chrome() {
    "$AB" --cdp "$CDP_PORT" close 2>/dev/null || true
    pkill -f "/opt/google/chrome.*user-data-dir=$CHROME_PROFILE" 2>/dev/null || true
}

cleanup() {
    log "清理 agent-browser 连接..."
    "$AB" --cdp "$CDP_PORT" close 2>/dev/null || true
    # 不杀 Chrome — 保持 session 活跃
}
trap cleanup EXIT

# 打开 MWI 页面 (用同一个 CDP session 注入 WebSocket hook + 导航, 确保 hook 装上)
open_mwi() {
    log "连接 Chrome 并打开 MWI..."
    "$AB" --cdp "$CDP_PORT" close 2>/dev/null || true
    sleep 1
    # 注入 hook + 导航 (在同一个 CDP session 内, 确保 hook 在第一次 navigation 前装好)
    python3 "$CDP_HELPER" inject_and_navigate "$MWI_URL" >/dev/null 2>&1 || {
        log "警告: hook 注入失败, fallback 到普通 open"
        "$AB" --cdp "$CDP_PORT" open "$MWI_URL"
    }
    "$AB" --cdp "$CDP_PORT" wait --load networkidle
    sleep 2
}

# 检查页面状态: "game" / "login" / "character_select" / "unknown"
check_state() {
    local snapshot
    snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || echo "")

    if echo "$snapshot" | grep -qi 'Select Character\|Slot [0-9]'; then
        echo "character_select"
    elif echo "$snapshot" | grep -qi 'Welcome Back\|ENTER GAME'; then
        echo "welcome_back"
    elif echo "$snapshot" | grep -qi 'tab "LOGIN"\|tab "REGISTER"\|Play As Guest'; then
        echo "login"
    elif echo "$snapshot" | grep -qi "NavigationBar\|inventory\|skill\|actionQueue\|Milking\|Foraging\|Woodcutting"; then
        echo "game"
    else
        echo "unknown"
    fi
}

# 首次设置: 启动 headed Chrome 让用户手动登录
setup_mode() {
    log "=== 首次设置模式 ==="
    log "启动 Chrome, 请手动登录你的 MWI 账号"

    stop_chrome
    sleep 2
    start_chrome

    log "Chrome 已启动, 请在浏览器中:"
    log "  1. 打开 $MWI_URL"
    log "  2. 登录你的账号 (过验证码)"
    log "  3. 登录成功后, session 会自动保存到 $CHROME_PROFILE"
    log ""
    log "完成后按 Ctrl+C 退出"

    while true; do
        sleep 5
    done
}

# Welcome Back 页面 → 点击 ENTER GAME
enter_game() {
    log "检测到 Welcome Back 页面, 点击 ENTER GAME..."
    "$AB" --cdp "$CDP_PORT" find text "ENTER GAME" click 2>/dev/null && {
        sleep 5
        log "已点击 ENTER GAME"
        return 0
    }
    log "未找到 ENTER GAME 按钮"
    return 1
}

# 从游戏 UI 读取技能等级 (返回 key=value 格式)
read_skill_levels() {
    local snapshot
    snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i -C 2>/dev/null || echo "")
    # 解析 "SkillName123" 格式
    echo "$snapshot" | grep -oP '(?:Milking|Foraging|Woodcutting|Cheesesmithing|Crafting|Tailoring|Cooking|Brewing|Alchemy|Enhancing)\d+' \
        | sort -u | while read -r entry; do
            local name level
            name=$(echo "$entry" | grep -oP '^[A-Za-z]+')
            level=$(echo "$entry" | grep -oP '\d+$')
            echo "${name,,}=$level"  # lowercase
        done
}

# 获取当前正在做的动作名 (只返回名字, 不带括号/计数)
get_current_action() {
    local raw
    raw=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'EVALEOF' 2>/dev/null
(function() {
    // Header_actionName 是当前动作名 + 括号计数, 例如 "Super Brewing Tea (3180)"
    var el = document.querySelector('[class*="Header_actionName"]')
        || document.querySelector('[class*="actionName"]')
        || document.querySelector('[class*="currentAction"]');
    if (!el) return "";
    var text = (el.textContent || "").trim();
    // 提取名字: 第一个 ( 之前的部分
    var idx = text.indexOf("(");
    if (idx > 0) text = text.substring(0, idx).trim();
    return text;
})()
EVALEOF
)
    # eval 输出形如 "Super Brewing Tea" (带 JSON 引号), 去掉
    raw="${raw#\"}"
    raw="${raw%\"}"
    echo "$raw"
}

# 关闭所有可关闭的弹窗 (Quest Modal / Welcome Back / Modal_closeButton 等)
# 这些弹窗会挡住 optimize 的点击
dismiss_modals() {
    local snapshot close_refs ref
    # 用 snapshot 找 close 按钮 (CDP click 比 JS click 可靠)
    for _ in 1 2 3; do
        snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        # 找 button "Close" / "X" / 类似 (|| true: grep 无匹配时防止 pipefail+set-e 退出)
        close_refs=$(echo "$snapshot" | grep -E 'button "(Close|✕|×)"' | grep -oP 'ref=\Ke\d+' | head -3 || true)
        if [[ -z "$close_refs" ]]; then
            break
        fi
        for ref in $close_refs; do
            "$AB" --cdp "$CDP_PORT" click "@$ref" 2>/dev/null || true
            sleep 0.5
        done
    done
    # JS 兜底: closeButton class
    "$AB" --cdp "$CDP_PORT" eval --stdin <<'EVALEOF' 2>/dev/null || true
(function() {
    var btns = document.querySelectorAll('[class*="closeButton"], [class*="CloseButton"]');
    var n = 0;
    btns.forEach(function(b) {
        if (b.offsetParent !== null) {
            try { b.click(); n++; } catch(e) {}
        }
    });
    return n;
})()
EVALEOF
    sleep 1
}

# 类人随机延迟 (秒数, 浮点)
# 用法: human_sleep 2 5  → 2~5 秒
human_sleep() {
    local min="$1" max="$2"
    local range=$(( max - min ))
    local extra=$(awk -v r="$range" 'BEGIN { srand(); printf "%.2f", rand() * r }')
    sleep "$(awk -v m="$min" -v e="$extra" 'BEGIN { printf "%.2f", m + e }')"
}

# 用 JS 点击包含指定文本的 SkillAction 卡片 (整个 card)
# 先 scrollIntoView 因为 headless viewport 小, 物品可能在屏幕外
click_skill_action() {
    local item_name="$1"
    local b64
    b64=$(printf '%s' "$item_name" | base64 -w0)
    local js
    js=$(cat <<JSEOF
(function() {
    var name = atob("$b64");
    var nameEl = Array.from(document.querySelectorAll('[class*="SkillAction_name"]'))
        .find(function(e) { return e.textContent === name; });
    if (!nameEl) return "NOT_FOUND";
    var card = nameEl.closest('[class*="SkillAction_skillAction"]');
    if (!card) return "NO_CARD";
    card.scrollIntoView({block: "center", inline: "center"});
    return "SCROLLED";
})()
JSEOF
)
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true
    sleep 1
    js=$(cat <<JSEOF
(function() {
    var name = atob("$b64");
    var nameEl = Array.from(document.querySelectorAll('[class*="SkillAction_name"]'))
        .find(function(e) { return e.textContent === name; });
    if (!nameEl) return "NOT_FOUND";
    var card = nameEl.closest('[class*="SkillAction_skillAction"]');
    if (!card) return "NO_CARD";
    card.click();
    return "OK";
})()
JSEOF
)
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true
}

# 用 JS 点击侧边栏的技能 (按技能名匹配, 比如 "Brewing")
# MWI 的 NavigationBar 结构: span.NavigationBar_label > div > div.NavigationBar_navigationLink (clickable)
click_sidebar_skill() {
    local skill="$1"  # e.g. "Brewing"
    local b64
    b64=$(printf '%s' "$skill" | base64 -w0)
    local js
    js=$(cat <<'JSEOF'
(function() {
    var skill = atob("__B64__");
    var labels = Array.from(document.querySelectorAll('[class*="NavigationBar_label"]'));
    var label = labels.find(function(l) { return (l.textContent || "").trim() === skill; });
    if (!label) return "NO_LABEL";
    var clickable = label.closest('[class*="NavigationBar_navigationLink"], [class*="NavigationBar_nav__"]');
    if (!clickable) return "NO_CLICKABLE";
    clickable.click();
    return "OK";
})()
JSEOF
)
    js="${js//__B64__/$b64}"
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true
}

# 用 JS 点击 tab (按 role=tab 找)
click_tab_by_text() {
    local tab_name="$1"
    local b64
    b64=$(printf '%s' "$tab_name" | base64 -w0)
    local js
    js=$(cat <<'JSEOF'
(function() {
    var name = atob("__B64__");
    var tabs = Array.from(document.querySelectorAll('[role="tab"]'));
    var match = tabs.find(function(t) { return (t.textContent || "").trim() === name; });
    if (!match) return "NOT_FOUND";
    match.click();
    return "OK";
})()
JSEOF
)
    js="${js//__B64__/$b64}"
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true
}

# 通过 snapshot 找到元素 ref 并点击 (用于侧边栏 / tab)
# match_mode: "exact" (默认) 或 "prefix"
# 带 retry: 最多尝试 5 次, 每次间隔 1 秒, 避免页面加载时序问题
click_by_snapshot() {
    local target="$1"
    local mode="${2:-exact}"
    local attempts=5
    local ref snapshot
    while (( attempts-- > 0 )); do
        snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i -C 2>/dev/null)
        if [[ "$mode" == "prefix" ]]; then
            ref=$(echo "$snapshot" | grep -F "\"$target" | head -1 | grep -oP 'ref=\Ke\d+')
        else
            ref=$(echo "$snapshot" | grep -F "\"$target\"" | head -1 | grep -oP 'ref=\Ke\d+')
        fi
        if [[ -n "$ref" ]]; then
            "$AB" --cdp "$CDP_PORT" click "@$ref" 2>/dev/null && return 0
        fi
        sleep 1
    done
    return 1
}

# 检查弹窗是否真的打开了 Start / Start Now 按钮 (反检测: 不盲点)
# 注: 角色 idle 时按钮是 "Start", 有队列时是 "Start Now"
verify_start_now_dialog() {
    local item_name="$1"
    local b64
    b64=$(printf '%s' "$item_name" | base64 -w0)
    local js
    js='(function(){var name=atob("'"$b64"'");'
    js+='var buttons=Array.from(document.querySelectorAll("button")).filter(function(b){return b.offsetParent!==null;});'
    js+='var startBtn=buttons.find(function(b){var t=b.textContent.trim();return t==="Start Now"||t==="Start";});'
    js+='if(!startBtn)return "no_start_btn";'
    js+='var dialog=startBtn.closest("[class*=\"Modal\"],[class*=\"Dialog\"],[class*=\"dialog\"],[class*=\"modal\"]")||document.body;'
    js+='if(dialog.textContent.indexOf(name)<0)return "name_not_in_dialog";'
    js+='return "ok";})()'
    local result
    result=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true)
    [[ "$result" == *'"ok"'* ]]
}

# 从生产弹窗中获取缺少的材料列表 + 生产时长
# 返回 JSON: {"duration_s":6.25, "missing":[{"name":"Dragon Fruit","have":0,"need":0.9}, ...]}
get_missing_materials() {
    "$AB" --cdp "$CDP_PORT" eval --stdin <<'EVALEOF' 2>/dev/null || true
(function() {
    var modal = document.querySelector('[class*="SkillActionDetail_skillActionDetail"]');
    if (!modal) return '{"duration_s":0,"missing":[]}';
    // 提取 Duration (例如 "6.25s")
    var durMatch = modal.textContent.match(/Duration\s*([\d.]+)s/);
    var duration_s = durMatch ? parseFloat(durMatch[1]) : 10;
    var rows = modal.querySelectorAll('[class*="SkillActionDetail_inputItem"], [class*="inputItem"]');
    if (rows.length === 0) {
        // Fallback: parse from text "160K / 0.9 ☐ Red Tea Leaf" pattern
        var text = modal.textContent;
        var pattern = /([\d,.KMB]+)\s*\/\s*([\d,.]+)\s*[^\w]*\s*([A-Z][a-zA-Z\s']+?)(?=[\d,.KMB]+\s*\/|Upgrade|Output|Essence|Rare|Duration|Bonus|Produce|Loadout|$)/g;
        var missing = [];
        var m;
        while ((m = pattern.exec(text)) !== null) {
            var have = parseFloat(m[1].replace(/,/g,'').replace('K','e3').replace('M','e6').replace('B','e9'));
            var need = parseFloat(m[2]);
            if (have < need) missing.push({name: m[3].trim(), have: have, need: need});
        }
        return JSON.stringify({duration_s: duration_s, missing: missing});
    }
    var missing = [];
    rows.forEach(function(row) {
        var text = row.textContent;
        var match = text.match(/([\d,.KMB]+)\s*\/\s*([\d,.]+)/);
        if (match) {
            var have = parseFloat(match[1].replace(/,/g,'').replace('K','e3').replace('M','e6').replace('B','e9'));
            var need = parseFloat(match[2]);
            if (have < need) {
                var nameEl = row.querySelector('[class*="name"], svg[aria-label]');
                var name = nameEl ? (nameEl.getAttribute('aria-label') || nameEl.textContent.trim()) : text.replace(/[\d,.\/\s]+/g,'').trim();
                missing.push({name: name, have: have, need: need});
            }
        }
    });
    return JSON.stringify({duration_s: duration_s, missing: missing});
})()
EVALEOF
}

# 在 Marketplace 购买指定物品
# 用法: buy_from_marketplace "Dragon Fruit" 100
# 流程: 搜索 → 选物品 → 等订单簿 → 点 Buy → 输入数量 → Post Buy Order
buy_from_marketplace() {
    local item_name="$1"
    local quantity="$2"
    local b64
    b64=$(printf '%s' "$item_name" | base64 -w0)

    log "  → 去市场购买 $quantity 个 $item_name"

    # 1. 导航到 Marketplace
    local r
    r=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'NAVEOF' 2>/dev/null || true
(function() {
    var labels = Array.from(document.querySelectorAll('[class*="NavigationBar_label"]'));
    var label = labels.find(function(l) { return (l.textContent || "").trim() === "Marketplace"; });
    if (!label) return "NO_LABEL";
    label.closest('[class*="NavigationBar_navigationLink"]').click();
    return "OK";
})()
NAVEOF
)
    if [[ "$r" != *OK* ]]; then
        log "  ✗ 无法导航到市场"
        return 1
    fi
    human_sleep 2 3
    ensure_market_listings_tab

    # 2. 搜索物品
    local filter_ref
    filter_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'searchbox "Item Filter"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$filter_ref" ]]; then
        log "  ✗ 找不到搜索框"
        return 1
    fi
    # React 兼容搜索: native setter + input event (fill 可能不触发 React 过滤更新)
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var input=document.querySelector("input[type=search][placeholder*=Filter]");if(!input)return "NO_INPUT";input.focus();var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;s.call(input,"");input.dispatchEvent(new Event("input",{bubbles:true}));s.call(input,name);input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));return "OK";})()' | base64 -w0)" 2>/dev/null || true
    human_sleep 1 2

    # 3. 点击匹配的物品 (通过 aria-label 精确匹配)
    r=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var svgs=Array.from(document.querySelectorAll("svg[aria-label]"));var match=svgs.find(function(s){return s.getAttribute("aria-label")===name;});if(!match)return "NOT_FOUND";var clickable=match.closest("[class*=Item_clickable],[class*=Item_item]");if(!clickable)return "NO_CLICKABLE";clickable.click();return "OK";})()' | base64 -w0)" 2>/dev/null || true)
    if [[ "$r" != *OK* ]]; then
        log "  ✗ 在市场中找不到 $item_name ($r)"
        return 1
    fi
    human_sleep 2 3

    # 4. 等待订单簿加载 (等 Buy 按钮出现)
    local attempts=10
    local buy_ready=""
    while (( attempts-- > 0 )); do
        local snap
        snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        if echo "$snap" | grep -q 'button "Buy"'; then
            buy_ready=1
            break
        fi
        # 如果还在 Loading, 尝试点 Refresh
        if echo "$snap" | grep -q 'button "Refresh"'; then
            local refresh_ref
            refresh_ref=$(echo "$snap" | grep 'button "Refresh"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
            [[ -n "$refresh_ref" ]] && "$AB" --cdp "$CDP_PORT" click "@$refresh_ref" 2>/dev/null || true
        fi
        sleep 2
    done
    if [[ -z "$buy_ready" ]]; then
        log "  ✗ 订单簿加载超时"
        return 1
    fi

    # 5. 点第一个 Buy 按钮 (最低 ask 价的卖单)
    local buy_ref
    buy_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'button "Buy"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$buy_ref" ]]; then
        log "  ✗ 找不到 Buy 按钮"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$buy_ref" 2>/dev/null || true
    human_sleep 1 2

    # 6. 检查 Buy Now 弹窗里 "Available At Price" 的数量是否够
    local available
    available=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'AVAILEOF' 2>/dev/null || true
(function() {
    var modal = document.querySelector('[class*="Modal_modal"], [class*="modal"]');
    if (!modal) return "0";
    var text = modal.textContent;
    var match = text.match(/Available At Price[:\s]*([\d,KMB]+)/i);
    if (!match) return "0";
    var s = match[1].replace(/,/g, '');
    if (s.endsWith('K')) return String(Math.floor(parseFloat(s) * 1000));
    if (s.endsWith('M')) return String(Math.floor(parseFloat(s) * 1000000));
    return s;
})()
AVAILEOF
)
    available="${available//\"/}"
    available="${available:-0}"
    log "  → 当前 ask 价可买: $available 个, 需要: $quantity 个"

    if (( available < quantity )); then
        log "  ✗ 当前价位供给不足 ($available < $quantity), 跳过"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi

    # 7. 在 Buy Now 弹窗中输入数量并下单
    r=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var qty='$quantity';var input=document.querySelector("[class*=Modal] input[type=number], [class*=modal] input[type=number]");if(!input)return "no_input";input.focus();var nativeInputValueSetter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;nativeInputValueSetter.call(input,String(qty));input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));return "qty_set:"+qty;})()' | base64 -w0)" 2>/dev/null || true)
    if [[ "$r" != *qty_set* ]]; then
        log "  ✗ 无法设置购买数量: $r"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi
    log "  → 设置数量: $quantity"
    human_sleep 1 2

    # 8. 点 Post Buy Order
    local post_ref
    post_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'button "Post Buy Order"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$post_ref" ]]; then
        log "  ✗ 找不到 Post Buy Order 按钮"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$post_ref" 2>/dev/null || true
    human_sleep 2 3
    log "  ✓ 已下单购买 $quantity 个 $item_name"
    return 0
}

# 在 Marketplace 卖出指定物品 (以 bid 价即时成交)
# 用法: sell_to_marketplace "Gathering Tea" 100
# 流程: 导航市场 → 搜索 → 选物品 → 等订单簿 → 点 Sell → 输入数量 → Post Sell Order
sell_to_marketplace() {
    local item_name="$1"
    local quantity="$2"
    local b64
    b64=$(printf '%s' "$item_name" | base64 -w0)

    log "  → 去市场卖出 $quantity 个 $item_name"

    # 1. 导航到 Marketplace
    local r
    r=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'NAVEOF' 2>/dev/null || true
(function() {
    var labels = Array.from(document.querySelectorAll('[class*="NavigationBar_label"]'));
    var label = labels.find(function(l) { return (l.textContent || "").trim() === "Marketplace"; });
    if (!label) return "NO_LABEL";
    label.closest('[class*="NavigationBar_navigationLink"]').click();
    return "OK";
})()
NAVEOF
)
    if [[ "$r" != *OK* ]]; then
        log "  ✗ 无法导航到市场"
        return 1
    fi
    human_sleep 2 3
    ensure_market_listings_tab

    # 2. 搜索物品
    local filter_ref
    filter_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'searchbox "Item Filter"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$filter_ref" ]]; then
        log "  ✗ 找不到搜索框"
        return 1
    fi
    # React 兼容搜索: native setter + input event (fill 可能不触发 React 过滤更新)
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var input=document.querySelector("input[type=search][placeholder*=Filter]");if(!input)return "NO_INPUT";input.focus();var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;s.call(input,"");input.dispatchEvent(new Event("input",{bubbles:true}));s.call(input,name);input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));return "OK";})()' | base64 -w0)" 2>/dev/null || true
    human_sleep 1 2

    # 3. 点击匹配的物品 (只点 Marketplace 面板里的, 不点 Inventory/Header)
    r=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var svgs=Array.from(document.querySelectorAll("svg[aria-label]"));var match=svgs.find(function(s){if(s.getAttribute("aria-label")!==name)return false;var el=s;while(el){if(el.className&&typeof el.className==="string"&&el.className.indexOf("MarketplacePanel")>=0)return true;el=el.parentElement;}return false;});if(!match)return "NOT_FOUND";var clickable=match.closest("[class*=Item_clickable],[class*=Item_item]");if(!clickable)return "NO_CLICKABLE";clickable.click();return "OK";})()' | base64 -w0)" 2>/dev/null || true)
    if [[ "$r" != *OK* ]]; then
        log "  ✗ 在市场中找不到 $item_name ($r)"
        return 1
    fi
    human_sleep 2 3

    # 4. 等待订单簿加载 (等 Sell 按钮出现)
    local attempts=10
    local sell_ready=""
    while (( attempts-- > 0 )); do
        local snap
        snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        if echo "$snap" | grep -q 'button "Sell"'; then
            sell_ready=1
            break
        fi
        if echo "$snap" | grep -q 'button "Refresh"'; then
            local refresh_ref
            refresh_ref=$(echo "$snap" | grep 'button "Refresh"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
            [[ -n "$refresh_ref" ]] && "$AB" --cdp "$CDP_PORT" click "@$refresh_ref" 2>/dev/null || true
        fi
        sleep 2
    done
    if [[ -z "$sell_ready" ]]; then
        log "  ✗ 订单簿加载超时"
        return 1
    fi

    # 5. 读取最高 bid 的深度 (Sell 按钮同行的 Quantity cell) 并点击 Sell
    local snap
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    local sell_ref
    sell_ref=$(echo "$snap" | grep '  - button "Sell" \[' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$sell_ref" ]]; then
        log "  ✗ 找不到 Sell 按钮"
        return 1
    fi

    # 从订单簿读取最高 bid 的数量
    # snapshot 格式: cell "数量" → cell "价格 Coins" → cell "Sell" → (缩进) button "Sell"
    # 精确匹配 button "Sell" (不匹配 "Sell Up Arrow"), 往上 3 行就是数量 cell
    local available
    available=$(echo "$snap" | grep -B3 '  - button "Sell" \[' | head -1 | grep -oP 'cell "\K[^"]+' || true)
    # 处理 K/M 后缀
    available=$(python3 -c "
s = '$available'.replace(',','')
if s.endswith('K'): print(int(float(s[:-1])*1000))
elif s.endswith('M'): print(int(float(s[:-1])*1000000))
elif s.endswith('B'): print(int(float(s[:-1])*1000000000))
elif s.isdigit(): print(s)
else: print(0)
" 2>/dev/null || echo "0")
    log "  → 最高 bid 深度: $available 个"

    # 按 bid 深度限流
    if (( available <= 0 )); then
        log "  ✗ 无买单深度, 跳过"
        return 1
    fi
    if (( available < quantity )); then
        log "  → bid 深度不足, 调整卖出量: $quantity → $available"
        quantity="$available"
    fi

    # 点击 Sell 展开卖出面板
    "$AB" --cdp "$CDP_PORT" click "@$sell_ref" 2>/dev/null || true
    human_sleep 1 2

    # 6. 输入卖出数量 (UI 用 spinbutton, 不是 Modal)
    local spin_ref
    spin_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'spinbutton' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$spin_ref" ]]; then
        log "  ✗ 找不到数量输入框"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi
    r=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var qty='$quantity';var input=document.querySelector("input[role=spinbutton], [class*=Marketplace] input[type=number]");if(!input)return "no_input";input.focus();var nativeInputValueSetter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;nativeInputValueSetter.call(input,String(qty));input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));return "qty_set:"+qty;})()' | base64 -w0)" 2>/dev/null || true)
    if [[ "$r" != *qty_set* ]]; then
        log "  ✗ 无法设置卖出数量: $r"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi
    log "  → 设置数量: $quantity"
    human_sleep 1 2

    # 8. 点 Post Sell Order
    local post_ref
    post_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'button "Post Sell Order"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$post_ref" ]]; then
        log "  ✗ 找不到 Post Sell Order 按钮"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$post_ref" 2>/dev/null || true
    human_sleep 2 3
    log "  ✓ 已下单卖出 $quantity 个 $item_name"
    return 0
}

# ============================================================================
# Marketplace Listing 辅助函数 (v2: 挂 ask / bid 单)
# ============================================================================

# 确保当前在 Market Listings tab (不是 My Listings)
# 因为 collect/read_my_listings 会切到 My Listings, 这里要切回来
ensure_market_listings_tab() {
    local snap tab_ref
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    tab_ref=$(echo "$snap" | grep -F 'tab "Market Listings"' | grep -v 'selected' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -n "$tab_ref" ]]; then
        "$AB" --cdp "$CDP_PORT" click "@$tab_ref" 2>/dev/null || true
        human_sleep 1 2
    fi
}

# 鲁棒地关闭当前打开的市场挂单/确认等模态对话框
# .click() 对 React 的 div 关闭按钮经常无效, 必须派发完整的 pointer/mouse 事件序列
close_marketplace_modal() {
    "$AB" --cdp "$CDP_PORT" eval --stdin <<'CLOSEEOF' 2>/dev/null || true
(function(){
  var modal = document.querySelector('[class*="Modal_modal__"]');
  if (!modal) return 'NO_MODAL';
  var closeBtn = Array.from(modal.querySelectorAll('div')).find(function(d){
    var c = typeof d.className === 'string' ? d.className : '';
    return c.indexOf('Modal_closeButton') === 0 || c.indexOf(' Modal_closeButton') >= 0;
  });
  if (!closeBtn) return 'NO_CLOSE';
  var rect = closeBtn.getBoundingClientRect();
  ['mouseenter','mouseover','mousedown','pointerdown','pointerup','mouseup','click'].forEach(function(t){
    var ctor = t.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
    try { closeBtn.dispatchEvent(new ctor(t, { bubbles: true, cancelable: true, view: window, clientX: rect.x + rect.width/2, clientY: rect.y + rect.height/2 })); } catch(e){}
  });
  return document.querySelector('[class*="Modal_modal__"]') ? 'STILL_OPEN' : 'CLOSED';
})()
CLOSEEOF
}

# 导航到 Marketplace tab
navigate_to_marketplace() {
    local r
    r=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'NAVEOF' 2>/dev/null || true
(function() {
  var labels = Array.from(document.querySelectorAll('[class*="NavigationBar_label"]'));
  var label = labels.find(function(l) { return (l.textContent || "").trim() === "Marketplace"; });
  if (!label) return "NO_LABEL";
  label.closest('[class*="NavigationBar_navigationLink"]').click();
  return "OK";
})()
NAVEOF
)
    [[ "$r" == *OK* ]] || return 1
    human_sleep 1 2
    return 0
}

# 在 Market Listings tab 搜索并打开指定物品的订单簿, 返回成功/失败
# 用法: open_item_in_marketplace "Holy Cheese"
open_item_in_marketplace() {
    local item_name="$1"
    local b64
    b64=$(printf '%s' "$item_name" | base64 -w0)

    # 先确保在 Market Listings tab (带验证重试, 因为 collect_all_listings 可能把我们留在 My Listings)
    local attempt tab_verified=""
    for attempt in 1 2 3; do
        local snap
        snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        if echo "$snap" | grep -qE 'tab "Market Listings" \[selected'; then
            tab_verified=1
            break
        fi
        local tab_ref
        tab_ref=$(echo "$snap" | grep -F 'tab "Market Listings"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
        if [[ -n "$tab_ref" ]]; then
            "$AB" --cdp "$CDP_PORT" click "@$tab_ref" 2>/dev/null || true
            human_sleep 2 3
        else
            human_sleep 1 2
        fi
    done
    if [[ -z "$tab_verified" ]]; then
        log "    ⚠ Market Listings tab 切换未确认"
    fi

    # 搜索物品 (先重新 snapshot 以拿到切换后的 filter_ref)
    local snap filter_ref
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    filter_ref=$(echo "$snap" | grep -F 'searchbox "Item Filter"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$filter_ref" ]]; then
        log "    ✗ 找不到搜索框"
        return 1
    fi
    # React 兼容搜索: 先清空再填入, native setter + input event 确保过滤更新
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var input=document.querySelector("input[type=search][placeholder*=Filter]");if(!input)return "NO_INPUT";input.focus();var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value").set;s.call(input,"");input.dispatchEvent(new Event("input",{bubbles:true}));s.call(input,name);input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));return "OK";})()' | base64 -w0)" 2>/dev/null || true
    human_sleep 1 2

    # 点击物品卡片 (限定在 MarketplacePanel 内, 重试 3 次应对搜索结果延迟渲染)
    local r click_ok=""
    for attempt in 1 2 3; do
        r=$("$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var b64="'"$b64"'";var name=atob(b64);var svgs=Array.from(document.querySelectorAll("svg[aria-label]"));var match=svgs.find(function(s){if(s.getAttribute("aria-label")!==name)return false;var el=s;while(el){if(el.className&&typeof el.className==="string"&&el.className.indexOf("MarketplacePanel")>=0)return true;el=el.parentElement;}return false;});if(!match)return "NOT_FOUND";var clickable=match.closest("[class*=Item_clickable],[class*=Item_item]");if(!clickable)return "NO_CLICKABLE";clickable.click();return "OK";})()' | base64 -w0)" 2>/dev/null || true)
        if [[ "$r" == *OK* ]]; then
            click_ok=1
            break
        fi
        sleep 2
    done
    if [[ -z "$click_ok" ]]; then
        log "    ✗ 市场中找不到 $item_name ($r)"
        return 1
    fi
    human_sleep 2 3

    # 等订单簿加载 (等到 "+ New Sell Listing" 按钮出现)
    local attempts=10 ready=""
    while (( attempts-- > 0 )); do
        snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        if echo "$snap" | grep -q '"+ New Sell Listing"'; then
            ready=1
            break
        fi
        if echo "$snap" | grep -q 'button "Refresh"'; then
            local refresh_ref
            refresh_ref=$(echo "$snap" | grep 'button "Refresh"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
            [[ -n "$refresh_ref" ]] && "$AB" --cdp "$CDP_PORT" click "@$refresh_ref" 2>/dev/null || true
        fi
        sleep 2
    done
    if [[ -z "$ready" ]]; then
        log "    ✗ 订单簿加载超时"
        return 1
    fi
    return 0
}

# 读订单簿的 best ask (最低卖价) 和 best bid (最高买价)
# 输出格式: "best_ask best_bid" (两个数字, 空格分隔; 缺失用 0)
get_order_book_top() {
    local raw
    raw=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'BOOKEOF' 2>/dev/null || echo '"0 0"'
(function(){
  var tables = Array.from(document.querySelectorAll('table'));
  var parsePrice = function(t){ return parseInt((t||'').replace(/[^\d]/g,'')) || 0; };
  var ask = 0, bid = 0;
  tables.forEach(function(t){
    var h = (t.querySelector('thead, tr') || {textContent:''}).textContent || '';
    if (h.indexOf('Ask Price') >= 0) {
      var row = t.querySelector('tbody tr') || t.querySelectorAll('tr')[1];
      if (row) {
        var cells = row.querySelectorAll('td');
        if (cells.length >= 2) ask = parsePrice(cells[1].textContent);
      }
    } else if (h.indexOf('Bid Price') >= 0) {
      var row = t.querySelector('tbody tr') || t.querySelectorAll('tr')[1];
      if (row) {
        var cells = row.querySelectorAll('td');
        if (cells.length >= 2) bid = parsePrice(cells[1].textContent);
      }
    }
  });
  return ask + ' ' + bid;
})()
BOOKEOF
)
    # agent-browser eval 返回 JSON 编码的字符串 (带外层引号), 去掉它们
    raw="${raw#\"}"
    raw="${raw%\"}"
    echo "$raw"
}

# 切到 My Listings tab; 读取所有挂牌, 返回 JSON
# 格式: {"used": 3, "max": 23, "collectable": 0, "listings": [{item, type, filled, total, price}, ...]}
read_my_listings() {
    # 注意: 这个函数的最终 stdout 返回给调用方, 所以中间所有 agent-browser 命令
    # 都要 >/dev/null, 否则 "✓ Done" 会污染返回值
    # 切到 My Listings tab (带验证重试)
    local attempt
    for attempt in 1 2 3; do
        local snap
        snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
        if echo "$snap" | grep -qE 'tab "My Listings[^"]*" \[selected'; then
            break
        fi
        local tab_ref
        tab_ref=$(echo "$snap" | grep -P 'tab "My Listings' | head -1 | grep -oP 'ref=\Ke\d+' || true)
        if [[ -n "$tab_ref" ]]; then
            "$AB" --cdp "$CDP_PORT" click "@$tab_ref" >/dev/null 2>&1 || true
            human_sleep 2 3
        else
            human_sleep 1 2
        fi
    done

    # 等 My Listings 数据加载 (fresh slot 进入后 WebSocket 同步需要时间)
    # 条件: counter 显示 "X / Y"(X 可以是 0, 但必须出现, 代表已加载)
    # 最多等 12 秒
    local wait_left=12
    while (( wait_left > 0 )); do
        local has_data
        has_data=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'PROBEEOF' 2>/dev/null || echo "no"
(function(){
  var counter = Array.from(document.querySelectorAll('div')).find(function(d){
    return typeof d.className === 'string' && d.className.indexOf('MarketplacePanel_listingCount') >= 0;
  });
  // counter 存在 && 包含 "Listings" 文字就算已渲染
  if (!counter) return 'no';
  if (!/\d+\s*\/\s*\d+\s*Listings/.test(counter.textContent)) return 'no';
  // 再检查: 如果 counter 说 used > 0, 但 tbody 没行, 说明数据还没同步 -> 等
  var m = counter.textContent.match(/(\d+)\s*\/\s*\d+\s*Listings/);
  var used = m ? parseInt(m[1]) : 0;
  var tables = Array.from(document.querySelectorAll('table'));
  var myTable = tables.find(function(t){
    var h = (t.querySelector('thead, tr')||{textContent:''}).textContent || '';
    return h.indexOf('Status') >= 0 && h.indexOf('Progress') >= 0;
  });
  var rows = myTable ? myTable.querySelectorAll('tbody tr').length : 0;
  if (used > 0 && rows === 0) return 'partial';
  return 'ready';
})()
PROBEEOF
)
        has_data="${has_data//\"/}"
        if [[ "$has_data" == "ready" ]]; then
            break
        fi
        sleep 1
        wait_left=$((wait_left - 1))
    done

    "$AB" --cdp "$CDP_PORT" eval --stdin <<'LISTEOF' 2>/dev/null || echo '{"used":0,"max":23,"collectable":0,"listings":[]}'
(function(){
  var counter = Array.from(document.querySelectorAll('div')).find(function(d){
    return typeof d.className === 'string' && d.className.indexOf('MarketplacePanel_listingCount') >= 0;
  });
  var used = 0, max = 23;
  if (counter) {
    var m = counter.textContent.match(/(\d+)\s*\/\s*(\d+)\s*Listings/);
    if (m) { used = parseInt(m[1]); max = parseInt(m[2]); }
  }
  var collectBtn = Array.from(document.querySelectorAll('button')).find(function(b){
    return (b.textContent||'').indexOf('Collect All') >= 0;
  });
  var collectable = 0;
  if (collectBtn) {
    var cm = collectBtn.textContent.match(/\((\d+)\)/);
    if (cm) collectable = parseInt(cm[1]);
  }
  var tables = Array.from(document.querySelectorAll('table'));
  var myTable = tables.find(function(t){
    var h = (t.querySelector('thead, tr')||{textContent:''}).textContent || '';
    return h.indexOf('Status') >= 0 && h.indexOf('Progress') >= 0;
  });
  var listings = [];
  if (myTable) {
    var rows = Array.from(myTable.querySelectorAll('tbody tr'));
    rows.forEach(function(r){
      var svg = r.querySelector('svg[aria-label]');
      var cells = Array.from(r.querySelectorAll('td'));
      if (cells.length >= 4) {
        var prog = cells[2].textContent.trim();
        var pm = prog.match(/([\d,\.KMB]+)\s*\/\s*([\d,\.KMB]+)/);
        var parseQty = function(s){
          s = (s||'').replace(/,/g,'');
          if (/K$/.test(s)) return Math.floor(parseFloat(s)*1000);
          if (/M$/.test(s)) return Math.floor(parseFloat(s)*1000000);
          if (/B$/.test(s)) return Math.floor(parseFloat(s)*1000000000);
          return parseInt(s) || 0;
        };
        listings.push({
          item: svg ? svg.getAttribute('aria-label') : null,
          status: cells[0].textContent.trim(),
          type: cells[1].textContent.trim(),
          filled: pm ? parseQty(pm[1]) : 0,
          total: pm ? parseQty(pm[2]) : 0,
          price: parseInt(cells[3].textContent.replace(/[^\d]/g,'')) || 0
        });
      }
    });
  }
  // 兜底: 按 row 数据计算 Filled 条目数, 取 max (按钮读取可能滞后, 但 row 状态更新及时)
  var collectableFromRows = listings.filter(function(L){ return L.status === 'Filled' || L.status === 'Completed'; }).length;
  // used 也兜底: 如果 counter 没读到, 用 listings.length
  if (used === 0 && listings.length > 0) used = listings.length;
  return JSON.stringify({used: used, max: max, collectable: Math.max(collectable, collectableFromRows), listings: listings});
})()
LISTEOF
}

# 收菜: 如果 Collect All (N) 的 N > 0, 就点一下把所有已成交的订单收回来
collect_all_listings() {
    log "=== 收菜检查 ==="
    navigate_to_marketplace || { log "  ✗ 无法进入市场"; return 1; }

    local listings_json
    listings_json=$(read_my_listings)
    # 去掉外层引号 + 反转义 (agent-browser eval 会 JSON 编码字符串返回)
    listings_json="${listings_json#\"}"
    listings_json="${listings_json%\"}"
    listings_json=$(echo "$listings_json" | sed 's/\\"/"/g; s/\\\\/\\/g')

    local collectable
    collectable=$(echo "$listings_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('collectable', 0))" 2>/dev/null || echo "0")

    if [[ "$collectable" == "0" ]] || [[ -z "$collectable" ]]; then
        log "  暂无可收成交 (Collect All: 0)"
        return 0
    fi

    log "  → 发现 $collectable 个已成交订单, 点 Collect All"
    local btn_ref
    btn_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep -F '"Collect All' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$btn_ref" ]]; then
        log "  ✗ 找不到 Collect All 按钮"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$btn_ref" 2>/dev/null || true
    human_sleep 2 3
    log "  ✓ 已收菜"
    return 0
}

# 统计指定物品在 My Listings 里所有 Active Buy 单的剩余未成交数量
# 输入: listings_json (来自 read_my_listings), item_name
# 输出: 剩余总挂单量 (total - filled 之和)
pending_buy_qty_for_item() {
    local listings_json="$1"
    local item_name="$2"
    echo "$listings_json" | python3 -c "
import sys, json
name = '''$item_name'''
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
total = 0
for L in d.get('listings', []):
    if L.get('type') == 'Buy' and L.get('status') == 'Active' and L.get('item') == name:
        total += max(0, L.get('total', 0) - L.get('filled', 0))
print(total)
" 2>/dev/null || echo 0
}

# 点 + 直到价格 >= target, 或 - 直到价格 <= target; 最多 N 次; 返回最终价格
# 用法: adjust_price_in_modal <target> <direction:up|down> <max_clicks>
adjust_price_in_modal() {
    local target="$1"
    local direction="$2"
    local max_clicks="${3:-15}"

    "$AB" --cdp "$CDP_PORT" eval --stdin <<ADJEOF 2>/dev/null || echo "0"
(function(){
  var target = $target;
  var direction = '$direction';
  var maxClicks = $max_clicks;
  var getPrice = function(){
    var d = Array.from(document.querySelectorAll('div')).find(function(e){
      return typeof e.className === 'string' && e.className.indexOf('MarketplacePanel_priceInput__') >= 0;
    });
    return d ? parseInt(d.textContent.replace(/,/g,'')) : null;
  };
  var modal = document.querySelector('[class*="Modal_modal__"]');
  if (!modal) return '0';
  var buttons = Array.from(modal.querySelectorAll('button'));
  var btn = direction === 'up'
    ? buttons.find(function(b){ return b.textContent.trim() === '+'; })
    : buttons.find(function(b){ return b.textContent.trim() === '-'; });
  if (!btn) return '0';
  var last = getPrice();
  var clicks = 0;
  while (clicks < maxClicks) {
    var ok = direction === 'up' ? (last >= target) : (last <= target);
    if (ok) break;
    btn.click();
    var now = getPrice();
    if (now === last) break;
    last = now;
    clicks++;
  }
  return String(last);
})()
ADJEOF
}

# 在 Sell/Buy Listing 模态里设置数量 (使用 React 原生 setter)
set_listing_quantity() {
    local qty="$1"
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' '(function(){var qty='"$qty"';var modal=document.querySelector("[class*=Modal_modal__]");if(!modal)return "no_modal";var input=modal.querySelector("input[type=number]");if(!input)return "no_input";var setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set;setter.call(input,String(qty));input.dispatchEvent(new Event("input",{bubbles:true}));return "ok:"+input.value;})()' | base64 -w0)" 2>/dev/null || echo "error"
}

# 用 CDP 的 ref-click 点模态里的按钮 (React 同步事件; JS .click() 不可靠)
click_modal_button() {
    local btn_text="$1"
    local snap ref
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    # 精确匹配完整按钮名 (如 "Post Sell Listing" 不能被误匹配为 "Post Sell Order")
    ref=$(echo "$snap" | grep -F "button \"$btn_text\"" | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$ref" ]]; then
        echo "no_btn"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$ref" 2>/dev/null || {
        echo "click_failed"
        return 1
    }
    echo "ok:$ref"
}

# 如果弹出 "价格异常" 的 Yes/No 确认框, 点 No 取消 (我们的挂单不应该触发这种警告)
cancel_price_confirm_if_any() {
    local snap
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    if echo "$snap" | grep -qE 'button "No"' && echo "$snap" | grep -qE 'button "Yes"'; then
        local no_ref
        no_ref=$(echo "$snap" | grep -F 'button "No"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
        if [[ -n "$no_ref" ]]; then
            log "    ⚠ 检测到价格异常确认框, 取消"
            "$AB" --cdp "$CDP_PORT" click "@$no_ref" 2>/dev/null || true
            human_sleep 1 2
            return 0
        fi
    fi
    return 1
}

# 挂一个 Sell listing: 价格自动取 best ask 或以上, 数量由调用方决定
# 用法: post_sell_listing "Holy Cheese" 100
# 返回 0: 成功; 1: 失败
post_sell_listing() {
    local item_name="$1"
    local quantity="$2"
    log "  → 挂 Sell 单: $quantity 个 $item_name"

    # 1. 打开物品订单簿
    open_item_in_marketplace "$item_name" || return 1

    # 2. 读 best ask (作为挂牌目标价)
    local book best_ask best_bid
    book=$(get_order_book_top)
    read -r best_ask best_bid <<< "$book"
    if [[ -z "$best_ask" ]] || [[ "$best_ask" == "0" ]]; then
        log "    ✗ 无法读到 best ask, 跳过挂牌"
        return 1
    fi
    log "    订单簿: ask=$best_ask bid=$best_bid"

    # 3. 点 + New Sell Listing
    local snap new_sell_ref
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    new_sell_ref=$(echo "$snap" | grep -F '"+ New Sell Listing"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$new_sell_ref" ]]; then
        log "    ✗ 找不到 + New Sell Listing 按钮"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$new_sell_ref" 2>/dev/null || true
    human_sleep 1 2

    # 4. 调价到 best_ask 或以上 (默认是 best bid, 需要点 + 直到 >= best_ask)
    local final_price
    final_price=$(adjust_price_in_modal "$best_ask" "up" 15)
    final_price="${final_price//\"/}"
    if [[ -z "$final_price" ]] || [[ "$final_price" == "0" ]]; then
        log "    ✗ 调价失败"
        close_marketplace_modal
        return 1
    fi
    log "    最终价: $final_price (目标 $best_ask)"

    # 5. 设置数量
    local r
    r=$(set_listing_quantity "$quantity")
    if [[ "$r" != *ok* ]]; then
        log "    ✗ 设置数量失败: $r"
        close_marketplace_modal
        return 1
    fi
    human_sleep 1 2

    # 6. 点 Post Sell Listing
    r=$(click_modal_button "Post Sell Listing")
    if [[ "$r" != *ok* ]]; then
        log "    ✗ 点 Post Sell Listing 失败: $r"
        close_marketplace_modal
        return 1
    fi
    human_sleep 2 3

    # 7. 处理可能的价格异常确认框
    cancel_price_confirm_if_any && {
        log "    ✗ 挂牌被取消 (价格异常)"
        return 1
    }

    log "    ✓ 已挂 Sell $quantity 个 @ $final_price"
    return 0
}

# 挂一个 Buy listing: 价格自动取 best bid 或以下, 数量由调用方决定
# 用法: post_buy_listing "Milk" 100
# 返回 0: 成功; 1: 失败
post_buy_listing() {
    local item_name="$1"
    local quantity="$2"
    log "  → 挂 Buy 单: $quantity 个 $item_name"

    open_item_in_marketplace "$item_name" || return 1

    local book best_ask best_bid
    book=$(get_order_book_top)
    read -r best_ask best_bid <<< "$book"
    if [[ -z "$best_bid" ]] || [[ "$best_bid" == "0" ]]; then
        log "    ✗ 无法读到 best bid, 跳过挂牌"
        return 1
    fi
    log "    订单簿: ask=$best_ask bid=$best_bid"

    local snap new_buy_ref
    snap=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    new_buy_ref=$(echo "$snap" | grep -F '"+ New Buy Listing"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$new_buy_ref" ]]; then
        log "    ✗ 找不到 + New Buy Listing 按钮"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$new_buy_ref" 2>/dev/null || true
    human_sleep 1 2

    # 默认价 = best ask, 要点 - 直到 <= best_bid
    local final_price
    final_price=$(adjust_price_in_modal "$best_bid" "down" 15)
    final_price="${final_price//\"/}"
    if [[ -z "$final_price" ]] || [[ "$final_price" == "0" ]]; then
        log "    ✗ 调价失败"
        close_marketplace_modal
        return 1
    fi
    log "    最终价: $final_price (目标 $best_bid)"

    local r
    r=$(set_listing_quantity "$quantity")
    if [[ "$r" != *ok* ]]; then
        log "    ✗ 设置数量失败: $r"
        close_marketplace_modal
        return 1
    fi
    human_sleep 1 2

    r=$(click_modal_button "Post Buy Listing")
    if [[ "$r" != *ok* ]]; then
        log "    ✗ 点 Post Buy Listing 失败: $r"
        close_marketplace_modal
        return 1
    fi
    human_sleep 2 3

    cancel_price_confirm_if_any && {
        log "    ✗ 挂牌被取消 (价格异常)"
        return 1
    }

    log "    ✓ 已挂 Buy $quantity 个 @ $final_price"
    return 0
}

# 购买所有缺少的材料, 然后返回生产页面
# 用法: buy_missing_and_retry "Brewing" "Tea" "Super Brewing Tea"
buy_missing_and_retry() {
    local skill_label="$1"
    local category="$2"
    local item_name="$3"

    # 获取缺少的材料列表
    local missing_json
    missing_json=$(get_missing_materials)
    if [[ "$missing_json" == "[]" ]] || [[ -z "$missing_json" ]]; then
        log "  未检测到缺少的材料"
        return 1
    fi

    # 去掉 agent-browser eval 返回的外层 JSON 引号
    missing_json="${missing_json#\"}"
    missing_json="${missing_json%\"}"
    # 反转义
    missing_json=$(echo "$missing_json" | sed 's/\\"/"/g; s/\\\\/\\/g')
    log "  材料信息: $missing_json"

    # 关闭当前弹窗
    "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
    human_sleep 1 2

    # 解析并购买每种缺少的材料
    # 购买量 = 每次消耗 × (9小时 / 单次生产秒数) - 已有库存
    local buy_count
    buy_count=$(echo "$missing_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('missing',[])))" 2>/dev/null || echo "0")
    if [[ "$buy_count" == "0" ]]; then
        log "  无法解析缺少的材料"
        return 1
    fi

    local i=0
    while (( i < buy_count )); do
        local mat_name mat_qty
        # tab 分隔, 物品名可能含空格
        IFS=$'\t' read -r mat_name mat_qty < <(echo "$missing_json" | python3 -c "
import sys, json, math
d = json.load(sys.stdin)
dur = max(1, d.get('duration_s', 10))
mat = d['missing'][$i]
runs_9h = 9 * 3600 / dur
qty = max(1, math.ceil(mat['need'] * runs_9h - mat['have']))
print(mat['name'] + '\t' + str(qty))
" 2>/dev/null)
        log "  → 需购买 $mat_name: $mat_qty 个 (够 9 小时)"
        buy_from_marketplace "$mat_name" "$mat_qty" || {
            log "  ✗ 购买 $mat_name 失败"
            return 1
        }
        i=$((i + 1))
    done

    # 等一下让订单成交
    log "  等待购买成交..."
    human_sleep 3 5

    # 返回生产页面重新尝试
    log "  → 返回生产页面重试"
    switch_production "$skill_label" "$category" "$item_name"
}

# 用 JS 验证当前页面的 h1 标题是否匹配指定技能
verify_page_heading() {
    local expected="$1"
    local b64
    b64=$(printf '%s' "$expected" | base64 -w0)
    local js
    js='(function(){var e=atob("'"$b64"'");var h=document.querySelector("h1");if(!h)return "no_heading";var t=h.textContent.trim();if(t.indexOf(e)>=0)return "ok";return "mismatch:"+t;})()'
    "$AB" --cdp "$CDP_PORT" eval -b "$(printf '%s' "$js" | base64 -w0)" 2>/dev/null || true
}

# 在 MWI 中切换生产: 点技能 → 点 tab → 点物品 → 验证弹窗 → Start Now
# 反检测: 类人延迟, 失败立即退出, 多重确认
switch_production() {
    local skill_label="$1"
    local category="$2"
    local item_name="$3"

    log "切换生产: $skill_label → $category → $item_name"

    # 1. 点左侧技能 (带重试 + 验证页面确实切换了)
    log "  → 点击技能 $skill_label"
    local r attempts navigated=""
    attempts=5
    while (( attempts-- > 0 )); do
        r=$(click_sidebar_skill "$skill_label")
        if [[ "$r" != *OK* ]]; then
            log "  (尝试 $((5-attempts))/5) 未找到技能: $r"
            sleep 1
            continue
        fi
        sleep 1
        # 验证页面标题确实变了
        r=$(verify_page_heading "$skill_label")
        if [[ "$r" == *ok* ]]; then
            navigated=1
            break
        fi
        log "  (尝试 $((5-attempts))/5) 页面未切换: $r"
        sleep 1
    done
    if [[ -z "$navigated" ]]; then
        log "  ✗ 无法导航到技能 $skill_label, 中止"
        "$AB" --cdp "$CDP_PORT" screenshot "$SCRIPT_DIR/mwi-nav-fail.png" 2>/dev/null || true
        return 1
    fi
    human_sleep 3 6

    # 2. 点分类 tab (带重试)
    log "  → 点击 tab $category"
    attempts=5
    local clicked=""
    while (( attempts-- > 0 )); do
        r=$(click_tab_by_text "$category")
        if [[ "$r" == *OK* ]]; then
            clicked=1
            break
        fi
        log "  (尝试 $((5-attempts))/5) tab 未找到"
        sleep 1
    done
    if [[ -z "$clicked" ]]; then
        log "  ✗ 未找到分类 tab, 中止"
        "$AB" --cdp "$CDP_PORT" screenshot "$SCRIPT_DIR/mwi-tab-fail.png" 2>/dev/null || true
        "$AB" --cdp "$CDP_PORT" snapshot -i -C > "$SCRIPT_DIR/mwi-tab-fail-snapshot.txt" 2>/dev/null || true
        return 1
    fi
    human_sleep 2 4

    # 3. 点物品 card (带重试)
    log "  → 点击物品卡片 $item_name"
    attempts=3
    local card_clicked=""
    while (( attempts-- > 0 )); do
        r=$(click_skill_action "$item_name")
        if [[ "$r" == *OK* ]]; then
            card_clicked=1
            break
        fi
        log "  (尝试 $((3-attempts))/3) 物品卡片未找到: $r"
        sleep 1
    done
    if [[ -z "$card_clicked" ]]; then
        log "  ✗ 点击物品卡片失败, 中止"
        return 1
    fi
    human_sleep 3 6  # 模拟人在看弹窗内容

    # 4. 验证弹窗 (带重试, 弹窗可能需要时间渲染)
    log "  → 验证弹窗"
    attempts=5
    local dialog_ok=""
    while (( attempts-- > 0 )); do
        if verify_start_now_dialog "$item_name"; then
            dialog_ok=1
            break
        fi
        sleep 1
    done
    if [[ -z "$dialog_ok" ]]; then
        log "  ✗ 弹窗未出现或物品名不匹配, 中止"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 1
    fi

    # 5. 点 Start Now (dry-run 模式只验证不真点)
    if [[ "${OPTIMIZE_DRY_RUN:-0}" == "1" ]]; then
        log "  ⚠ DRY-RUN: 跳过 Start Now (导航到弹窗成功)"
        "$AB" --cdp "$CDP_PORT" press Escape 2>/dev/null || true
        return 0
    fi

    # 6. 检查按钮是否被禁用 (CSS 类 Button_disabled, 表示材料不足等)
    log "  → 检查 Start 按钮状态"
    local btn_state
    btn_state=$("$AB" --cdp "$CDP_PORT" eval --stdin <<'EVALEOF' 2>/dev/null || true
(function() {
    var buttons = Array.from(document.querySelectorAll("button")).filter(function(b) { return b.offsetParent !== null; });
    var startBtn = buttons.find(function(b) { var t = b.textContent.trim(); return t === "Start Now" || t === "Start"; });
    if (!startBtn) return "no_btn";
    if (startBtn.className.indexOf("disabled") >= 0 || startBtn.className.indexOf("Disabled") >= 0) return "css_disabled";
    if (startBtn.disabled) return "attr_disabled";
    return "ready:" + startBtn.textContent.trim();
})()
EVALEOF
)
    if [[ "$btn_state" == *css_disabled* ]] || [[ "$btn_state" == *attr_disabled* ]]; then
        log "  ⚠ Start 按钮被禁用, 尝试购买缺少的材料"
        buy_missing_and_retry "$skill_label" "$category" "$item_name"
        return $?
    fi
    if [[ "$btn_state" != *ready* ]]; then
        log "  ✗ Start 按钮未找到: $btn_state, 中止"
        return 1
    fi

    # 用 CDP 真实点击 Start 按钮 (而非 JS .click(), 后者不触发 React 事件)
    local start_text start_ref
    start_text="${btn_state#*ready:}"  # "Start Now" 或 "Start"
    start_text="${start_text//\"/}"
    log "  → CDP 点击: $start_text"
    local snap_start
    snap_start=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    # 优先找 "Start Now", 再找 "Start" (精确匹配避免误点)
    start_ref=$(echo "$snap_start" | grep -F "\"Start Now\"" | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$start_ref" ]]; then
        start_ref=$(echo "$snap_start" | grep -P 'button "Start"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    fi
    if [[ -z "$start_ref" ]]; then
        log "  ✗ 在 snapshot 中未找到 Start 按钮, 中止"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" click "@$start_ref" 2>/dev/null || {
        log "  ✗ CDP click Start 失败"
        return 1
    }
    human_sleep 2 3

    # 7. 处理 "替换队列" 确认弹窗 (如果有队列, MWI 会问 "Are you sure...? Yes/No")
    # idle 状态不会出这个确认
    snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null || true)
    local yes_ref
    yes_ref=$(echo "$snapshot" | grep -F '"Yes"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -n "$yes_ref" ]]; then
        log "  → 检测到替换队列确认, 点 Yes (@$yes_ref)"
        "$AB" --cdp "$CDP_PORT" click "@$yes_ref" 2>/dev/null || {
            log "  ✗ Yes 点击失败"
            return 1
        }
        human_sleep 2 3
    fi

    # 8. 验证生产是否真正开始 (等几秒让服务器处理)
    sleep 3
    local verify_action
    verify_action=$(get_current_action)
    if [[ -z "$verify_action" ]] || [[ "$verify_action" == "Doing nothing"* ]]; then
        log "  ✗ 验证失败: 点击后仍然是 '$verify_action', 生产未启动!"
        "$AB" --cdp "$CDP_PORT" screenshot "$SCRIPT_DIR/mwi-start-fail.png" 2>/dev/null || true
        return 1
    fi
    log "  ✓ 已切换到生产: $item_name (验证: $verify_action)"
}

# 检查材料是否够继续生产, 不够就从市场补货 (v2: 瞬间 + 挂 buy 单)
# 用法: replenish_if_needed "$calc_result" "$char_file"
# 逻辑 (仅针对当前 Top 1 的输入材料):
#   总覆盖 = 库存 + 已挂 buy 单剩余量 (换算成小时)
#   如果 总覆盖 < MATERIAL_TRIGGER_HOURS (默认 18h):
#     1. 瞬间吃 ask 买到库存达 MATERIAL_INSTANT_HOURS (默认 9h)
#     2. 挂 buy 单使已挂量达 MATERIAL_LISTING_HOURS (默认 9h, 价格 = best bid)
replenish_if_needed() {
    local calc_result="$1"
    local char_file="$2"
    log "=== 材料补货检查 ==="

    # 读取当前挂牌 (先切到 My Listings)
    navigate_to_marketplace || { log "  ✗ 无法进入市场"; return 1; }
    local listings_json
    listings_json=$(read_my_listings)
    listings_json="${listings_json#\"}"
    listings_json="${listings_json%\"}"
    listings_json=$(echo "$listings_json" | sed 's/\\"/"/g; s/\\\\/\\/g')

    # 算每种材料的状态 (calc_result/listings/char 通过 env + stdin 传递)
    local plan
    plan=$(CALC_RESULT="$calc_result" \
           LISTINGS_JSON="$listings_json" \
           CHAR_FILE="$char_file" \
           INSTANT_H="$MATERIAL_INSTANT_HOURS" \
           LISTING_H="$MATERIAL_LISTING_HOURS" \
           TRIGGER_H="$MATERIAL_TRIGGER_HOURS" \
           python3 <<'PYEOF' 2>/dev/null || echo "[]"
import json, os, math
calc = json.loads(os.environ['CALC_RESULT'])
try:
    listings = json.loads(os.environ['LISTINGS_JSON'])
except Exception:
    listings = {'listings': []}
with open(os.environ['CHAR_FILE']) as f:
    char = json.load(f)

inventory = {}
for item in char.get('characterItems', []):
    if item.get('itemLocationHrid') == '/item_locations/inventory':
        inventory[item['itemHrid']] = item.get('count', 0)

def pending_buy(name):
    tot = 0
    for L in listings.get('listings', []):
        if L.get('type') == 'Buy' and L.get('status') == 'Active' and L.get('item') == name:
            tot += max(0, L.get('total', 0) - L.get('filled', 0))
    return tot

best = calc['best']
aph = best['actions_per_hour']
instant_h = float(os.environ['INSTANT_H'])
listing_h = float(os.environ['LISTING_H'])
trigger_h = float(os.environ['TRIGGER_H'])

plan = []
for inp in best.get('input_items', []):
    have = inventory.get(inp['hrid'], 0)
    pending = pending_buy(inp['name'])
    consume_ph = inp['count'] * aph
    if consume_ph <= 0:
        continue
    total_cov_h = (have + pending) / consume_ph
    inv_h = have / consume_ph
    pending_h = pending / consume_ph
    if total_cov_h >= trigger_h:
        continue
    instant_need = max(0, math.ceil(consume_ph * instant_h - have))
    listing_need = max(0, math.ceil(consume_ph * listing_h - pending))
    plan.append({
        'name': inp['name'],
        'have': have,
        'pending': pending,
        'inv_h': round(inv_h, 1),
        'pending_h': round(pending_h, 1),
        'total_h': round(total_cov_h, 1),
        'instant_need': instant_need,
        'listing_need': listing_need,
    })
print(json.dumps(plan))
PYEOF
)

    if [[ "$plan" == "[]" ]] || [[ -z "$plan" ]]; then
        log "材料覆盖均 >= ${MATERIAL_TRIGGER_HOURS}h, 无需补货"
        return 0
    fi

    local plan_count
    plan_count=$(echo "$plan" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    log "有 $plan_count 种材料覆盖不足 ${MATERIAL_TRIGGER_HOURS}h, 开始补货"

    local i=0
    while (( i < plan_count )); do
        local mat_name have pending inv_h pending_h total_h instant_need listing_need
        # 用 tab 分隔 (物品名含空格如 "Cheesesmithing Essence")
        IFS=$'\t' read -r mat_name have pending inv_h pending_h total_h instant_need listing_need < <(echo "$plan" | python3 -c "
import sys,json
d = json.load(sys.stdin)[$i]
print('\t'.join([d['name'], str(d['have']), str(d['pending']), str(d['inv_h']), str(d['pending_h']), str(d['total_h']), str(d['instant_need']), str(d['listing_need'])]))
" 2>/dev/null)
        log "  → $mat_name: 库存 $have (${inv_h}h) + 挂单 $pending (${pending_h}h) = ${total_h}h"

        # Step 1: 瞬间吃 ask 买到 instant_h
        if (( instant_need > 0 )); then
            log "    [瞬间] 吃 ask 买 $instant_need 个"
            buy_from_marketplace "$mat_name" "$instant_need" || log "    ✗ 瞬间买失败"
        fi

        # Step 2: 挂 buy 单到 listing_h (挂在 best bid, 排队等成交)
        if (( listing_need > 0 )); then
            # 再检查下挂牌槽位
            local used_now avail_now
            listings_json=$(read_my_listings)
            listings_json="${listings_json#\"}"
            listings_json="${listings_json%\"}"
            listings_json=$(echo "$listings_json" | sed 's/\\"/"/g; s/\\\\/\\/g')
            used_now=$(echo "$listings_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('used', 0))" 2>/dev/null || echo "0")
            avail_now=$(( MAX_LISTINGS - LISTING_RESERVE_SLOTS - used_now ))
            if (( avail_now >= 1 )); then
                log "    [挂单] 挂 $listing_need 个 @ best bid (剩 $avail_now 槽)"
                post_buy_listing "$mat_name" "$listing_need" || log "    ✗ 挂单失败"
            else
                log "    [挂单] 挂牌槽位已满 ($used_now/$MAX_LISTINGS), 跳过挂单"
            fi
        fi
        i=$((i + 1))
    done
    return 0
}

# 自动卖出 (v2): 挂 sell 单而非吃 bid 单
# - 只卖 top1 最赚钱的产出物品
# - 保留 SELL_RESERVE 货值
# - 每次只挂溢出部分的 SELL_FRACTION (默认 20%), 防砸盘
# - 检查挂牌数 <= MAX_LISTINGS - LISTING_RESERVE_SLOTS, 否则回退到直接吃 bid
# 用法: auto_sell_output "$calc_result"
auto_sell_output() {
    local calc_result="$1"
    log "=== 自动卖出检查 ==="

    # 从 calc_result 解析 best item 的产出信息
    local output_name inventory_count bid_price
    output_name=$(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['best']['output_item_name'])" 2>/dev/null)
    inventory_count=$(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['best']['inventory_count'])" 2>/dev/null)
    bid_price=$(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['best']['bid_price'])" 2>/dev/null)

    if [[ -z "$output_name" ]] || [[ -z "$bid_price" ]] || [[ "$bid_price" == "-1" ]] || [[ "$bid_price" == "0" ]]; then
        log "无法获取产出物品信息或无 bid 价, 跳过卖出"
        return 0
    fi

    log "产出物品: $output_name (库存: $inventory_count, bid: $bid_price)"

    # 计算保留量: SELL_RESERVE / bid 价格
    local reserve_count excess
    reserve_count=$(python3 -c "print(max(0, int($SELL_RESERVE / $bid_price)))" 2>/dev/null || echo "0")
    excess=$(( inventory_count - reserve_count ))

    if (( excess <= 0 )); then
        log "库存 $inventory_count ≤ 保留量 $reserve_count (保留 ${SELL_RESERVE} 货值), 不卖"
        return 0
    fi

    # 每次只卖溢出部分的 SELL_FRACTION (防砸盘 + 防止一次大单引人注意)
    local sellable
    sellable=$(python3 -c "import math; print(max(1, int(math.ceil($excess * $SELL_FRACTION))))" 2>/dev/null || echo "1")
    log "保留 $reserve_count 个 (≈${SELL_RESERVE} 货值), 溢出 $excess, 本次卖 $sellable (${SELL_FRACTION}x)"

    # 检查挂牌是否有空余槽位
    navigate_to_marketplace || { log "  ✗ 无法进入市场"; return 1; }
    local listings_json used available_slots
    listings_json=$(read_my_listings)
    listings_json="${listings_json#\"}"
    listings_json="${listings_json%\"}"
    listings_json=$(echo "$listings_json" | sed 's/\\"/"/g; s/\\\\/\\/g')
    used=$(echo "$listings_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('used', 0))" 2>/dev/null || echo "0")
    available_slots=$(( MAX_LISTINGS - LISTING_RESERVE_SLOTS - used ))
    log "  挂牌使用: $used / $MAX_LISTINGS (可用 $available_slots)"

    if (( available_slots >= 1 )); then
        # 有空位, 挂 sell 单在 best ask
        post_sell_listing "$output_name" "$sellable" && return 0
        log "  ⚠ 挂 sell 单失败, 回退到直接吃 bid"
    else
        log "  挂牌槽位已满, 回退到直接吃 bid"
    fi

    # 回退路径: 直接按 bid 价卖 (原有 v1 行为)
    sell_to_marketplace "$output_name" "$sellable"
}

# Slot 1 利润优化的节流文件 (记录上次跑 optimize 的时间)
OPTIMIZE_LAST_RUN_FILE="$SCRIPT_DIR/.mwi-optimize-last-run"
# 至少 N 小时跑一次 optimize (默认 4 小时)
OPTIMIZE_MIN_INTERVAL=${OPTIMIZE_MIN_INTERVAL:-$((4 * 3600))}

should_optimize() {
    [[ ! -f "$OPTIMIZE_LAST_RUN_FILE" ]] && return 0
    local last_run now elapsed
    last_run=$(cat "$OPTIMIZE_LAST_RUN_FILE")
    now=$(date +%s)
    elapsed=$((now - last_run))
    if (( elapsed >= OPTIMIZE_MIN_INTERVAL )); then
        return 0
    fi
    log "距离上次 optimize 仅 $((elapsed / 3600))h, 跳过 (间隔 $((OPTIMIZE_MIN_INTERVAL / 3600))h)"
    return 1
}

# Slot 1 利润优化: 查最赚钱的物品并切换 (节流, 反检测, fail-safe)
# 使用 v2 calc: 从 WebSocket hook 抓的 init_character_data 算完整 buff
optimize_slot1_production() {
    log "=== Slot 1 利润优化 ==="

    # 节流: 默认 3 天才跑一次, 避免频繁切换被检测
    if ! should_optimize; then
        return 0
    fi

    # 先关掉所有弹窗 (Welcome Back / Quest Modal 等会挡路)
    log "关闭挡路弹窗..."
    dismiss_modals

    # 从 window.__mwiCharData 抓角色数据 (hook 在 open_mwi 里注入)
    # play_slot 进入前已清空旧数据, 所以这里拿到的一定是本次进入后的新鲜数据
    local char_file
    char_file=$(mktemp /tmp/mwi-char-XXXXXX.json)
    trap "rm -f '$char_file'" RETURN

    local data_ok="" data_attempts=5
    while (( data_attempts-- > 0 )); do
        if python3 "$CDP_HELPER" get_char_data 60 > "$char_file" 2>/dev/null; then
            if [[ -s "$char_file" ]] && ! grep -q '^null' "$char_file"; then
                data_ok=1
                break
            fi
        fi
        log "等待角色数据 (WebSocket hook 可能还没捕获)..."
        sleep 3
    done
    if [[ -z "$data_ok" ]]; then
        log "无法读取角色数据 (重试 5 次失败), 跳过优化"
        return 1
    fi
    local char_size
    char_size=$(wc -c < "$char_file")
    log "抓到角色数据: ${char_size} 字节"

    # 运行 v2 利润计算 (用真实角色 preset)
    local calc_result
    calc_result=$(python3 "$PROFIT_CALC" "$char_file" 2>/dev/null)
    if [[ -z "$calc_result" ]] || echo "$calc_result" | grep -q '"error"'; then
        log "利润计算失败, 跳过优化"
        return 1
    fi

    # 解析 top10 列表
    local top10_count
    top10_count=$(echo "$calc_result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['top10']))" 2>/dev/null || echo "0")
    if [[ "$top10_count" == "0" ]]; then
        log "没有可盈利的物品"
        return 1
    fi

    # 当前动作
    local current_name
    current_name=$(get_current_action)
    log "当前动作: $current_name"

    # 遍历 top10, 第一个成功切换的就停
    local idx=0
    while (( idx < top10_count )); do
        local item_name item_skill item_category item_profit
        read -r item_name < <(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['top10'][$idx]['name'])" 2>/dev/null)
        read -r item_skill < <(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['top10'][$idx]['skill_label'])" 2>/dev/null)
        read -r item_category < <(echo "$calc_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['top10'][$idx]['category'])" 2>/dev/null)
        item_profit=$(echo "$calc_result" | python3 -c "import sys,json; d=json.load(sys.stdin)['top10'][$idx]; print(f\"{d['profit_per_day']/1e6:.1f}M/day\")" 2>/dev/null)

        log "Top $((idx+1)): $item_name ($item_skill/$item_category) - $item_profit"

        # 如果已经在做这个, 不需要切换
        if [[ "$current_name" == "$item_name" ]]; then
            log "当前已在生产 $item_name, 无需切换"
            replenish_if_needed "$calc_result" "$char_file" || true
            auto_sell_output "$calc_result" || true
            date +%s > "$OPTIMIZE_LAST_RUN_FILE"
            return 0
        fi

        # 只有 top1 才值得切换 (如果当前做的也在 top10 里, 差距不大就不切)
        if (( idx == 0 )); then
            log "需要切换: $current_name → $item_name"
        fi

        if switch_production "$item_skill" "$item_category" "$item_name"; then
            log "✓ 已切换到 Top $((idx+1)): $item_name"
            replenish_if_needed "$calc_result" "$char_file" || true
            auto_sell_output "$calc_result" || true
            date +%s > "$OPTIMIZE_LAST_RUN_FILE"
            return 0
        fi

        log "Top $((idx+1)) 切换失败, 尝试下一个..."
        idx=$((idx + 1))
    done

    log "top10 全部切换失败"
    return 1
}

# 进入一个角色再退回角色选择
play_slot() {
    local slot="$1"
    log "进入 Slot $slot..."
    # 清空旧的角色数据, 防止读到上一次的缓存
    "$AB" --cdp "$CDP_PORT" eval "window.__mwiCharData=null;window.__mwiCharDataTs=0" 2>/dev/null || true
    "$AB" --cdp "$CDP_PORT" find text "Slot $slot" click 2>/dev/null || {
        log "未找到 Slot $slot, 跳过"
        return 1
    }
    sleep 8

    # 每次登录后先到 My Listings 收菜
    dismiss_modals
    collect_all_listings || true
    sleep 2

    # Slot 1: 执行利润优化
    if [[ "$slot" == "1" ]]; then
        optimize_slot1_production || true
        sleep 2
    fi

    # 回到角色选择: 刷新页面 → ENTER GAME → 回到选角界面
    log "Slot $slot 保活完成, 返回角色选择..."
    "$AB" --cdp "$CDP_PORT" open "$MWI_URL"
    "$AB" --cdp "$CDP_PORT" wait --load networkidle
    sleep 2

    local state
    state=$(check_state)
    if [[ "$state" == "welcome_back" ]]; then
        enter_game
        sleep 3
    fi
}

# 依次进入所有 4 个 Slot
play_all_slots() {
    for slot in 1 2 3 4; do
        local state
        state=$(check_state)
        if [[ "$state" != "character_select" ]]; then
            log "当前不在角色选择界面 (状态: $state), 停止轮换"
            return 1
        fi
        play_slot "$slot"
        # 每个角色之间随机等几秒, 像人一样
        local gap=$(( RANDOM % 5 + 2 ))
        sleep "$gap"
    done
    log "全部 4 个角色保活完成"
}

# 主逻辑
main() {
    if [[ "${1:-}" == "--setup" ]]; then
        setup_mode
        exit 0
    fi

    # 检查是否该运行了
    if ! should_run; then
        exit 0
    fi

    # 随机延迟 0~30 分钟, 避免每次都在整点启动
    local delay=$(( RANDOM % MAX_RANDOM_DELAY + 1 ))
    local delay_min=$(( delay / 60 ))
    local delay_sec=$(( delay % 60 ))
    log "=== MWI Keep-Alive 开始 (延迟 ${delay_min}m${delay_sec}s) ==="
    sleep "$delay"

    # 确保 Chrome 在运行
    start_chrome --headless=new || exit 1

    open_mwi

    local state
    state=$(check_state)
    log "当前状态: $state"

    case "$state" in
        game)
            log "Session 有效, 已在游戏中"
            sleep 5
            log "保活完成"
            ;;
        welcome_back)
            enter_game
            sleep 3
            state=$(check_state)
            log "进入后状态: $state"
            if [[ "$state" == "character_select" ]]; then
                play_all_slots
            fi
            log "保活完成"
            ;;
        character_select)
            play_all_slots
            log "保活完成"
            ;;
        login)
            log "Session 已过期, 需要重新登录"
            log "请手动运行: ./mwi-keep-alive.sh --setup"
            exit 1
            ;;
        unknown)
            log "无法识别页面状态, 截图保存..."
            "$AB" --cdp "$CDP_PORT" screenshot "$SCRIPT_DIR/mwi-unknown-state.png" 2>/dev/null || true
            log "截图已保存到 mwi-unknown-state.png"
            exit 1
            ;;
    esac

    # 记录本次运行时间
    mark_run

    # 不关闭 Chrome — session cookie 是非持久化的, 杀 Chrome 就丢了
    log "=== MWI Keep-Alive 结束 ==="
}

main "$@"
