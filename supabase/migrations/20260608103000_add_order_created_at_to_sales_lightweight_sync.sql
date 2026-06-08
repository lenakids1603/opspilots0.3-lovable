-- Add customer order creation time for lightweight sales sync.
-- Non-destructive: adds nullable columns and keeps raw/history data intact.

ALTER TABLE public.jst_sales_orders
  ADD COLUMN IF NOT EXISTS order_created_at timestamptz;

ALTER TABLE public.sales_order_light_items
  ADD COLUMN IF NOT EXISTS order_created_at timestamptz;

ALTER TABLE public.order_lookup_index
  ADD COLUMN IF NOT EXISTS order_created_at timestamptz;

ALTER TABLE public.shipping_risk_orders
  ADD COLUMN IF NOT EXISTS order_created_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_jst_sales_orders_order_created_at
  ON public.jst_sales_orders(order_created_at);

CREATE INDEX IF NOT EXISTS idx_sales_light_items_order_created_at
  ON public.sales_order_light_items(order_created_at);

CREATE INDEX IF NOT EXISTS idx_order_lookup_index_order_created_at
  ON public.order_lookup_index(order_created_at);

CREATE INDEX IF NOT EXISTS idx_shipping_risk_orders_order_created_at
  ON public.shipping_risk_orders(order_created_at);

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

  CREATE TEMP TABLE tmp_sales_refresh_all_facts ON COMMIT DROP AS
  SELECT
    f.*,
    coalesce(f.order_created_at, f.pay_time) AS business_time
  FROM public.sales_order_light_items f
  WHERE coalesce(f.order_created_at, f.pay_time) IS NOT NULL;

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

CREATE OR REPLACE FUNCTION public.backfill_sales_summary_from_legacy(
  _from timestamptz DEFAULT now() - interval '1 day',
  _to timestamptz DEFAULT now(),
  _max_orders int DEFAULT 5000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item_keys text[];
  inserted_items int := 0;
  lookup_rows int := 0;
  risk_rows int := 0;
  summary_result jsonb;
BEGIN
  IF _to <= _from THEN
    RAISE EXCEPTION '_to must be later than _from';
  END IF;

  CREATE TEMP TABLE tmp_backfill_orders ON COMMIT DROP AS
  SELECT *
  FROM public.jst_sales_orders o
  WHERE coalesce(o.modified_time, o.order_created_at, o.pay_time, o.created_time) >= _from
    AND coalesce(o.modified_time, o.order_created_at, o.pay_time, o.created_time) < _to
  ORDER BY coalesce(o.modified_time, o.order_created_at, o.pay_time, o.created_time) DESC NULLS LAST
  LIMIT greatest(1, least(coalesce(_max_orders, 5000), 5000));

  CREATE TEMP TABLE tmp_backfill_items ON COMMIT DROP AS
  SELECT
    coalesce(nullif(i.item_unique_key, ''), concat_ws('|', o.jst_o_id, coalesce(i.jst_item_id, ''), coalesce(i.sku_id, ''), coalesce(i.item_index::text, ''))) AS item_unique_key,
    o.jst_o_id AS o_id,
    o.so_id,
    o.shop_id,
    o.shop_name,
    null::text AS platform,
    o.status AS order_status,
    o.internal_order_type,
    o.internal_order_type_name,
    coalesce(o.order_created_at, o.created_time) AS order_created_at,
    o.created_time,
    o.pay_time,
    o.modified_time,
    o.plan_delivery_date,
    o.io_id,
    o.io_date,
    o.l_id,
    i.sku_id,
    i.sku_code,
    i.sku_name,
    coalesce(nullif(i.i_id, ''), nullif(i.sku_code, '')) AS style_no,
    i.product_name,
    null::text AS color,
    null::text AS size,
    i.supplier_id,
    i.supplier_name,
    coalesce(i.qty, 0) AS qty,
    coalesce(i.sale_price, 0) AS sale_price,
    coalesce(nullif(i.paid_amount, 0), nullif(i.amount, 0), 0) AS pay_amount,
    coalesce(nullif(i.paid_amount, 0), nullif(i.amount, 0), 0) AS paid_amount,
    i.refund_status,
    null::numeric AS estimated_cost_price,
    0::numeric AS estimated_cost_amount,
    coalesce(o.internal_order_type, '') IN ('shipped', 'returned_after_ship') AS is_shipped,
    coalesce(o.internal_order_type, '') IN ('paid_cancelled_before_ship', 'returned_after_ship') AS has_refund,
    o.modified_time AS last_jst_modified,
    now() AS synced_at
  FROM tmp_backfill_orders o
  JOIN public.jst_sales_order_items i ON i.sales_order_id = o.id
  WHERE o.jst_o_id IS NOT NULL;

  INSERT INTO public.sales_order_light_items (
    item_unique_key, o_id, so_id, shop_id, shop_name, platform, order_status,
    internal_order_type, internal_order_type_name, order_created_at, created_time, pay_time, modified_time,
    plan_delivery_date, io_id, io_date, l_id, sku_id, sku_code, sku_name, style_no,
    product_name, color, size, supplier_id, supplier_name, qty, sale_price, pay_amount,
    paid_amount, refund_status, estimated_cost_price, estimated_cost_amount, is_shipped,
    has_refund, last_jst_modified, synced_at
  )
  SELECT
    item_unique_key, o_id, so_id, shop_id, shop_name, platform, order_status,
    internal_order_type, internal_order_type_name, order_created_at, created_time, pay_time, modified_time,
    plan_delivery_date, io_id, io_date, l_id, sku_id, sku_code, sku_name, style_no,
    product_name, color, size, supplier_id, supplier_name, qty, sale_price, pay_amount,
    paid_amount, refund_status, estimated_cost_price, estimated_cost_amount, is_shipped,
    has_refund, last_jst_modified, synced_at
  FROM tmp_backfill_items
  ON CONFLICT (item_unique_key) DO UPDATE SET
    o_id = EXCLUDED.o_id,
    so_id = EXCLUDED.so_id,
    shop_id = EXCLUDED.shop_id,
    shop_name = EXCLUDED.shop_name,
    platform = EXCLUDED.platform,
    order_status = EXCLUDED.order_status,
    internal_order_type = EXCLUDED.internal_order_type,
    internal_order_type_name = EXCLUDED.internal_order_type_name,
    order_created_at = coalesce(EXCLUDED.order_created_at, sales_order_light_items.order_created_at),
    created_time = EXCLUDED.created_time,
    pay_time = EXCLUDED.pay_time,
    modified_time = EXCLUDED.modified_time,
    plan_delivery_date = EXCLUDED.plan_delivery_date,
    io_id = EXCLUDED.io_id,
    io_date = EXCLUDED.io_date,
    l_id = EXCLUDED.l_id,
    sku_id = EXCLUDED.sku_id,
    sku_code = EXCLUDED.sku_code,
    sku_name = EXCLUDED.sku_name,
    style_no = EXCLUDED.style_no,
    product_name = EXCLUDED.product_name,
    color = EXCLUDED.color,
    size = EXCLUDED.size,
    supplier_id = EXCLUDED.supplier_id,
    supplier_name = EXCLUDED.supplier_name,
    qty = EXCLUDED.qty,
    sale_price = EXCLUDED.sale_price,
    pay_amount = EXCLUDED.pay_amount,
    paid_amount = EXCLUDED.paid_amount,
    refund_status = EXCLUDED.refund_status,
    estimated_cost_price = EXCLUDED.estimated_cost_price,
    estimated_cost_amount = EXCLUDED.estimated_cost_amount,
    is_shipped = EXCLUDED.is_shipped,
    has_refund = EXCLUDED.has_refund,
    last_jst_modified = EXCLUDED.last_jst_modified,
    synced_at = EXCLUDED.synced_at,
    updated_at = now();
  GET DIAGNOSTICS inserted_items = ROW_COUNT;

  SELECT array_agg(item_unique_key) INTO item_keys FROM tmp_backfill_items;
  summary_result := public.refresh_sales_summaries_for_order_items(coalesce(item_keys, ARRAY[]::text[]));

  INSERT INTO public.order_lookup_index (
    o_id, so_id, shop_id, shop_name, platform, order_status, order_created_at, pay_time, pay_amount,
    item_count, qty, has_refund, jst_modified, synced_at, expires_at
  )
  SELECT
    o_id, max(so_id), max(shop_id), max(shop_name), max(platform), max(order_status), max(order_created_at), max(pay_time),
    coalesce(sum(pay_amount), 0), count(*)::int, coalesce(sum(qty), 0),
    bool_or(has_refund), max(last_jst_modified), now(), now() + interval '90 days'
  FROM tmp_backfill_items
  GROUP BY o_id
  ON CONFLICT (o_id) DO UPDATE SET
    so_id = EXCLUDED.so_id,
    shop_id = EXCLUDED.shop_id,
    shop_name = EXCLUDED.shop_name,
    platform = EXCLUDED.platform,
    order_status = EXCLUDED.order_status,
    order_created_at = coalesce(EXCLUDED.order_created_at, order_lookup_index.order_created_at),
    pay_time = EXCLUDED.pay_time,
    pay_amount = EXCLUDED.pay_amount,
    item_count = EXCLUDED.item_count,
    qty = EXCLUDED.qty,
    has_refund = EXCLUDED.has_refund,
    jst_modified = EXCLUDED.jst_modified,
    synced_at = EXCLUDED.synced_at,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();
  GET DIAGNOSTICS lookup_rows = ROW_COUNT;

  DELETE FROM public.shipping_risk_orders r
  USING tmp_backfill_orders o
  WHERE r.o_id = o.jst_o_id
    AND coalesce(o.internal_order_type, '') <> 'paid_pending_ship';

  INSERT INTO public.shipping_risk_orders (
    item_unique_key, o_id, so_id, shop_id, shop_name, platform, order_status, order_created_at, pay_time, jst_modified,
    latest_ship_time, remaining_hours, is_timeout, risk_level, sku_code, sku_name, style_no, color, size, qty, supplier_name,
    last_checked_at
  )
  SELECT
    item_unique_key, o_id, so_id, shop_id, shop_name, platform, order_status, order_created_at, pay_time, last_jst_modified,
    coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours'),
    CASE
      WHEN coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') IS NULL THEN NULL
      ELSE EXTRACT(epoch FROM (coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') - now())) / 3600
    END,
    coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') IS NOT NULL
      AND coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') < now(),
    CASE
      WHEN coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') IS NULL THEN 'unknown'
      WHEN coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') < now() THEN 'timeout'
      WHEN coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') <= now() + interval '6 hours' THEN 'high'
      WHEN coalesce(plan_delivery_date, pay_time + interval '48 hours', order_created_at + interval '48 hours') <= now() + interval '24 hours' THEN 'medium'
      ELSE 'low'
    END,
    sku_code, sku_name, style_no, color, size, qty, supplier_name, now()
  FROM tmp_backfill_items
  WHERE internal_order_type = 'paid_pending_ship'
  ON CONFLICT (item_unique_key) DO UPDATE SET
    o_id = EXCLUDED.o_id,
    so_id = EXCLUDED.so_id,
    shop_id = EXCLUDED.shop_id,
    shop_name = EXCLUDED.shop_name,
    platform = EXCLUDED.platform,
    order_status = EXCLUDED.order_status,
    order_created_at = coalesce(EXCLUDED.order_created_at, shipping_risk_orders.order_created_at),
    pay_time = EXCLUDED.pay_time,
    jst_modified = EXCLUDED.jst_modified,
    latest_ship_time = EXCLUDED.latest_ship_time,
    remaining_hours = EXCLUDED.remaining_hours,
    is_timeout = EXCLUDED.is_timeout,
    risk_level = EXCLUDED.risk_level,
    sku_code = EXCLUDED.sku_code,
    sku_name = EXCLUDED.sku_name,
    style_no = EXCLUDED.style_no,
    color = EXCLUDED.color,
    size = EXCLUDED.size,
    qty = EXCLUDED.qty,
    supplier_name = EXCLUDED.supplier_name,
    last_checked_at = now(),
    updated_at = now();
  GET DIAGNOSTICS risk_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'window_from', _from,
    'window_to', _to,
    'max_orders', _max_orders,
    'legacy_orders_scanned', (SELECT count(*) FROM tmp_backfill_orders),
    'light_items_upserted', inserted_items,
    'lookup_rows_upserted', lookup_rows,
    'risk_rows_upserted', risk_rows,
    'summary', summary_result
  );
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_sales_summaries_for_order_items(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_sales_summaries_for_order_items(text[]) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.backfill_sales_summary_from_legacy(timestamptz, timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_sales_summary_from_legacy(timestamptz, timestamptz, int) TO service_role;
