-- Manual backfill helper for the lightweight sales summary tables.
-- Run only after applying migration 20260607090000_jst_sales_summary_lightweight_sync.sql.
-- Start with 1 day, compare validation output, then expand to 7/30 days.

-- 1) Backfill the most recent 1 day, capped to 5,000 legacy orders.
SELECT public.backfill_sales_summary_from_legacy(
  now() - interval '1 day',
  now(),
  5000
) AS backfill_result;

-- 2) Validation: compare legacy item facts vs lightweight facts for the same window.
WITH legacy AS (
  SELECT
    count(DISTINCT o.jst_o_id) AS order_count,
    count(*) AS item_count,
    coalesce(sum(i.qty), 0) AS qty,
    coalesce(sum(coalesce(nullif(i.paid_amount, 0), nullif(i.amount, 0), 0)), 0) AS pay_amount,
    count(DISTINCT coalesce(nullif(i.sku_code, ''), nullif(i.sku_id, ''))) AS sku_count,
    count(DISTINCT coalesce(nullif(i.i_id, ''), nullif(i.sku_code, ''))) AS style_count
  FROM public.jst_sales_orders o
  JOIN public.jst_sales_order_items i ON i.sales_order_id = o.id
  WHERE coalesce(o.modified_time, o.pay_time, o.created_time) >= now() - interval '1 day'
    AND coalesce(o.modified_time, o.pay_time, o.created_time) < now()
),
lightweight AS (
  SELECT
    count(DISTINCT o_id) AS order_count,
    count(*) AS item_count,
    coalesce(sum(qty), 0) AS qty,
    coalesce(sum(pay_amount), 0) AS pay_amount,
    count(DISTINCT coalesce(nullif(sku_code, ''), nullif(sku_id, ''))) AS sku_count,
    count(DISTINCT coalesce(nullif(style_no, ''), nullif(sku_code, ''))) AS style_count
  FROM public.sales_order_light_items
  WHERE coalesce(modified_time, pay_time, created_time) >= now() - interval '1 day'
    AND coalesce(modified_time, pay_time, created_time) < now()
)
SELECT
  'legacy_vs_lightweight_1d' AS check_name,
  legacy.order_count AS legacy_orders,
  lightweight.order_count AS light_orders,
  legacy.item_count AS legacy_items,
  lightweight.item_count AS light_items,
  legacy.qty AS legacy_qty,
  lightweight.qty AS light_qty,
  legacy.pay_amount AS legacy_pay_amount,
  lightweight.pay_amount AS light_pay_amount,
  legacy.sku_count AS legacy_skus,
  lightweight.sku_count AS light_skus,
  legacy.style_count AS legacy_styles,
  lightweight.style_count AS light_styles
FROM legacy, lightweight;

-- 3) Expand only after the 1-day validation is acceptable.
-- SELECT public.backfill_sales_summary_from_legacy(now() - interval '7 days', now(), 5000);
-- SELECT public.backfill_sales_summary_from_legacy(now() - interval '30 days', now(), 5000);

-- 4) Cleanup plan only. Do not run without explicit approval and a maintenance window:
-- - Batch-null legacy raw fields after summaries are verified:
--   jst_sales_orders.raw_data
--   jst_sales_order_items.raw_item_data
--   jst_outbound_orders.raw_data / jst_outbound_order_items.raw_data
--   jst_refund_orders.raw_data / jst_refund_order_items.raw_data
--   jst_aftersale_received_orders.raw_data / jst_aftersale_received_items.raw_data
-- - Expire jst_sync_log_details.request_body by age.
-- - Avoid VACUUM FULL during business hours; prefer maintenance-window table rebuild or pg_repack if available.
