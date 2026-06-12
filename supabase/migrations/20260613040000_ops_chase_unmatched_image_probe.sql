-- 未匹配桶款图回退查询优化(2026-06-13)
--
-- ops_chase_unmatched_list 的 LATERAL 款图回退用了
-- 「s.style_no = 款 OR s.sku_code IN (该款 SKU)」单条 OR 谓词,优化器无法
-- 同时用 idx_ops_skus_style_no / idx_ops_skus_sku_code 两个索引,退化为
-- 每款一次 ops_skus(1.1 万行)全表扫,生产复刻实测整函数 ~945ms。
-- 改为 UNION ALL 两个索引探针(语义不变:有图取图,无图为 NULL),
-- 其余口径与 20260613030000 完全一致。

CREATE OR REPLACE FUNCTION public.ops_chase_unmatched_list()
RETURNS TABLE (
  style_no text, product_name text, image_url text,
  total_qty numeric, overdue_qty numeric, due24_qty numeric,
  due48_qty numeric, due72_qty numeric, later_qty numeric,
  order_count bigint, shop_names text[], earliest_ship_time timestamptz,
  sku_details jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_ops_internal(auth.uid()) THEN
    RAISE EXCEPTION '仅限内部用户' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH matched AS MATERIALIZED (
    SELECT DISTINCT s.item_unique_key
    FROM public.ops_chase_match_snapshot s
    WHERE s.category IN ('urge_supplier', 'late_order', 'in_transit', 'closed_short')
      AND coalesce(s.supplier_name, '') <> ''
  ),
  base AS (
    SELECT coalesce(nullif(r.style_no, ''), nullif(r.sku_code, ''), '(无款号)') AS s_no,
           coalesce(nullif(r.sku_code, ''), '(无SKU)') AS sku,
           r.sku_name, r.qty, r.o_id, r.latest_ship_time,
           coalesce(nullif(r.shop_name, ''), r.shop_id, '') AS shop
    FROM public.shipping_risk_orders r
    LEFT JOIN matched m ON m.item_unique_key = r.item_unique_key
    WHERE r.order_status IN ('Question', 'WaitConfirm')
      AND coalesce(r.qty, 0) > 0
      AND (coalesce(r.supplier_name, '') = '' OR coalesce(r.style_no, '') ~ '^\d{12,}')
      AND m.item_unique_key IS NULL
      AND r.latest_ship_time IS NOT NULL
      AND r.latest_ship_time <= now() + interval '7 days'
      AND (
        coalesce(r.style_no, '') ~ '^\d{12,}'
        OR EXISTS (
          SELECT 1 FROM public.purchase_order_items poi
          JOIN public.purchase_orders po2 ON po2.id = poi.purchase_order_id
          WHERE (poi.style_no = coalesce(nullif(r.style_no, ''), r.sku_code)
                 OR (coalesce(r.sku_code, '') <> '' AND poi.sku_no = r.sku_code))
            AND coalesce(po2.status, '') NOT IN ('Delete', 'Cancelled')
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.ops_chase_excluded_styles e
        WHERE e.scope IN ('chase', 'all')
          AND (e.style_no IS NULL OR lower(e.style_no) = lower(coalesce(r.style_no, '')))
          AND (e.sku IS NULL OR e.sku = coalesce(r.sku_code, ''))
      )
  ),
  by_sku AS (
    SELECT b.s_no, b.sku, max(coalesce(b.sku_name, '')) AS sku_name,
           sum(b.qty) AS qty,
           coalesce(sum(b.qty) FILTER (WHERE b.latest_ship_time <= now()), 0) AS overdue,
           coalesce(sum(b.qty) FILTER (WHERE b.latest_ship_time > now()
             AND b.latest_ship_time <= now() + interval '24 hours'), 0) AS due24,
           coalesce(sum(b.qty) FILTER (WHERE b.latest_ship_time > now() + interval '24 hours'
             AND b.latest_ship_time <= now() + interval '48 hours'), 0) AS due48,
           coalesce(sum(b.qty) FILTER (WHERE b.latest_ship_time > now() + interval '48 hours'
             AND b.latest_ship_time <= now() + interval '72 hours'), 0) AS due72,
           coalesce(sum(b.qty) FILTER (WHERE b.latest_ship_time > now() + interval '72 hours'), 0) AS later
    FROM base b
    GROUP BY b.s_no, b.sku
  ),
  by_style AS (
    SELECT b.s_no,
           count(DISTINCT b.o_id) AS orders,
           array_agg(DISTINCT b.shop) FILTER (WHERE b.shop <> '') AS shops,
           min(b.latest_ship_time) AS earliest
    FROM base b
    GROUP BY b.s_no
  )
  SELECT k.s_no,
         coalesce(nullif(p.product_name, ''), CASE WHEN p.name <> p.code THEN p.name END),
         coalesce(nullif(p.main_image_url, ''), nullif(p.external_image_url, ''), si.img),
         sum(k.qty), sum(k.overdue), sum(k.due24), sum(k.due48), sum(k.due72), sum(k.later),
         st.orders, st.shops, st.earliest,
         jsonb_agg(jsonb_build_object(
           'sku', k.sku, 'sku_name', k.sku_name, 'qty', k.qty, 'overdue_qty', k.overdue
         ) ORDER BY k.overdue DESC, k.qty DESC)
  FROM by_sku k
  JOIN by_style st ON st.s_no = k.s_no
  LEFT JOIN public.ops_products p ON p.code = k.s_no
  LEFT JOIN LATERAL (
    -- 两个索引探针代替 OR 全表扫:先按款号,再按该款 SKU,取第一张非空图
    SELECT t.img
    FROM (
      SELECT coalesce(nullif(s.sku_image_url, ''), nullif(s.external_image_url, '')) AS img
      FROM public.ops_skus s
      WHERE s.style_no = k.s_no
      UNION ALL
      SELECT coalesce(nullif(s.sku_image_url, ''), nullif(s.external_image_url, ''))
      FROM public.ops_skus s
      WHERE s.sku_code IN (SELECT k2.sku FROM by_sku k2 WHERE k2.s_no = k.s_no)
    ) t
    WHERE t.img IS NOT NULL
    LIMIT 1
  ) si ON true
  GROUP BY k.s_no, p.product_name, p.name, p.code, p.main_image_url, p.external_image_url, si.img,
           st.orders, st.shops, st.earliest
  ORDER BY sum(k.overdue) DESC, sum(k.qty) DESC, k.s_no;
END
$$;

COMMENT ON FUNCTION public.ops_chase_unmatched_list() IS
  '催货兜底:供应商未匹配且【已逾期～未来7天】内的待发货需求(matched 去重读快照,款图回退走双索引探针);无采购单缺货新款已移除,副本款保留。';
