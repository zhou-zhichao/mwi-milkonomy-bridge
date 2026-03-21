// ==UserScript==
// @name         MWI → Milkonomy Bridge
// @namespace    https://github.com/user/mwi-milkonomy-bridge
// @version      2.0.0
// @description  自动从 MWI 捕获角色数据和实时市场价格，同步到 Milkonomy
// @author       You
// @match        *://www.milkywayidle.com/*
// @match        *://test.milkywayidle.com/*
// @match        *://www.milkywayidlecn.com/*
// @match        *://test.milkywayidlecn.com/*
// @match        *://milkywayidle.com/*
// @grant        none
// ==/UserScript==

(function () {
  "use strict";

  var VERSION = "2.0.0";
  var MILKONOMY_RECEIVER = "https://milkonomy.pages.dev/market-receiver.html";

  console.log("[MWI-Milkonomy] ====== v" + VERSION + " 脚本已加载 ======");

  var MILKONOMY_ACTIONS = [
    "milking", "foraging", "woodcutting",
    "cheesesmithing", "crafting", "tailoring",
    "cooking", "brewing", "alchemy", "enhancing"
  ];

  var SKILL_TO_ACTION = {};
  for (var i = 0; i < MILKONOMY_ACTIONS.length; i++) {
    SKILL_TO_ACTION["/skills/" + MILKONOMY_ACTIONS[i]] = MILKONOMY_ACTIONS[i];
  }

  var LOCATION_TO_EQUIPMENT_TYPE = {
    "/item_locations/head": "head", "/item_locations/body": "body",
    "/item_locations/legs": "legs", "/item_locations/feet": "feet",
    "/item_locations/hands": "hands", "/item_locations/ring": "ring",
    "/item_locations/neck": "neck", "/item_locations/earrings": "earrings",
    "/item_locations/back": "back", "/item_locations/off_hand": "off_hand",
    "/item_locations/pouch": "pouch", "/item_locations/charm": "charm"
  };

  var TOOL_LOCATION_TO_ACTION = {};
  for (var j = 0; j < MILKONOMY_ACTIONS.length; j++) {
    TOOL_LOCATION_TO_ACTION["/item_locations/" + MILKONOMY_ACTIONS[j] + "_tool"] = MILKONOMY_ACTIONS[j];
  }

  var HOUSE_ROOM_TO_ACTION = {};
  for (var k = 0; k < MILKONOMY_ACTIONS.length; k++) {
    HOUSE_ROOM_TO_ACTION["/house_rooms/" + MILKONOMY_ACTIONS[k] + "_room"] = MILKONOMY_ACTIONS[k];
  }

  var COMMUNITY_BUFF_MAP = {
    "/community_buff_types/experience": "experience",
    "/community_buff_types/gathering_quantity": "gathering_quantity",
    "/community_buff_types/production_efficiency": "production_efficiency",
    "/community_buff_types/enhancing_speed": "enhancing_speed"
  };

  var characterData = null;
  var marketItemCount = 0;

  // === Milkonomy iframe 同步 ===
  var milkonomyFrame = null;
  var frameReady = false;
  var pendingUpdates = [];

  function initMilkonomyFrame() {
    milkonomyFrame = document.createElement("iframe");
    milkonomyFrame.src = MILKONOMY_RECEIVER;
    milkonomyFrame.style.cssText = "display:none;";
    document.body.appendChild(milkonomyFrame);

    milkonomyFrame.onload = function() {
      frameReady = true;
      console.log("[MWI-Milkonomy] ✓ Milkonomy 同步通道已建立");
      // 发送积压的更新
      for (var i = 0; i < pendingUpdates.length; i++) {
        sendToMilkonomy(pendingUpdates[i]);
      }
      pendingUpdates = [];
    };

    window.addEventListener("message", function(e) {
      if (e.data && e.data.type === "mwi-market-ack") {
        console.log("[MWI-Milkonomy] ✓ 已同步 " + e.data.count + " 个物品价格到 Milkonomy");
      }
    });
  }

  function sendToMilkonomy(items) {
    if (!frameReady || !milkonomyFrame) {
      pendingUpdates.push(items);
      return;
    }
    milkonomyFrame.contentWindow.postMessage({
      type: "mwi-market-update",
      timestamp: Math.floor(Date.now() / 1000),
      items: items
    }, "https://milkonomy.pages.dev");
  }

  // === 市场数据处理 ===
  function processMarketData(books) {
    if (!books || !books.itemHrid || !books.orderBooks) return;
    var hrid = books.itemHrid;
    var orderBooks = books.orderBooks;
    var itemData = {};

    for (var i = 0; i < orderBooks.length; i++) {
      var asks = orderBooks[i].asks || [];
      var bids = orderBooks[i].bids || [];
      if (asks.length === 0 && bids.length === 0) continue;
      var bestAsk = asks.length > 0 ? asks[0].price : -1;
      var bestBid = bids.length > 0 ? bids[0].price : -1;
      itemData[String(i)] = { ask: bestAsk, bid: bestBid };
    }

    if (Object.keys(itemData).length > 0) {
      marketItemCount++;
      updateMarketStatus();
      // 实时推送到 Milkonomy
      var update = {};
      update[hrid] = itemData;
      sendToMilkonomy(update);
    }
  }

  function updateMarketStatus() {
    var el = document.getElementById("mwi-milkonomy-market-count");
    if (el) el.textContent = marketItemCount;
  }

  // === WebSocket Hook ===
  var dataProperty = Object.getOwnPropertyDescriptor(MessageEvent.prototype, "data");
  if (!dataProperty || !dataProperty.get) {
    console.error("[MWI-Milkonomy] 无法 hook MessageEvent.prototype.data");
  } else {
    var oriGet = dataProperty.get;

    dataProperty.get = function hookedGet() {
      var socket = this.currentTarget;
      if (!(socket instanceof WebSocket)) return oriGet.call(this);
      if (socket.url.indexOf("milkywayidle") <= -1) return oriGet.call(this);

      var message = oriGet.call(this);
      Object.defineProperty(this, "data", { value: message });

      try {
        if (typeof message === "string") {
          var msg = JSON.parse(message);
          if (msg.type === "market_item_order_books_updated") {
            processMarketData(msg.marketItemOrderBooks);
          }
          if (msg.type === "init_character_data") {
            characterData = msg;
            console.log("[MWI-Milkonomy] ✓ 捕获角色数据:", msg.character ? msg.character.name : "?");
            showPanel();
          }
        }
      } catch (e) {
        console.error("[MWI-Milkonomy] error:", e);
      }
      return message;
    };

    Object.defineProperty(MessageEvent.prototype, "data", dataProperty);
    console.log("[MWI-Milkonomy] ✓ WebSocket hook OK");
  }

  // === 角色数据转换 ===
  function buildPreset() {
    if (!characterData) return null;
    var d = characterData;
    var skills = d.characterSkills || [];
    var items = d.characterItems || [];
    var houseRoomMap = d.characterHouseRoomMap || {};
    var communityBuffs = d.communityBuffs || [];
    var drinkSlotsMap = d.actionTypeDrinkSlotsMap || {};

    var skillLevelMap = {};
    for (var i = 0; i < skills.length; i++) {
      var act = SKILL_TO_ACTION[skills[i].skillHrid];
      if (act) skillLevelMap[act] = skills[i].level;
    }

    var toolMap = {}, equippedMap = {};
    for (var j = 0; j < items.length; j++) {
      var loc = items[j].itemLocationHrid;
      if (!loc || loc === "/item_locations/inventory") continue;
      if (TOOL_LOCATION_TO_ACTION[loc]) {
        toolMap[TOOL_LOCATION_TO_ACTION[loc]] = { hrid: items[j].itemHrid, enhanceLevel: items[j].enhancementLevel || 0 };
      } else if (LOCATION_TO_EQUIPMENT_TYPE[loc]) {
        equippedMap[LOCATION_TO_EQUIPMENT_TYPE[loc]] = { hrid: items[j].itemHrid, enhanceLevel: items[j].enhancementLevel || 0 };
      }
    }

    var houseLevelMap = {};
    var hEntries = Object.entries(houseRoomMap);
    for (var h = 0; h < hEntries.length; h++) {
      var ha = HOUSE_ROOM_TO_ACTION[hEntries[h][0]];
      if (ha && hEntries[h][1]) houseLevelMap[ha] = hEntries[h][1].level || 0;
    }

    var teaMap = {};
    var dEntries = Object.entries(drinkSlotsMap);
    for (var dr = 0; dr < dEntries.length; dr++) {
      var dAct = dEntries[dr][0].replace("/action_types/", "");
      if (MILKONOMY_ACTIONS.indexOf(dAct) > -1 && Array.isArray(dEntries[dr][1])) {
        teaMap[dAct] = dEntries[dr][1].filter(function(s){return s&&s.itemHrid;}).map(function(s){return s.itemHrid;});
      }
    }

    var actionConfigMap = {};
    for (var m = 0; m < MILKONOMY_ACTIONS.length; m++) {
      var a = MILKONOMY_ACTIONS[m];
      var tool = toolMap[a] || {}, body = equippedMap.body || {}, legs = equippedMap.legs || {}, charm = equippedMap.charm || {};
      actionConfigMap[a] = {
        action: a, playerLevel: skillLevelMap[a] || 1,
        tool: { type: a + "_tool", hrid: tool.hrid, enhanceLevel: tool.hrid ? tool.enhanceLevel : undefined },
        body: { type: "body", hrid: body.hrid, enhanceLevel: body.hrid ? body.enhanceLevel : undefined },
        legs: { type: "legs", hrid: legs.hrid, enhanceLevel: legs.hrid ? legs.enhanceLevel : undefined },
        charm: { type: "charm", hrid: charm.hrid, enhanceLevel: charm.hrid ? charm.enhanceLevel : undefined },
        houseLevel: houseLevelMap[a] || 0, tea: teaMap[a] || []
      };
    }

    var specialTypes = ["off_hand","head","hands","feet","neck","earrings","ring","pouch"];
    var specialEquimentMap = {};
    for (var s = 0; s < specialTypes.length; s++) {
      var eq = equippedMap[specialTypes[s]] || {};
      specialEquimentMap[specialTypes[s]] = { type: specialTypes[s], hrid: eq.hrid || "", enhanceLevel: eq.hrid ? eq.enhanceLevel : undefined };
    }

    var communityBuffMap = {
      experience: {type:"experience",hrid:"/community_buff_types/experience",level:undefined},
      gathering_quantity: {type:"gathering_quantity",hrid:"/community_buff_types/gathering_quantity",level:undefined},
      production_efficiency: {type:"production_efficiency",hrid:"/community_buff_types/production_efficiency",level:undefined},
      enhancing_speed: {type:"enhancing_speed",hrid:"/community_buff_types/enhancing_speed",level:undefined}
    };
    for (var cb = 0; cb < communityBuffs.length; cb++) {
      var ct = COMMUNITY_BUFF_MAP[communityBuffs[cb].hrid];
      if (ct && communityBuffs[cb].level) {
        communityBuffMap[ct] = { type: ct, hrid: communityBuffs[cb].hrid, level: communityBuffs[cb].level };
      }
    }

    return {
      name: d.character ? d.character.name : "MWI",
      color: "#11BF11",
      actionConfigMap: actionConfigMap,
      specialEquimentMap: specialEquimentMap,
      communityBuffMap: communityBuffMap
    };
  }

  // === UI ===
  function showPanel() {
    if (document.getElementById("mwi-milkonomy-panel")) return;

    // 初始化 Milkonomy 同步通道
    initMilkonomyFrame();

    var panel = document.createElement("div");
    panel.id = "mwi-milkonomy-panel";
    panel.style.cssText = "position:fixed;bottom:16px;right:16px;z-index:99999;display:flex;gap:8px;align-items:center;";

    var btnCSS = "padding:8px 14px;color:white;border:none;border-radius:6px;font-size:13px;font-weight:bold;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,0.3);";

    var exportBtn = document.createElement("button");
    exportBtn.textContent = "\uD83D\uDCCB \u5BFC\u51FA\u89D2\u8272";
    exportBtn.style.cssText = btnCSS + "background:#16ab1b;";
    exportBtn.onclick = function() {
      var preset = buildPreset();
      if (!preset) { alert("\u65E0\u6570\u636E\uFF0C\u8BF7\u5237\u65B0\u9875\u9762"); return; }
      var json = JSON.stringify(preset);
      navigator.clipboard.writeText(json).then(function() {
        showToast("\u2713 \u5DF2\u590D\u5236\uFF01\u6253\u5F00 Milkonomy \u2192 \u9884\u8BBE \u2192 \u5BFC\u5165 \u2192 \u7C98\u8D34");
      }).catch(function() {
        window.prompt("\u590D\u5236\u4EE5\u4E0B JSON:", json);
      });
    };

    var statusEl = document.createElement("span");
    statusEl.style.cssText = "padding:6px 12px;background:rgba(0,0,0,0.6);color:#e6a23c;border-radius:6px;font-size:12px;font-weight:bold;";
    statusEl.innerHTML = "\uD83D\uDCCA \u5E02\u573A\u540C\u6B65: <span id='mwi-milkonomy-market-count'>0</span> \u4E2A\u7269\u54C1";

    panel.appendChild(exportBtn);
    panel.appendChild(statusEl);
    document.body.appendChild(panel);
    console.log("[MWI-Milkonomy] \u2713 \u9762\u677F\u5DF2\u663E\u793A");
  }

  function showToast(msg) {
    var old = document.getElementById("mwi-mk-toast");
    if (old) old.remove();
    var t = document.createElement("div");
    t.id = "mwi-mk-toast";
    t.textContent = msg;
    t.style.cssText = "position:fixed;top:20px;left:50%;transform:translateX(-50%);z-index:999999;padding:12px 24px;background:#16ab1b;color:white;border-radius:8px;font-size:14px;font-weight:bold;white-space:pre-line;text-align:center;box-shadow:0 4px 12px rgba(0,0,0,0.3);";
    document.body.appendChild(t);
    setTimeout(function(){t.remove();}, 3500);
  }

  console.log("[MWI-Milkonomy] ====== \u7B49\u5F85\u6E38\u620F\u6570\u636E... ======");
})();
