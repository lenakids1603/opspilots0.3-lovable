# 商品模块设计方案（第一阶段）

明确不做的事：**不**开发"全量同步聚水潭 60 万条商品"按钮；**不**把平台商品记录展示在商品资料主列表；**不**批量下载图片。

---

## 一、数据库结构

### 1. `ops_products_master` — 商品主档（内部 SKU 维度，一条 SKU 一行）
字段：`id, style_code, sku_code, product_name, color, size, supplier_id, supplier_name, cost_price, season, category, main_image_url, status, first_seen_at, last_seen_at, source(订单/采购/入库/出库/销退/手工/聚水潭), created_at, updated_at`

去重唯一键（按优先级）：
- `sku_code` 非空时唯一
- 否则 `jst_sku_id`（写在 mapping 表，主档通过 mapping 反查）
- 否则 `(style_code, color, size)` 兜底唯一

> 沿用项目现有 `ops_skus` / `ops_products` 表的可能性需确认；若已包含等价字段，复用并补字段，不重复建表。

### 2. `ops_product_online_mappings` — 线上商品映射（平台/店铺维度，可多条）
字段：`id, product_master_id(FK), sku_code, jst_item_id, jst_sku_id, platform, shop_id, shop_name, online_item_code, online_sku_code, online_product_name, online_sku_name, online_status, modified_at, raw_data jsonb, created_at, updated_at`
唯一键：`(shop_id, online_sku_code)` 或 `(jst_sku_id, shop_id)`。

### 3. `ops_product_sync_logs` — 商品同步日志
字段：`sync_type, status, started_at, finished_at, total_count, success_count, failed_count, error_message, cursor, date_range, created_at`
（或直接复用现有 `jst_sync_logs`，新增 `sync_type` 取值约定。）

### 4. `ops_product_mapping_exceptions` — 映射异常
字段：`shop_id, shop_name, platform, online_item_code, online_sku_code, order_no, reason, status(pending/resolved/ignored), raw_data jsonb, created_at`

RLS：沿用 `is_ops_internal` 读、`admin` 写；GRANT 给 `authenticated` + `service_role`。

---

## 二、Edge Functions

- `ops-product-master-derive`：从 `jst_sales_orders/_items`、采购单、入库、出库、销退表反查 SKU/款号/颜色/尺码/图片/供应商，upsert 主档；更新 `first_seen_at/last_seen_at`；遇到无主档的线上 SKU 写 `mapping_exceptions`。
- `jst-sync-products-incremental`：仅支持小范围参数 `{days, sku_codes[], style_codes[], shop_id?}`，分页 + 断点续传 + 失败重试，写 mapping 表 + 主档 upsert，**只存图片 URL**。
- 暂不做 full-sync 入口。

---

## 三、前端页面

### 商品资料页（`/products`）
- 数据源：`ops_products_master`（内部 SKU 维度）
- 列：图片 / 款号 / SKU / 名称 / 颜色 / 尺码 / 供应商 / 成本 / 关联线上商品数 / 近 7 天销量 / 库存 / 状态 / 最后出现时间
- 顶部按钮：
  - "从业务数据沉淀主档"（调 derive 函数）
  - "同步近 7 天有变更商品"
  - "同步近 30 天有订单商品"
  - "按 SKU 同步" / "按款号同步"（输入框）
  - "补全缺失资料"
- **不**放"全量同步"按钮。

### 商品详情页（`/products/:id`）
Tab 视图：基础资料 / 线上映射（mapping 表）/ 订单 / 出库 / 采购 / 入库 / 销退退款 / 库存 / 成本。

### 映射异常页（`/products/exceptions`）
列表 + 手动绑定到主档。

---

## 四、本次执行顺序

1. **先确认**：现有 `ops_products` / `ops_skus` / `ops_sku_aliases` 表的字段与本方案的差距，决定"复用扩字段"还是"新建 master 表"。
2. 提交 migration（4 表 + GRANT + RLS）。
3. 写 `ops-product-master-derive` edge function（从业务数据沉淀）。
4. 改商品资料页：只展示主档 + 顶部按钮组（不含全量同步）。
5. 商品详情页骨架（先放基础资料 + 线上映射两个 tab，其余 tab 占位）。
6. 映射异常页骨架。
7. 增量同步 edge function 留到第二批，本轮不实现。

---

## 五、待确认

执行前请确认两点：
1. 是**新建** `ops_products_master` 表，还是**扩展现有** `ops_products` / `ops_skus`？（看到项目里已有这两张表）
2. 同步日志是**新建** `ops_product_sync_logs`，还是**复用** `jst_sync_logs`？

确认后即按上面顺序开工。
