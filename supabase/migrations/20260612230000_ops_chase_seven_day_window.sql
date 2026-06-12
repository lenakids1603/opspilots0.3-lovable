-- 催发货口径重构:只看 7 天内截止,按紧急度五档分层(2026-06-12,老板确认口径)
--
-- 口径原则:催发货页 = 平台发货截止时间驱动的行动清单。只统计
-- latest_ship_time 在【已逾期 ～ 未来 7 天】内的待发货需求;7 天以外的订单
-- 不进入本页(它们的问题由采购缺口页负责)。
--
-- 变更(边界:ops_chase_match_core 分类逻辑不动,只在列表/聚合层加过滤与分档):
--   1) ops_chase_supplier_list / ops_chase_urgency_summary:
--      仅统计 latest_ship_time IS NOT NULL 且 <= now()+7天 的行;
--      urgency='later' 在 7 天窗口内即「72小时~7天」档,列名 later_qty 不变。
--   2) ops_chase_unmatched_list:同样加 7 天硬过滤;并彻底移除「无采购单的
--      需求」(缺货新款,只出现在采购缺口页签)——保留副本款(平台数字款号,
--      ^\d{12,}):它们是供应商归属映射问题而非缺货问题,正是本桶要兜底的对象。
--      「有采购单」= 该款号或该 SKU 存在非 Delete/Cancelled 的采购明细。
--      新增 due48_qty/due72_qty/later_qty 三列支撑前端五档筛选(返回类型变更,
--      DROP 重建)。
--   3) ops_chase_deadline_timeline:两个分支(urge_supplier + 未匹配兜底)
--      均加 7 天过滤;兜底分支同样移除无采购单需求。
--   4) 采购缺口(ops_chase_purchase_list)/厂家已结单(closed_short)不动,
--      保持全时间范围——采购决策不该等。
--
-- 本文件用 -- @@SPLIT@@ 注释分块,便于 Management API 分段执行。

-- @@SPLIT@@ ============ 1. 接口A:催供应商(7 天硬过滤) ============
CREATE OR REPLACE FUNCTION public.ops_chase_supplier_list()
RETURNS TABLE (
  supplier_id uuid, supplier_name text, sku text, style_no text,
  total_qty numeric, overdue_qty numeric, due24_qty numeric,
  due48_qty numeric, due72_qty numeric, later_qty numeric,
  po_count int, max_overdue_days int, po_details jsonb,
  product_name text, image_url text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_supplier uuid;
BEGIN
  IF public.is_ops_internal(v_uid) THEN
    v_supplier := NULL;  -- 内部用户看全部
  ELSE
    v_supplier := public.supplier_id_of(v_uid);  -- 供应商账号只看自己
    IF v_supplier IS NULL THEN
      RAISE EXCEPTION '无权访问催供应商清单' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN QUERY
  WITH per_po AS (
    SELECT c.supplier_id, c.supplier_name, c.sku, max(c.style_no) AS style_no,
           c.external_po_id, c.delivery_date, max(c.overdue_days) AS overdue_days,
           sum(c.match_qty) AS qty,
           sum(c.match_qty) FILTER (WHERE c.urgency = 'overdue') AS q_overdue,
           sum(c.match_qty) FILTER (WHERE c.urgency = 'due24') AS q_due24,
           sum(c.match_qty) FILTER (WHERE c.urgency = 'due48') AS q_due48,
           sum(c.match_qty) FILTER (WHERE c.urgency = 'due72') AS q_due72,
           sum(c.match_qty) FILTER (WHERE c.urgency = 'later') AS q_later
    FROM public.ops_chase_match_core() c
    WHERE c.category = 'urge_supplier'
      AND (v_supplier IS NULL OR c.supplier_id = v_supplier)
      -- 7 天硬过滤:已逾期 ～ 未来 7 天;无承诺发货时间的不进本页
      AND c.latest_ship_time IS NOT NULL
      AND c.latest_ship_time <= now() + interval '7 days'
    GROUP BY c.supplier_id, c.supplier_name, c.sku, c.external_po_id, c.delivery_date
  ),
  by_sku AS (
    SELECT p.supplier_id AS r_supplier_id, p.supplier_name AS r_supplier_name,
           p.sku AS r_sku, max(p.style_no) AS r_style_no,
           sum(p.qty) AS r_total,
           coalesce(sum(p.q_overdue), 0) AS r_overdue, coalesce(sum(p.q_due24), 0) AS r_due24,
           coalesce(sum(p.q_due48), 0) AS r_due48, coalesce(sum(p.q_due72), 0) AS r_due72,
           coalesce(sum(p.q_later), 0) AS r_later,
           count(DISTINCT p.external_po_id)::int AS r_po_count, max(p.overdue_days) AS r_max_overdue,
           jsonb_agg(jsonb_build_object(
             'po_id', p.external_po_id,
             'delivery_date', (p.delivery_date AT TIME ZONE 'Asia/Shanghai')::date,
             'overdue_days', p.overdue_days,
             'qty', p.qty) ORDER BY p.delivery_date) AS r_po_details
    FROM per_po p
    GROUP BY p.supplier_id, p.supplier_name, p.sku
  )
  SELECT b.r_supplier_id, b.r_supplier_name, b.r_sku, b.r_style_no,
         b.r_total, b.r_overdue, b.r_due24, b.r_due48, b.r_due72, b.r_later,
         b.r_po_count, b.r_max_overdue, b.r_po_details,
         coalesce(nullif(pr.product_name, ''),
                  CASE WHEN pr.name <> pr.code THEN pr.name END),
         coalesce(nullif(pr.main_image_url, ''), nullif(pr.external_image_url, ''))
  FROM by_sku b
  LEFT JOIN public.ops_products pr ON pr.code = b.r_style_no
  ORDER BY b.r_overdue DESC, b.r_max_overdue DESC, b.r_total DESC;
END
$$;

COMMENT ON FUNCTION public.ops_chase_supplier_list() IS
  '催供应商清单:仅含 latest_ship_time 在【已逾期～未来7天】内的需求;later_qty 即「72小时~7天」档。';

-- @@SPLIT@@ ============ 2. 接口D:紧急度汇总(7 天硬过滤) ============
CREATE OR REPLACE FUNCTION public.ops_chase_urgency_summary()
RETURNS TABLE (urgency text, qty numeric, order_count bigint, supplier_count bigint)
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
  WITH agg AS (
    SELECT c.urgency AS u, sum(c.match_qty) AS s_qty,
           count(DISTINCT c.o_id) AS s_orders,
           count(DISTINCT coalesce(c.supplier_id::text, c.supplier_name)) AS s_suppliers
    FROM public.ops_chase_match_core() c
    WHERE c.category = 'urge_supplier'
      AND c.latest_ship_time IS NOT NULL
      AND c.latest_ship_time <= now() + interval '7 days'
    GROUP BY c.urgency
  )
  SELECT b.u, coalesce(a.s_qty, 0), coalesce(a.s_orders, 0), coalesce(a.s_suppliers, 0)
  FROM unnest(ARRAY['overdue','due24','due48','due72','later']) WITH ORDINALITY b(u, ord)
  LEFT JOIN agg a ON a.u = b.u
  ORDER BY b.ord;
END
$$;

COMMENT ON FUNCTION public.ops_chase_urgency_summary() IS
  '催供应商紧急度五档汇总(7 天窗口):overdue/due24/due48/due72/later,later 即「72小时~7天」档。';

-- @@SPLIT@@ ============ 3. 接口G:供应商未匹配(7 天过滤+移除无采购单+五档列) ============
DROP FUNCTION IF EXISTS public.ops_chase_unmatched_list();

CREATE FUNCTION public.ops_chase_unmatched_list()
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
  WITH matched AS (
    SELECT DISTINCT c.item_unique_key
    FROM public.ops_chase_match_core() c
    WHERE c.category IN ('urge_supplier', 'late_order', 'in_transit', 'closed_short')
      AND coalesce(c.supplier_name, '') <> ''
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
      -- 7 天硬过滤:已逾期 ～ 未来 7 天
      AND r.latest_ship_time IS NOT NULL
      AND r.latest_ship_time <= now() + interval '7 days'
      -- 移除无采购单的需求(缺货新款→只看采购缺口页);副本款(平台数字款号)保留
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
    SELECT coalesce(nullif(s.sku_image_url, ''), nullif(s.external_image_url, '')) AS img
    FROM public.ops_skus s
    WHERE s.style_no = k.s_no OR s.sku_code IN (SELECT k2.sku FROM by_sku k2 WHERE k2.s_no = k.s_no)
    ORDER BY (coalesce(nullif(s.sku_image_url, ''), nullif(s.external_image_url, '')) IS NULL)
    LIMIT 1
  ) si ON true
  GROUP BY k.s_no, p.product_name, p.name, p.code, p.main_image_url, p.external_image_url, si.img,
           st.orders, st.shops, st.earliest
  ORDER BY sum(k.overdue) DESC, sum(k.qty) DESC, k.s_no;
END
$$;

COMMENT ON FUNCTION public.ops_chase_unmatched_list() IS
  '催货兜底:供应商未匹配且【已逾期～未来7天】内的待发货需求,按款聚合(五档件数列)。无采购单的缺货新款已移除(见采购缺口页);副本款保留。';

REVOKE ALL ON FUNCTION public.ops_chase_unmatched_list() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_unmatched_list() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_unmatched_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_unmatched_list() TO service_role;

-- @@SPLIT@@ ============ 4. 接口F:发货截止时间轴(7 天过滤,兜底分支移除无采购单) ============
CREATE OR REPLACE FUNCTION public.ops_chase_deadline_timeline()
RETURNS TABLE (
  deadline_date date, style_no text, product_name text, image_url text,
  qty numeric, urgency text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_supplier uuid;
BEGIN
  IF public.is_ops_internal(v_uid) THEN
    v_supplier := NULL;  -- 内部用户看全部
  ELSE
    v_supplier := public.supplier_id_of(v_uid);  -- 供应商账号只看自己
    IF v_supplier IS NULL THEN
      RAISE EXCEPTION '无权访问催货时间轴' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN QUERY
  WITH matched AS (
    SELECT DISTINCT c.item_unique_key
    FROM public.ops_chase_match_core() c
    WHERE c.category IN ('urge_supplier', 'late_order', 'in_transit', 'closed_short')
      AND coalesce(c.supplier_name, '') <> ''
  ),
  agg0 AS (
    SELECT (c.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date AS d_date,
           c.style_no AS s_no,
           c.match_qty AS s_qty,
           array_position(ARRAY['overdue','due24','due48','due72','later'], c.urgency) AS u_ord
    FROM public.ops_chase_match_core() c
    WHERE c.category = 'urge_supplier'
      AND (v_supplier IS NULL OR c.supplier_id = v_supplier)
      AND c.latest_ship_time IS NOT NULL
      AND c.latest_ship_time <= now() + interval '7 days'
    UNION ALL
    -- 供应商未匹配兜底(仅内部视图):按承诺发货时间直接归日
    SELECT (r.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date,
           coalesce(nullif(r.style_no, ''), nullif(r.sku_code, ''), '(无款号)'),
           r.qty,
           array_position(ARRAY['overdue','due24','due48','due72','later'],
             CASE
               WHEN r.latest_ship_time <= now() THEN 'overdue'
               WHEN r.latest_ship_time <= now() + interval '24 hours' THEN 'due24'
               WHEN r.latest_ship_time <= now() + interval '48 hours' THEN 'due48'
               WHEN r.latest_ship_time <= now() + interval '72 hours' THEN 'due72'
               ELSE 'later'
             END)
    FROM public.shipping_risk_orders r
    LEFT JOIN matched m ON m.item_unique_key = r.item_unique_key
    WHERE v_supplier IS NULL
      AND r.order_status IN ('Question', 'WaitConfirm')
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
  agg AS (
    SELECT a.d_date, a.s_no, sum(a.s_qty) AS s_qty, min(a.u_ord) AS u_ord
    FROM agg0 a
    GROUP BY 1, 2
  )
  SELECT a.d_date, a.s_no,
         coalesce(nullif(p.product_name, ''),
                  CASE WHEN p.name <> p.code THEN p.name END),
         coalesce(nullif(p.main_image_url, ''), nullif(p.external_image_url, '')),
         a.s_qty,
         (ARRAY['overdue','due24','due48','due72','later'])[a.u_ord]
  FROM agg a
  LEFT JOIN public.ops_products p ON p.code = a.s_no
  ORDER BY a.d_date ASC NULLS LAST, a.s_qty DESC, a.s_no;
END
$$;

COMMENT ON FUNCTION public.ops_chase_deadline_timeline() IS
  '催货时间轴(7 天窗口):urge_supplier 匹配结果 + 供应商未匹配兜底(仅内部,无采购单的缺货新款已移除),按(latest_ship_time 东八区日期 × 款号)聚合,urgency 取该组最高紧急档。供应商账号仍只见自己的 urge_supplier。';
