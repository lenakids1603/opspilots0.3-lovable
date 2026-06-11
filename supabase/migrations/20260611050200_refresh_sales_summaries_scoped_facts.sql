-- refresh_sales_summaries_for_order_items：tmp_sales_refresh_all_facts 按受影响日期过滤。
-- 背景：旧实现每次调用（销售同步每页一次）把整张 sales_order_light_items（生产 3.9 万行/40MB）
-- 拷进临时表再做 4 个 GROUP BY，是 2026-06-11 生产 statement timeout 与 I/O 压力的主因
-- （pg_stat_statements 累计 2076s 居首，PG 日志确认超时语句即此 RPC）。
-- 修复：汇总桶的最细粒度都含 summary_date，且各维表日期都派生自
-- coalesce(order_created_at, pay_time) 的北京日期；将全量事实表按该日期集过滤后，
-- 重算结果与旧实现严格等价，但单页 I/O 从全表×5 遍降为 1 次日期索引扫描 + 小临时表。
-- 同时为日期过滤补表达式索引。timezone(text,timestamptz) 为 immutable，可入索引。

CREATE INDEX IF NOT EXISTS idx_sales_light_items_business_date
  ON public.sales_order_light_items
  (((coalesce(order_created_at, pay_time) AT TIME ZONE 'Asia/Shanghai')::date));

CREATE OR REPLACE FUNCTION public.refresh_sales_summaries_for_order_items(_item_keys text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  hourly_rows int := 0;
  daily_rows int := 0;
  sku_rows int := 0;
  style_rows int := 0;
BEGIN
  IF _item_keys IS NULL OR cardinality(_item_keys) = 0 THEN
    RETURN jsonb_build_object('hourly', 0, 'daily', 0, 'sku_daily', 0, 'style_daily', 0);
  END IF;

  CREATE TEMP TABLE tmp_sales_refresh_keys ON COMMIT DROP AS
  SELECT DISTINCT item_unique_key
  FROM unnest(_item_keys) AS k(item_unique_key)
  WHERE item_unique_key IS NOT NULL AND btrim(item_unique_key) <> '';

  CREATE TEMP TABLE tmp_sales_refresh_facts ON COMMIT DROP AS
  SELECT
    f.*,
    coalesce(f.order_created_at, f.pay_time) AS business_time
  FROM public.sales_order_light_items f
  WHERE f.item_unique_key IN (SELECT item_unique_key FROM tmp_sales_refresh_keys)
    AND coalesce(f.order_created_at, f.pay_time) IS NOT NULL;

  -- 受影响的北京日期集：与各维表 summary_date 完全同源（business_time / pay_time 两路）
  CREATE TEMP TABLE tmp_sales_refresh_dates ON COMMIT DROP AS
  SELECT DISTINCT (refresh_time AT TIME ZONE 'Asia/Shanghai')::date AS summary_date
  FROM tmp_sales_refresh_facts
  CROSS JOIN LATERAL (VALUES (business_time), (pay_time)) AS t(refresh_time)
  WHERE refresh_time IS NOT NULL;

  -- 仅取受影响日期的事实行（旧实现为全表拷贝）。
  -- 正确性：所有汇总桶均按 business_time 的北京日期分桶，桶日期 ∈ 上述日期集，
  -- 故重算受影响桶所需的全部事实行都被保留。
  CREATE TEMP TABLE tmp_sales_refresh_all_facts ON COMMIT DROP AS
  SELECT
    f.*,
    coalesce(f.order_created_at, f.pay_time) AS business_time
  FROM public.sales_order_light_items f
  WHERE coalesce(f.order_created_at, f.pay_time) IS NOT NULL
    AND (coalesce(f.order_created_at, f.pay_time) AT TIME ZONE 'Asia/Shanghai')::date
        IN (SELECT summary_date FROM tmp_sales_refresh_dates);

  CREATE TEMP TABLE tmp_hourly_dims ON COMMIT DROP AS
  SELECT DISTINCT
    (refresh_time AT TIME ZONE 'Asia/Shanghai')::date AS summary_date,
    EXTRACT(hour FROM refresh_time AT TIME ZONE 'Asia/Shanghai')::int AS summary_hour,
    platform, shop_id, sku_code, style_no
  FROM tmp_sales_refresh_facts
  CROSS JOIN LATERAL (VALUES (business_time), (pay_time)) AS t(refresh_time)
  WHERE refresh_time IS NOT NULL;

  CREATE TEMP TABLE tmp_daily_dims ON COMMIT DROP AS
  SELECT DISTINCT
    (refresh_time AT TIME ZONE 'Asia/Shanghai')::date AS summary_date,
    platform, shop_id
  FROM tmp_sales_refresh_facts
  CROSS JOIN LATERAL (VALUES (business_time), (pay_time)) AS t(refresh_time)
  WHERE refresh_time IS NOT NULL;

  CREATE TEMP TABLE tmp_sku_dims ON COMMIT DROP AS
  SELECT DISTINCT
    (refresh_time AT TIME ZONE 'Asia/Shanghai')::date AS summary_date,
    platform, shop_id, sku_code
  FROM tmp_sales_refresh_facts
  CROSS JOIN LATERAL (VALUES (business_time), (pay_time)) AS t(refresh_time)
  WHERE refresh_time IS NOT NULL;

  CREATE TEMP TABLE tmp_style_dims ON COMMIT DROP AS
  SELECT DISTINCT
    (refresh_time AT TIME ZONE 'Asia/Shanghai')::date AS summary_date,
    platform, shop_id, style_no
  FROM tmp_sales_refresh_facts
  CROSS JOIN LATERAL (VALUES (business_time), (pay_time)) AS t(refresh_time)
  WHERE refresh_time IS NOT NULL;

  DELETE FROM public.sales_hourly_summary h
  USING tmp_hourly_dims d
  WHERE h.summary_key = md5(concat_ws('|', d.summary_date::text, d.summary_hour::text, coalesce(d.platform, ''), coalesce(d.shop_id, ''), coalesce(d.sku_code, ''), coalesce(d.style_no, '')));

  INSERT INTO public.sales_hourly_summary (
    summary_date, summary_hour, platform, shop_id, shop_name, style_no, sku_code, supplier_name,
    pay_order_count, pay_item_count, pay_qty, pay_amount,
    net_qty, net_amount, estimated_cost_amount, estimated_gross_profit,
    first_order_time, last_order_time, last_jst_modified, summary_key, updated_at
  )
  SELECT
    (f.business_time AT TIME ZONE 'Asia/Shanghai')::date,
    EXTRACT(hour FROM f.business_time AT TIME ZONE 'Asia/Shanghai')::int,
    f.platform, f.shop_id, max(f.shop_name), f.style_no, f.sku_code, max(f.supplier_name),
    count(DISTINCT f.o_id)::int,
    count(*)::int,
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.estimated_cost_amount), 0),
    coalesce(sum(f.pay_amount), 0) - coalesce(sum(f.estimated_cost_amount), 0),
    min(f.business_time),
    max(f.business_time),
    max(f.last_jst_modified),
    md5(concat_ws('|', ((f.business_time AT TIME ZONE 'Asia/Shanghai')::date)::text, (EXTRACT(hour FROM f.business_time AT TIME ZONE 'Asia/Shanghai')::int)::text, coalesce(f.platform, ''), coalesce(f.shop_id, ''), coalesce(f.sku_code, ''), coalesce(f.style_no, ''))),
    now()
  FROM tmp_sales_refresh_all_facts f
  JOIN tmp_hourly_dims d
    ON d.summary_date = (f.business_time AT TIME ZONE 'Asia/Shanghai')::date
   AND d.summary_hour = EXTRACT(hour FROM f.business_time AT TIME ZONE 'Asia/Shanghai')::int
   AND coalesce(d.platform, '') = coalesce(f.platform, '')
   AND coalesce(d.shop_id, '') = coalesce(f.shop_id, '')
   AND coalesce(d.sku_code, '') = coalesce(f.sku_code, '')
   AND coalesce(d.style_no, '') = coalesce(f.style_no, '')
  GROUP BY 1, 2, 3, 4, 6, 7;
  GET DIAGNOSTICS hourly_rows = ROW_COUNT;

  DELETE FROM public.sales_daily_summary s
  USING tmp_daily_dims d
  WHERE s.summary_key = md5(concat_ws('|', d.summary_date::text, coalesce(d.platform, ''), coalesce(d.shop_id, '')));

  INSERT INTO public.sales_daily_summary (
    summary_date, platform, shop_id, shop_name,
    pay_order_count, pay_item_count, pay_qty, pay_amount,
    net_qty, net_amount, estimated_cost_amount, estimated_gross_profit,
    first_order_time, last_order_time, last_jst_modified, summary_key, updated_at
  )
  SELECT
    (f.business_time AT TIME ZONE 'Asia/Shanghai')::date,
    f.platform, f.shop_id, max(f.shop_name),
    count(DISTINCT f.o_id)::int,
    count(*)::int,
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.estimated_cost_amount), 0),
    coalesce(sum(f.pay_amount), 0) - coalesce(sum(f.estimated_cost_amount), 0),
    min(f.business_time),
    max(f.business_time),
    max(f.last_jst_modified),
    md5(concat_ws('|', ((f.business_time AT TIME ZONE 'Asia/Shanghai')::date)::text, coalesce(f.platform, ''), coalesce(f.shop_id, ''))),
    now()
  FROM tmp_sales_refresh_all_facts f
  JOIN tmp_daily_dims d
    ON d.summary_date = (f.business_time AT TIME ZONE 'Asia/Shanghai')::date
   AND coalesce(d.platform, '') = coalesce(f.platform, '')
   AND coalesce(d.shop_id, '') = coalesce(f.shop_id, '')
  GROUP BY 1, 2, 3;
  GET DIAGNOSTICS daily_rows = ROW_COUNT;

  DELETE FROM public.sales_sku_daily_summary s
  USING tmp_sku_dims d
  WHERE s.summary_key = md5(concat_ws('|', d.summary_date::text, coalesce(d.platform, ''), coalesce(d.shop_id, ''), coalesce(d.sku_code, '')));

  INSERT INTO public.sales_sku_daily_summary (
    summary_date, platform, shop_id, shop_name, sku_code, sku_name, style_no, color, size, supplier_name,
    pay_order_count, pay_qty, pay_amount, net_qty, net_amount,
    estimated_cost_price, estimated_cost_amount, estimated_gross_profit, last_jst_modified, summary_key, updated_at
  )
  SELECT
    (f.business_time AT TIME ZONE 'Asia/Shanghai')::date,
    f.platform, f.shop_id, max(f.shop_name), f.sku_code, max(f.sku_name), max(f.style_no), max(f.color), max(f.size), max(f.supplier_name),
    count(DISTINCT f.o_id)::int,
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    max(f.estimated_cost_price),
    coalesce(sum(f.estimated_cost_amount), 0),
    coalesce(sum(f.pay_amount), 0) - coalesce(sum(f.estimated_cost_amount), 0),
    max(f.last_jst_modified),
    md5(concat_ws('|', ((f.business_time AT TIME ZONE 'Asia/Shanghai')::date)::text, coalesce(f.platform, ''), coalesce(f.shop_id, ''), coalesce(f.sku_code, ''))),
    now()
  FROM tmp_sales_refresh_all_facts f
  JOIN tmp_sku_dims d
    ON d.summary_date = (f.business_time AT TIME ZONE 'Asia/Shanghai')::date
   AND coalesce(d.platform, '') = coalesce(f.platform, '')
   AND coalesce(d.shop_id, '') = coalesce(f.shop_id, '')
   AND coalesce(d.sku_code, '') = coalesce(f.sku_code, '')
  GROUP BY 1, 2, 3, 5;
  GET DIAGNOSTICS sku_rows = ROW_COUNT;

  DELETE FROM public.sales_style_daily_summary s
  USING tmp_style_dims d
  WHERE s.summary_key = md5(concat_ws('|', d.summary_date::text, coalesce(d.platform, ''), coalesce(d.shop_id, ''), coalesce(d.style_no, '')));

  INSERT INTO public.sales_style_daily_summary (
    summary_date, platform, shop_id, shop_name, style_no, supplier_name,
    pay_order_count, pay_sku_count, pay_qty, pay_amount,
    net_qty, net_amount, estimated_cost_amount, estimated_gross_profit, last_jst_modified, summary_key, updated_at
  )
  SELECT
    (f.business_time AT TIME ZONE 'Asia/Shanghai')::date,
    f.platform, f.shop_id, max(f.shop_name), f.style_no, max(f.supplier_name),
    count(DISTINCT f.o_id)::int,
    count(DISTINCT f.sku_code)::int,
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.qty), 0),
    coalesce(sum(f.pay_amount), 0),
    coalesce(sum(f.estimated_cost_amount), 0),
    coalesce(sum(f.pay_amount), 0) - coalesce(sum(f.estimated_cost_amount), 0),
    max(f.last_jst_modified),
    md5(concat_ws('|', ((f.business_time AT TIME ZONE 'Asia/Shanghai')::date)::text, coalesce(f.platform, ''), coalesce(f.shop_id, ''), coalesce(f.style_no, ''))),
    now()
  FROM tmp_sales_refresh_all_facts f
  JOIN tmp_style_dims d
    ON d.summary_date = (f.business_time AT TIME ZONE 'Asia/Shanghai')::date
   AND coalesce(d.platform, '') = coalesce(f.platform, '')
   AND coalesce(d.shop_id, '') = coalesce(f.shop_id, '')
   AND coalesce(d.style_no, '') = coalesce(f.style_no, '')
  GROUP BY 1, 2, 3, 5;
  GET DIAGNOSTICS style_rows = ROW_COUNT;

  RETURN jsonb_build_object('hourly', hourly_rows, 'daily', daily_rows, 'sku_daily', sku_rows, 'style_daily', style_rows);
END;
$$;
