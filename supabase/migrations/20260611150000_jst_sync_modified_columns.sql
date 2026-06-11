-- =============================================================================
-- 同步 upsert 增量条件优化 — 第 1 步:明细表补 modified 列(2026-06-11)
--
-- ⚠️ 生产部署顺序(零中断):
--   1. 先应用本迁移(旧版函数不写这些列,无影响);
--   2. 再部署新版 edge functions(jst-sync-sales-orders / outbound-orders /
--      refund-orders / aftersale-received,开始写入 modified_at_jst 并兼容
--      RETURNING 为空);
--   3. 最后应用 20260611150100(挂跳过触发器)。
--   若先挂触发器而函数仍是旧版,旧代码 upsert 后的 .single() 会因跳过行
--   RETURNING 为空而报错。
--
-- 明细表此前没有 JST modified 列,补列后由同步函数写入父单的 modified,
-- 供条件更新触发器比较。存量行该列为 NULL → 触发器按 NULL 边界放行,
-- 随同步自然回填。本迁移可重复执行。
-- =============================================================================

alter table public.jst_sales_order_items            add column if not exists modified_at_jst timestamptz;
alter table public.jst_refund_order_items           add column if not exists modified_at_jst timestamptz;
alter table public.jst_aftersale_received_items     add column if not exists modified_at_jst timestamptz;
alter table public.warehouse_shipping_package_items add column if not exists modified_at_jst timestamptz;
