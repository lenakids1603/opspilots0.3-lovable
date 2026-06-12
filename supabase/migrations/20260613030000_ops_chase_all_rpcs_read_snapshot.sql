-- 催货页全部 RPC 改读匹配快照 + 快照 5 分钟 pg_cron 兜底(2026-06-13)
--
-- 背景:timeline 改读快照后页面仍慢——打开速度取决于最慢接口。
-- supplier_list / urgency_summary / unmatched_list / purchase_list /
-- closed_short_list 每个仍现场算一遍 match_core(~1s+,并发叠加),
-- 整页合计远超 1 秒。老板定标准:整页所有接口合计 < 1 秒,全部改读快照。
--
-- 改法(照搬 timeline):
--   * FROM ops_chase_match_core() → FROM ops_chase_match_snapshot;
--   * 用到 urgency / overdue_days 的地方按 latest_ship_time / delivery_date
--     现算,消除快照档位漂移;category 用快照值(仅午夜日界漂移,可接受);
--   * 7 天过滤(supplier_list/urgency_summary/unmatched_list)与全时间范围
--     (purchase_list/closed_short_list)的口径维持 20260612230000 不变。
--
-- 新鲜度兑现:销售回补 tick 不走 ops_chase_refresh_risk_meta,实测快照 age
-- 曾到 16 分钟(>承诺 5 分钟)。加独立 pg_cron 每 5 分钟无条件重算
-- (advisory try-lock 防与 risk_meta 撞车;重算 ~2.5s/5min,负载 <1%),
-- 「数据截至」角标从此诚实;risk_meta 的节流刷新保留作即时性加成。
--
-- 本文件用 -- @@SPLIT@@ 注释分块,便于 Management API 分段执行。

-- @@SPLIT@@ ============ 1. 接口A:催供应商(读快照) ============
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
  WITH src AS (
    SELECT s.supplier_id AS sup_id, s.supplier_name AS sup_name, s.sku AS s_sku,
           s.style_no AS s_style, s.external_po_id AS s_po, s.delivery_date AS s_dd,
           s.match_qty AS s_qty,
           CASE WHEN s.delivery_date IS NOT NULL
                THEN greatest((now() AT TIME ZONE 'Asia/Shanghai')::date - (s.delivery_date AT TIME ZONE 'Asia/Shanghai')::date, 0)
                ELSE 0 END AS od,
           CASE
             WHEN s.latest_ship_time <= now() THEN 'overdue'
             WHEN s.latest_ship_time <= now() + interval '24 hours' THEN 'due24'
             WHEN s.latest_ship_time <= now() + interval '48 hours' THEN 'due48'
             WHEN s.latest_ship_time <= now() + interval '72 hours' THEN 'due72'
             ELSE 'later'
           END AS u
    FROM public.ops_chase_match_snapshot s
    WHERE s.category = 'urge_supplier'
      AND (v_supplier IS NULL OR s.supplier_id = v_supplier)
      AND s.latest_ship_time IS NOT NULL
      AND s.latest_ship_time <= now() + interval '7 days'
  ),
  per_po AS (
    SELECT c.sup_id, c.sup_name, c.s_sku, max(c.s_style) AS s_style,
           c.s_po, c.s_dd, max(c.od) AS overdue_days,
           sum(c.s_qty) AS qty,
           sum(c.s_qty) FILTER (WHERE c.u = 'overdue') AS q_overdue,
           sum(c.s_qty) FILTER (WHERE c.u = 'due24') AS q_due24,
           sum(c.s_qty) FILTER (WHERE c.u = 'due48') AS q_due48,
           sum(c.s_qty) FILTER (WHERE c.u = 'due72') AS q_due72,
           sum(c.s_qty) FILTER (WHERE c.u = 'later') AS q_later
    FROM src c
    GROUP BY c.sup_id, c.sup_name, c.s_sku, c.s_po, c.s_dd
  ),
  by_sku AS (
    SELECT p.sup_id AS r_supplier_id, p.sup_name AS r_supplier_name,
           p.s_sku AS r_sku, max(p.s_style) AS r_style_no,
           sum(p.qty) AS r_total,
           coalesce(sum(p.q_overdue), 0) AS r_overdue, coalesce(sum(p.q_due24), 0) AS r_due24,
           coalesce(sum(p.q_due48), 0) AS r_due48, coalesce(sum(p.q_due72), 0) AS r_due72,
           coalesce(sum(p.q_later), 0) AS r_later,
           count(DISTINCT p.s_po)::int AS r_po_count, max(p.overdue_days) AS r_max_overdue,
           jsonb_agg(jsonb_build_object(
             'po_id', p.s_po,
             'delivery_date', (p.s_dd AT TIME ZONE 'Asia/Shanghai')::date,
             'overdue_days', p.overdue_days,
             'qty', p.qty) ORDER BY p.s_dd) AS r_po_details
    FROM per_po p
    GROUP BY p.sup_id, p.sup_name, p.s_sku
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
  '催供应商清单(7 天窗口,读 ops_chase_match_snapshot 快照):urgency/overdue_days 按 latest_ship_time/delivery_date 现算。';

-- @@SPLIT@@ ============ 2. 接口D:紧急度汇总(读快照) ============
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
  WITH src AS (
    SELECT s.match_qty, s.o_id, s.supplier_id, s.supplier_name,
           CASE
             WHEN s.latest_ship_time <= now() THEN 'overdue'
             WHEN s.latest_ship_time <= now() + interval '24 hours' THEN 'due24'
             WHEN s.latest_ship_time <= now() + interval '48 hours' THEN 'due48'
             WHEN s.latest_ship_time <= now() + interval '72 hours' THEN 'due72'
             ELSE 'later'
           END AS u
    FROM public.ops_chase_match_snapshot s
    WHERE s.category = 'urge_supplier'
      AND s.latest_ship_time IS NOT NULL
      AND s.latest_ship_time <= now() + interval '7 days'
  ),
  agg AS (
    SELECT c.u, sum(c.match_qty) AS s_qty,
           count(DISTINCT c.o_id) AS s_orders,
           count(DISTINCT coalesce(c.supplier_id::text, c.supplier_name)) AS s_suppliers
    FROM src c
    GROUP BY c.u
  )
  SELECT b.u, coalesce(a.s_qty, 0), coalesce(a.s_orders, 0), coalesce(a.s_suppliers, 0)
  FROM unnest(ARRAY['overdue','due24','due48','due72','later']) WITH ORDINALITY b(u, ord)
  LEFT JOIN agg a ON a.u = b.u
  ORDER BY b.ord;
END
$$;

COMMENT ON FUNCTION public.ops_chase_urgency_summary() IS
  '催供应商紧急度五档汇总(7 天窗口,读快照,urgency 现算):later 即「72小时~7天」档。';

-- @@SPLIT@@ ============ 3. 接口G:供应商未匹配(matched 去重读快照) ============
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
  '催货兜底:供应商未匹配且【已逾期～未来7天】内的待发货需求(matched 去重读快照);无采购单缺货新款已移除,副本款保留。';

-- @@SPLIT@@ ============ 4. 接口B:催采购/采购缺口(读快照,全时间范围不变) ============
CREATE OR REPLACE FUNCTION public.ops_chase_purchase_list()
RETURNS TABLE (
  sku text, style_no text, supplier_name text,
  pending_qty numeric, intransit_qty numeric, missing_date_qty numeric,
  late_order_qty numeric, urge_supplier_qty numeric, closed_short_qty numeric,
  raw_gap numeric, return_in_transit numeric, resale_rate numeric,
  return_offset numeric, final_gap numeric, earliest_pay_time timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_rate numeric;
BEGIN
  IF NOT (public.has_ops_role(v_uid, 'admin'::public.ops_role_code)
       OR public.has_ops_role(v_uid, 'ops'::public.ops_role_code)) THEN
    RAISE EXCEPTION '仅限管理员/采购角色访问催采购清单' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(
    (SELECT p.param_value::numeric FROM public.ops_params p WHERE p.param_key = 'chase_resale_rate'),
    0.95) INTO v_rate;

  RETURN QUERY
  WITH core AS (
    SELECT * FROM public.ops_chase_match_snapshot
  ),
  by_sku AS (
    SELECT c.sku AS c_sku, max(c.style_no) AS c_style_no, max(c.supplier_name) AS c_supplier_name,
           sum(c.match_qty) AS pending_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'in_transit'), 0) AS intransit_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'in_transit' AND c.missing_delivery_date), 0) AS missing_date_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'late_order'), 0) AS late_order_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'urge_supplier'), 0) AS urge_supplier_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'closed_short'), 0) AS closed_short_qty,
           coalesce(sum(c.match_qty) FILTER (WHERE c.category = 'gap'), 0) AS raw_gap,
           min(c.pay_time) AS earliest_pay_time
    FROM core c
    GROUP BY c.sku
  ),
  ret AS (
    SELECT i.sku_id AS r_sku, sum(coalesce(i.qty, 0)) AS applied
    FROM public.jst_refund_order_items i
    JOIN public.jst_refund_orders ro ON ro.as_id = i.as_id
    WHERE coalesce(ro.status, '') <> 'Cancelled'
      AND coalesce(ro.type, '') LIKE '%退货%'
    GROUP BY 1
  ),
  rec AS (
    SELECT i.sku_id AS r_sku, sum(coalesce(i.qty, 0)) AS received
    FROM public.jst_aftersale_received_items i
    GROUP BY 1
  )
  SELECT b.c_sku, b.c_style_no, b.c_supplier_name,
         b.pending_qty, b.intransit_qty, b.missing_date_qty,
         b.late_order_qty, b.urge_supplier_qty, b.closed_short_qty, b.raw_gap,
         greatest(coalesce(r.applied, 0) - coalesce(rc.received, 0), 0) AS return_in_transit,
         v_rate,
         round(greatest(coalesce(r.applied, 0) - coalesce(rc.received, 0), 0) * v_rate, 2) AS return_offset,
         greatest(b.raw_gap + b.closed_short_qty - greatest(coalesce(r.applied, 0) - coalesce(rc.received, 0), 0) * v_rate, 0) AS final_gap,
         b.earliest_pay_time
  FROM by_sku b
  LEFT JOIN ret r ON r.r_sku = b.c_sku
  LEFT JOIN rec rc ON rc.r_sku = b.c_sku
  ORDER BY greatest(b.raw_gap + b.closed_short_qty - greatest(coalesce(r.applied, 0) - coalesce(rc.received, 0), 0) * v_rate, 0) DESC,
           b.raw_gap + b.closed_short_qty DESC, b.earliest_pay_time ASC;
END
$$;

COMMENT ON FUNCTION public.ops_chase_purchase_list() IS
  '催采购/采购缺口(读快照,全时间范围):缺口=未匹配待发+已结单少交-销退可复售冲抵。';

-- @@SPLIT@@ ============ 5. 接口E:厂家已结单少交(读快照,全时间范围不变) ============
CREATE OR REPLACE FUNCTION public.ops_chase_closed_short_list()
RETURNS TABLE (
  sku text, style_no text, supplier_name text,
  short_qty numeric, order_count bigint, po_count int,
  oldest_pay_time timestamptz, po_details jsonb
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
  WITH base AS (
    SELECT * FROM public.ops_chase_match_snapshot c WHERE c.category = 'closed_short'
  ),
  per_po AS (
    SELECT b.sku AS b_sku, b.external_po_id, b.delivery_date, sum(b.match_qty) AS qty
    FROM base b
    GROUP BY b.sku, b.external_po_id, b.delivery_date
  ),
  po_json AS (
    SELECT p.b_sku, count(*)::int AS po_count,
           jsonb_agg(jsonb_build_object(
             'po_id', p.external_po_id,
             'delivery_date', (p.delivery_date AT TIME ZONE 'Asia/Shanghai')::date,
             'short_qty', p.qty) ORDER BY p.delivery_date) AS po_details
    FROM per_po p
    GROUP BY p.b_sku
  ),
  per_sku AS (
    SELECT b.sku AS b_sku, max(b.style_no) AS style_no, max(b.supplier_name) AS supplier_name,
           sum(b.match_qty) AS short_qty, count(DISTINCT b.o_id) AS order_count,
           min(b.pay_time) AS oldest_pay_time
    FROM base b
    GROUP BY b.sku
  )
  SELECT s.b_sku, s.style_no, s.supplier_name, s.short_qty, s.order_count,
         pj.po_count, s.oldest_pay_time, pj.po_details
  FROM per_sku s
  JOIN po_json pj ON pj.b_sku = s.b_sku
  ORDER BY s.short_qty DESC, s.oldest_pay_time ASC;
END
$$;

COMMENT ON FUNCTION public.ops_chase_closed_short_list() IS
  '厂家已结单少交(读快照,全时间范围):Finished 采购单未收量按 FIFO 吃掉的需求,永久缺口,供补单决策。';

-- @@SPLIT@@ ============ 6. 快照 5 分钟 pg_cron 兜底 ============
-- 销售回补 tick 不经过 risk_meta,快照实测可陈旧 16 分钟;独立 cron 兜底,
-- 「数据截至」角标承诺 ≤5 分钟。advisory try-lock 防与 risk_meta 节流刷新撞车。
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ops_chase_match_snapshot_5min') THEN
    PERFORM cron.unschedule('ops_chase_match_snapshot_5min');
  END IF;
END
$do$;

SELECT cron.schedule(
  'ops_chase_match_snapshot_5min',
  '*/5 * * * *',
  'select public.ops_chase_refresh_match_snapshot()'
);
