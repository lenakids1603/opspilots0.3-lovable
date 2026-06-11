-- 催货匹配口径修正 + 紧急度分桶（2026-06-11，老板确认口径）
--
-- 背景：聚水潭订单拍下后的初始状态就是 Question（待仓库审核），不是客服异常单，
-- 而是主力待发货需求。原口径需求侧排除了 Question，导致催货清单只统计
-- WaitConfirm（约 1.7 千单），漏掉约 2 万单真实需求。
--
-- 变更内容：
--   1) ops_chase_match_core 需求侧改为 order_status IN ('Question','WaitConfirm')
--      （Split/Merged/Delivering 仍由 ops_chase_refresh_risk_meta 核销，不进入表）；
--      新增 urgency 紧急度列，基于 shipping_risk_orders.latest_ship_time
--      （对顾客承诺的最晚发货时间）距当前时刻：
--        overdue 已超时 / due24 24小时内 / due48 24-48h / due72 48-72h / later 更晚
--      （latest_ship_time 为空的行归入 later；当前生产/staging 均无空值）。
--   2) ops_chase_supplier_list：overdue_qty 含义改为"顾客承诺已超时件数"，
--      新增 due24_qty / due48_qty / due72_qty / later_qty，total_qty 为该行总件数
--      （= 原 overdue_qty 的口径）。排序改为先按已超时件数降序。
--   3) 新增 ops_chase_urgency_summary()：催供应商（urge_supplier）口径下
--      各紧急度档的件数/订单数/涉及供应商数，固定返回 5 行，供页面顶部卡片。
--   4) ops_chase_question_count 语义重定义为"待审核订单数"（Question=拍单初始
--      状态，待仓库审核），返回列改名 pending_review_orders/items/qty。
--
-- 调研备注（生产 raw_data 实测）：JST 订单报文带 question_type / question_desc，
-- Question 单中约 95% question_type='缺货'（即等货中），其余为 修改订单/特殊单/
-- 催发特急/用户已申请退款/线上锁定 等少量真异常。后续同步可把这两个字段落库，
-- 用于区分"等货中"和"真异常"。本迁移不改同步。
--
-- 本文件用 -- @@SPLIT@@ 注释分块，便于 Management API 分段执行（请求体≤4KB）。

-- @@SPLIT@@ ============ 1. FIFO 匹配核心：需求口径 + urgency ============
DROP FUNCTION IF EXISTS public.ops_chase_match_core();

CREATE FUNCTION public.ops_chase_match_core()
RETURNS TABLE (
  sku text, style_no text, category text, match_qty numeric,
  external_po_id text, supplier_id uuid, supplier_name text,
  delivery_date timestamptz, overdue_days int, missing_delivery_date boolean,
  item_unique_key text, o_id text, pay_time timestamptz, latest_ship_time timestamptz,
  urgency text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH demand AS (
  SELECT r.item_unique_key, r.o_id, r.sku_code AS sku, r.style_no,
         r.qty::numeric AS qty,
         coalesce(r.pay_time, r.order_created_at, r.created_at) AS pay_time,
         r.latest_ship_time,
         sum(r.qty::numeric) OVER (
           PARTITION BY r.sku_code
           ORDER BY coalesce(r.pay_time, r.order_created_at, r.created_at), r.item_unique_key
         ) AS d_end
  FROM public.shipping_risk_orders r
  WHERE r.order_status IN ('Question', 'WaitConfirm')
    AND coalesce(r.qty, 0) > 0
    AND coalesce(r.sku_code, '') <> ''
),
supply AS (
  SELECT poi.sku_no AS sku, po.external_po_id, po.supplier_id, po.supplier_name,
         poi.delivery_date,
         greatest(coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0), 0)::numeric AS remaining,
         sum(greatest(coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0), 0)::numeric) OVER (
           PARTITION BY poi.sku_no
           ORDER BY poi.delivery_date ASC NULLS LAST, poi.id
         ) AS s_end
  FROM public.purchase_order_items poi
  JOIN public.purchase_orders po ON po.id = poi.purchase_order_id
  WHERE coalesce(po.status, '') NOT IN ('Delete', 'Cancelled')
    AND coalesce(poi.sku_no, '') <> ''
    AND coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0) > 0
),
matched AS (
  SELECT d.sku, d.style_no, d.item_unique_key, d.o_id, d.pay_time, d.latest_ship_time,
         s.external_po_id, s.supplier_id, s.supplier_name, s.delivery_date,
         least(d.d_end, s.s_end) - greatest(d.d_end - d.qty, s.s_end - s.remaining) AS match_qty
  FROM demand d
  JOIN supply s ON s.sku = d.sku
  WHERE least(d.d_end, s.s_end) > greatest(d.d_end - d.qty, s.s_end - s.remaining)
),
unioned AS (
  SELECT m.sku, m.style_no,
    CASE
      WHEN m.delivery_date IS NULL THEN 'in_transit'
      WHEN m.latest_ship_time IS NOT NULL AND m.delivery_date > m.latest_ship_time THEN 'late_order'
      WHEN (m.delivery_date AT TIME ZONE 'Asia/Shanghai')::date < (now() AT TIME ZONE 'Asia/Shanghai')::date THEN 'urge_supplier'
      ELSE 'in_transit'
    END AS category,
    m.match_qty, m.external_po_id, m.supplier_id, m.supplier_name, m.delivery_date,
    CASE WHEN m.delivery_date IS NOT NULL
         THEN greatest((now() AT TIME ZONE 'Asia/Shanghai')::date - (m.delivery_date AT TIME ZONE 'Asia/Shanghai')::date, 0)
         ELSE 0 END AS overdue_days,
    (m.delivery_date IS NULL) AS missing_delivery_date,
    m.item_unique_key, m.o_id, m.pay_time, m.latest_ship_time
  FROM matched m
  UNION ALL
  SELECT d.sku, d.style_no, 'gap', d.qty - coalesce(mm.mq, 0),
         NULL, NULL, NULL, NULL, 0, false,
         d.item_unique_key, d.o_id, d.pay_time, d.latest_ship_time
  FROM demand d
  LEFT JOIN (SELECT m2.item_unique_key, sum(m2.match_qty) AS mq FROM matched m2 GROUP BY 1) mm
    USING (item_unique_key)
  WHERE d.qty - coalesce(mm.mq, 0) > 0
)
SELECT u.*,
  CASE
    WHEN u.latest_ship_time IS NULL THEN 'later'
    WHEN u.latest_ship_time <= now() THEN 'overdue'
    WHEN u.latest_ship_time <= now() + interval '24 hours' THEN 'due24'
    WHEN u.latest_ship_time <= now() + interval '48 hours' THEN 'due48'
    WHEN u.latest_ship_time <= now() + interval '72 hours' THEN 'due72'
    ELSE 'later'
  END AS urgency
FROM unioned u
$$;

REVOKE ALL ON FUNCTION public.ops_chase_match_core() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_match_core() FROM anon;
REVOKE ALL ON FUNCTION public.ops_chase_match_core() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_match_core() TO service_role;

-- @@SPLIT@@ ============ 2. 接口A：催供应商（urgency 分桶列） ============
DROP FUNCTION IF EXISTS public.ops_chase_supplier_list();

CREATE FUNCTION public.ops_chase_supplier_list()
RETURNS TABLE (
  supplier_id uuid, supplier_name text, sku text, style_no text,
  total_qty numeric, overdue_qty numeric, due24_qty numeric,
  due48_qty numeric, due72_qty numeric, later_qty numeric,
  po_count int, max_overdue_days int, po_details jsonb
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
    GROUP BY c.supplier_id, c.supplier_name, c.sku, c.external_po_id, c.delivery_date
  )
  SELECT p.supplier_id, p.supplier_name, p.sku, max(p.style_no),
         sum(p.qty),
         coalesce(sum(p.q_overdue), 0), coalesce(sum(p.q_due24), 0),
         coalesce(sum(p.q_due48), 0), coalesce(sum(p.q_due72), 0),
         coalesce(sum(p.q_later), 0),
         count(DISTINCT p.external_po_id)::int, max(p.overdue_days),
         jsonb_agg(jsonb_build_object(
           'po_id', p.external_po_id,
           'delivery_date', (p.delivery_date AT TIME ZONE 'Asia/Shanghai')::date,
           'overdue_days', p.overdue_days,
           'qty', p.qty) ORDER BY p.delivery_date)
  FROM per_po p
  GROUP BY p.supplier_id, p.supplier_name, p.sku
  ORDER BY coalesce(sum(p.q_overdue), 0) DESC, max(p.overdue_days) DESC, sum(p.qty) DESC;
END
$$;

REVOKE ALL ON FUNCTION public.ops_chase_supplier_list() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_supplier_list() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_supplier_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_supplier_list() TO service_role;

-- @@SPLIT@@ ============ 3. 接口D：紧急度汇总（页面顶部卡片） ============
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
    GROUP BY c.urgency
  )
  SELECT b.u, coalesce(a.s_qty, 0), coalesce(a.s_orders, 0), coalesce(a.s_suppliers, 0)
  FROM unnest(ARRAY['overdue','due24','due48','due72','later']) WITH ORDINALITY b(u, ord)
  LEFT JOIN agg a ON a.u = b.u
  ORDER BY b.ord;
END
$$;

REVOKE ALL ON FUNCTION public.ops_chase_urgency_summary() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_urgency_summary() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_urgency_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_urgency_summary() TO service_role;

-- @@SPLIT@@ ============ 4. 接口C：重定义为"待审核订单数" ============
DROP FUNCTION IF EXISTS public.ops_chase_question_count();

CREATE FUNCTION public.ops_chase_question_count()
RETURNS TABLE (pending_review_orders bigint, pending_review_items bigint, pending_review_qty numeric)
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
  SELECT count(DISTINCT r.o_id), count(*), coalesce(sum(r.qty), 0)
  FROM public.shipping_risk_orders r
  WHERE r.order_status = 'Question';
END
$$;

COMMENT ON FUNCTION public.ops_chase_question_count() IS
  'Question=拍单初始状态（待仓库审核），非客服异常单。返回待审核订单数/行数/件数；原"问题单计数"语义作废。';

REVOKE ALL ON FUNCTION public.ops_chase_question_count() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_question_count() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_question_count() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_question_count() TO service_role;
