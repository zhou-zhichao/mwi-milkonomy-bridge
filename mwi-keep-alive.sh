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
MAX_RANDOM_DELAY=${MAX_RANDOM_DELAY:-$((30 * 60))} # 启动前随机等待 0~30 分钟, 可通过环境变量覆盖

# 自动卖出配置
SELL_RESERVE=${SELL_RESERVE:-50000000}   # 保留 50M 货值, 超出部分卖出

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
        snapshot=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null)
        # 找 button "Close" / "X" / 类似
        close_refs=$(echo "$snapshot" | grep -E 'button "(Close|✕|×)"' | grep -oP 'ref=\Ke\d+' | head -3)
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

    # 2. 搜索物品
    local filter_ref
    filter_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'searchbox "Item Filter"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$filter_ref" ]]; then
        log "  ✗ 找不到搜索框"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" fill "@$filter_ref" "$item_name" 2>/dev/null || true
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

    # 2. 搜索物品
    local filter_ref
    filter_ref=$("$AB" --cdp "$CDP_PORT" snapshot -i 2>/dev/null | grep 'searchbox "Item Filter"' | head -1 | grep -oP 'ref=\Ke\d+' || true)
    if [[ -z "$filter_ref" ]]; then
        log "  ✗ 找不到搜索框"
        return 1
    fi
    "$AB" --cdp "$CDP_PORT" fill "@$filter_ref" "$item_name" 2>/dev/null || true
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
        read -r mat_name mat_qty < <(echo "$missing_json" | python3 -c "
import sys, json, math
d = json.load(sys.stdin)
dur = max(1, d.get('duration_s', 10))
mat = d['missing'][$i]
# 9 小时的生产次数
runs_9h = 9 * 3600 / dur
# 需要购买: 每次消耗 × 次数 - 已有量, 向上取整
qty = max(1, math.ceil(mat['need'] * runs_9h - mat['have']))
print(mat['name'], qty)
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

# 检查材料是否够继续生产, 不够就从市场补货
# 用法: replenish_if_needed "$calc_result" "$char_file"
# 逻辑: 算每种输入材料还能生产几小时, 低于 6 小时就买到 9 小时
replenish_if_needed() {
    local calc_result="$1"
    local char_file="$2"
    log "=== 材料补货检查 ==="

    local buy_list
    buy_list=$(echo "$calc_result" | python3 -c "
import json, sys, math

calc = json.load(sys.stdin)
with open('$char_file') as f:
    char = json.load(f)

inventory = {}
for item in char.get('characterItems', []):
    if item.get('itemLocationHrid') == '/item_locations/inventory':
        inventory[item['itemHrid']] = item.get('count', 0)

best = calc['best']
aph = best['actions_per_hour']
threshold_h = 6
target_h = 9
buy = []
for inp in best.get('input_items', []):
    have = inventory.get(inp['hrid'], 0)
    consume_ph = inp['count'] * aph
    hours_left = have / consume_ph if consume_ph > 0 else 999
    if hours_left < threshold_h:
        need = max(1, math.ceil(consume_ph * target_h - have))
        buy.append({'name': inp['name'], 'qty': need, 'have': have, 'hours': round(hours_left, 1)})

print(json.dumps(buy))
" 2>/dev/null || echo "[]")

    if [[ "$buy_list" == "[]" ]] || [[ -z "$buy_list" ]]; then
        log "材料充足, 无需补货"
        return 0
    fi

    local count
    count=$(echo "$buy_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    log "有 $count 种材料库存不足 6 小时, 开始补货到 9 小时"

    local i=0
    while (( i < count )); do
        local mat_name mat_qty mat_hours
        read -r mat_name mat_qty mat_hours < <(echo "$buy_list" | python3 -c "
import sys,json
d = json.load(sys.stdin)[$i]
print(d['name'], d['qty'], d['hours'])
" 2>/dev/null)
        log "  → $mat_name: 剩余 ${mat_hours}h, 需购买 $mat_qty 个"
        buy_from_marketplace "$mat_name" "$mat_qty" || {
            log "  ✗ 购买 $mat_name 失败"
        }
        i=$((i + 1))
    done
    return 0
}

# 自动卖出: 只卖 top1 最赚钱的产出物品, 保留 SELL_RESERVE 货值
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
    local reserve_count sellable
    reserve_count=$(python3 -c "print(max(0, int($SELL_RESERVE / $bid_price)))" 2>/dev/null || echo "0")
    sellable=$(( inventory_count - reserve_count ))

    if (( sellable <= 0 )); then
        log "库存 $inventory_count ≤ 保留量 $reserve_count (保留 ${SELL_RESERVE} 货值), 不卖"
        return 0
    fi

    log "保留 $reserve_count 个 (≈${SELL_RESERVE} 货值), 可卖: $sellable 个"
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
