## 目标

在现有 `/data-center/jst-integration` 页面的「售后API」模块内，接入聚水潭售后同步功能。仅做同步层与最小化 UI 改造，不做分析页。

---

## 一、数据库 migration（一次性提交）

新增 4 张表 + GRANT + RLS（沿用现有 `is_ops_internal` / `has_ops_role admin` 规则，与 jst_* 系列一致）。

1. **`jst_refund_orders`** — 退货退款单主表（`as_id` 唯一）
2. **`jst_refund_order_items`** — 退货退款单明细（`refund_order_id` cascade；幂等键：`as_id + COALESCE(asi_id, sku_id||'|'||outer_oi_id)`，用部分唯一索引实现）
3. **`jst_aftersale_received_orders`** — 销售退仓主表（`as_id` 唯一）
4. **`jst_aftersale_received_items`** — 销售退仓明细（cascade）

字段按用户给出的列表落地，全部带 `raw_data jsonb`、`synced_at/created_at/updated_at`。

RLS：`is_ops_internal` 读，`admin` 全权限；GRANT 给 `authenticated` + `service_role`，不给 `anon`。

复用现有 `jst_sync_logs` / `jst_sync_jobs` 表，不新建日志体系。`sync_type` 新增两个取值：`refund_orders`、`aftersale_received`（只是 text 取值约定，无 schema 变更）。

---

## 二、Edge Functions

新增两个独立函数（结构对齐已有 `jst-sync-purchase-orders`，复用 token / 代理 / 签名逻辑）：

- **`supabase/functions/jst-sync-refund-orders/index.ts`**
  - 调聚水潭 `/open/refund/list/query`（按 `modified` 字段时间区间）
  - 主表 upsert by `as_id`，明细 upsert by 幂等键
  - 支持 `days | start_time | end_time | manual` 入参，默认 1 天
  - page_size 取接口最大，循环到 `has_next=false`
  - 写 `jst_sync_logs`，累计 `total_api_count / orders / items / failed`

- **`supabase/functions/jst-sync-aftersale-received/index.ts`**
  - 调聚水潭 `/open/aftersale/received/query`（销售退仓 / 实际收货）
  - 同样的分页/幂等/日志结构

两个函数都用现有 JST secrets（已配置：`JST_APP_KEY` / `JST_APP_SECRET` / `JST_ACCESS_TOKEN` / `JST_PROXY_*`）。

错误（签名、token、IP 白名单、权限）全部写入 `jst_sync_logs.error_message`，前端 toast 提示。

---

## 三、前端改造（仅改 `JstDataIntegrationPage.tsx` 的「售后API」tab）

替换原 `售后API（暂未接入）` 占位为两张卡片：

- **卡片 A：退货退款单** — 状态 badge / 已同步记录数（`count(jst_refund_orders)`）/ 最近同步时间 / 最近状态 / 4 个按钮（1天/7天/30天/自定义范围）
- **卡片 B：销售退仓** — 同上，数据源 `jst_aftersale_received_orders`

按钮通过 `supabase.functions.invoke()` 调用对应 edge function；运行中显示 spinner，结束后刷新统计与日志。

**顶部「销售/退款」统计卡片**：改为读取 `jst_refund_orders` 记录数 + 取 refund/aftersale 两类最新 `ended_at` 作为「最近同步时间」，状态来自最近一次日志。

**自动同步计划区域**：新增两行展示（仅 UI 展示，不实际安装 cron）：
- 退货退款单 — 每天 03:10，最近 2 天
- 销售退仓 — 每天 03:30，最近 2 天

如果现有自动同步计划列表是从某张配置表读取的，则向该表 insert 两条记录；若是硬编码列表，则在数组里追加两项。具体接入位置在实现阶段确认。

不引入新页面、不动其他 tab。

---

## 四、不做

- 不做退款原因/SKU/供应商分析
- 不做补偿同步 cron（先只做手动 + UI 展示的每日计划）
- 不改采购单/入库单/库存模块
- 不删除任何现有功能

---

## 五、执行顺序

1. 提交 migration（创建 4 表 + GRANT + RLS）→ 等用户批准
2. 写两个 edge function（自动部署）
3. 改 `JstDataIntegrationPage.tsx`：售后 tab + 顶部统计卡 + 自动计划展示
4. 手动点同步按钮验证 → 检查 `jst_sync_logs` 与数据表行数

确认后我就按这个顺序开始。
