# MWI → Milkonomy Bridge

自动从 [Milky Way Idle](https://www.milkywayidle.com/) 游戏中读取角色数据，生成 [Milkonomy](https://milkonomy.pages.dev/) 可直接导入的 JSON 预设。

## 功能

- 自动捕获角色技能等级
- 自动读取装备信息（工具、身体、腿部、护符及通用装备）
- 自动读取房屋等级
- 自动读取当前使用的茶/饮品
- 自动读取社区 Buff 等级
- 一键导出为 Milkonomy 兼容的 JSON 格式

## 安装

### 前置要求

1. 安装 [Tampermonkey](https://www.tampermonkey.net/) 浏览器扩展
2. **确保 Chrome 开发者模式已开启**：`chrome://extensions/` → 右上角 Developer mode 开关

### 安装脚本

- **Greasy Fork**: [安装链接](https://greasyfork.org/scripts/TODO)
- **手动安装**: 复制 `mwi-milkonomy-bridge.user.js` 的内容到 Tampermonkey 新建脚本中

## 使用方法

1. 打开 Milky Way Idle 游戏并登录
2. 登录后，页面右下角会出现两个按钮：
   - **📋 导出到 Milkonomy** — 将角色数据复制到剪贴板
   - **ℹ️ 查看数据** — 查看捕获到的角色数据摘要
3. 打开 [Milkonomy](https://milkonomy.pages.dev/)
4. 点击当前预设按钮 → 点击「导入」→ 粘贴 → 确定

## 原理

通过 Hook 游戏的 WebSocket 消息（`MessageEvent.prototype.data`），在登录时捕获 `init_character_data` 消息，从中提取角色数据并转换为 Milkonomy 的预设格式。

**只读不写** — 不向游戏服务器发送任何消息。

## 支持的游戏域名

- `www.milkywayidle.com`
- `test.milkywayidle.com`
- `www.milkywayidlecn.com`
- `test.milkywayidlecn.com`

## 历史价格记录

采集 MWI 公开的 `marketplace.json` 到本地 SQLite，用于查找买入时机。

### 安装 cron

```bash
./install-price-logger-cron.sh
```

这会在当前用户的 crontab 里加一条每 30 分钟运行一次的任务（官方数据 4 小时刷新一次，脚本会按 timestamp 自动去重）。

### 查询用法

```bash
# 单物品走势
python3 mwi-price-query.py cheese --days 30

# 扫描当前处于历史低位的物品（默认阈值 20 分位）
python3 mwi-price-query.py --cheap --days 30 --percentile 20
```

数据库位于 `data/prices.db`，不纳入版本控制。

## License

MIT
