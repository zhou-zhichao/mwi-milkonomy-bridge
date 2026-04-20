# 历史价格记录与查询

## 背景与动机

MWI 市场上每个商品的价格都有周期性波动，玩家需要知道"现在是不是便宜"来决定买入时机。当前项目只有 `mwi-profit-calc-v2.py` 使用实时价格计算利润，没有任何历史数据留存。

MWI 官方公开了 `https://www.milkywayidle.com/game_data/marketplace.json`，包含全部物品（测得 872 个）所有强化等级的 `ask / bid / last_price / volume`，顶层带一个 `timestamp` 字段，实测刷新间隔约 4 小时。

本项目添加一个本地历史价格采集 + 命令行查询工具，帮助判断买入时机。

## 范围

做：

- 定时采集 `marketplace.json` 全量快照到本地 SQLite
- 命令行查询单个物品的历史走势和统计
- 命令行扫描"当前价处于历史低位"的物品

不做（YAGNI）：

- HTML / 图形化展示
- 推送通知 / 自动提醒
- 装备强化等级专门的分析（数据全存，未来可加）
- 通过游戏 WebSocket 捕获高频价格变动（官方 API 已足够）

## 设计

### 采集器 `mwi-price-logger.py`

流程：

1. `GET https://www.milkywayidle.com/game_data/marketplace.json`（带 `User-Agent`，30 秒超时）。
2. 读取顶层 `timestamp`。
3. 查询 SQLite 中最大的 `timestamp`；若相等直接退出（状态码 0，日志打印 `skipped: timestamp unchanged`）。
4. 否则遍历 `marketData`，每个 `item_hrid` 下的每个等级 key（`"0"`, `"1"`, ...）生成一行写入 `price_history`。单次调用用一个事务。
5. 打印 `inserted N rows at timestamp=T (snapshot YYYY-MM-DD HH:MM:SS)`。

调用方式：

```bash
python3 /home/sam/mwi-milkonomy-bridge/mwi-price-logger.py
```

输出重定向到 `logs/mwi-price-logger.log`（由 cron 条目负责）。

### 调度

cron 条目（安装到用户 crontab）：

```cron
*/30 * * * * /usr/bin/python3 /home/sam/mwi-milkonomy-bridge/mwi-price-logger.py >> /home/sam/mwi-milkonomy-bridge/logs/mwi-price-logger.log 2>&1
```

每 30 分钟跑一次；官方 4 小时刷新一次的话每次有 ~7/8 的调用是 skip 退出，开销可忽略。

### 存储 `data/prices.db`

路径：`/home/sam/mwi-milkonomy-bridge/data/prices.db`

Schema：

```sql
CREATE TABLE price_history (
    timestamp   INTEGER NOT NULL,
    item_hrid   TEXT NOT NULL,
    level       INTEGER NOT NULL,
    ask         INTEGER,
    bid         INTEGER,
    last_price  INTEGER,
    volume      INTEGER,
    PRIMARY KEY (timestamp, item_hrid, level)
);
CREATE INDEX idx_item_time ON price_history(item_hrid, level, timestamp DESC);
```

约定：

- API 里 `ask=-1` 或 `bid=-1` 表示"无人挂单"，直接存 `-1`，查询时由 CLI 过滤/展示。
- `PRIMARY KEY` 天然保证同一时间戳不重复写入；采集器用 `INSERT OR IGNORE`。

容量：872 物品 × 6 快照/天 ≈ 5200 行/天 ≈ 1.9M 行/年，SQLite 无压力。

### 查询工具 `mwi-price-query.py`

两种模式：

**(1) 单物品查询**

```
$ mwi-price-query.py cheese [--days 30] [--level 0]
```

- 物品名支持模糊匹配：输入 `cheese` 查到 `/items/cheese`；若匹配多个则列出候选让用户精确选择。
- 模糊匹配数据源：从 `data/prices.db` 里 `DISTINCT item_hrid` 提取；不依赖外部 game data。
- 输出：
  - 头部：`<item_hrid> (lv N) — 最近 D 天`
  - 当前值：`ask / bid`
  - 统计：`D 天均值 / 最低（带日期）/ 最高（带日期）/ 当前 ask 的分位`
  - 数据点表格：时间倒序，`时间 ask bid vol`，最多 50 行

**(2) 低位扫描**

```
$ mwi-price-query.py --cheap [--days 30] [--percentile 20]
```

- 遍历 `price_history` 中 level=0 的所有物品，计算各自当前 ask 在过去 D 天内的分位。
- 打印所有分位 ≤ P 的物品，按分位升序。列：`item_hrid / current ask / Dd min / Dd avg / percentile`。
- 默认 P=20。

通用：

- 物品名列只显示 hrid（保持纯 CLI 无外部依赖）。
- `--days` 默认 30；不够 D 天数据时用现有最早数据。
- 当前值定义：数据库里该物品最新一条快照的 ask / bid。
- 分位计算：取过去 D 天窗口内该物品所有 ask > 0 的记录（包含当前这条），按升序排，当前 ask 的排名 `r`（从 1 起），总数 `n`，分位 = `(r - 1) / (n - 1) * 100`（n=1 时分位视为 50）。分位越小 = 当前越便宜。

### 目录结构变动

```
mwi-milkonomy-bridge/
├── mwi-price-logger.py        # 新增
├── mwi-price-query.py         # 新增
├── data/                      # 新增（gitignore）
│   └── prices.db
├── logs/
│   └── mwi-price-logger.log   # 新增
└── docs/superpowers/specs/
    └── 2026-04-21-price-history-design.md   # 本文件
```

`.gitignore` 增加 `data/`。

## 错误处理

- `marketplace.json` 请求失败：打印错误信息到 stderr，退出码 1；cron 日志里会出现，但不影响下一次尝试。
- SQLite 写入失败：事务回滚、退出码 1。
- 查询时数据库不存在或为空：友好提示"先运行采集器积累数据"。

## 测试计划

手动验证：

1. 运行一次采集器，确认写入行数合理（~5000 行），DB 文件生成。
2. 再运行一次（timestamp 未变），确认 skip 退出。
3. 把系统时间戳改一下或手动改 DB 里的 timestamp 模拟新快照，再跑确认能写入新行。
4. 查询 `cheese`，确认输出格式正确、数据来自 DB。
5. 模糊匹配歧义：查询 `bar` 应列出多个候选。
6. `--cheap` 至少要有 2 次快照才能有分位意义；先手工构造或等实际运行一天。

## 未来扩展（不在本次范围内）

- HTML 报告 / matplotlib 图
- 指定物品的价格报警（当前价低于阈值就写个标记文件）
- 按 volume 过滤流动性太差的物品
- 与 `mwi-profit-calc` 集成，用历史均值而非当前 ask 计算利润以避免被临时深度欺骗
