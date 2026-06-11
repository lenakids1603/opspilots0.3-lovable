-- 催货时间轴供数 + 款名款图透传（2026-06-12）
--
-- 变更内容：
--   1) 新增 ops_chase_deadline_timeline()：基于 urge_supplier 匹配结果，
--      按 (latest_ship_time 东八区日期, style_no) 聚合，返回
--      deadline_date / style_no / product_name / image_url / qty / urgency
--      （该天该款的最高紧急档，overdue > due24 > due48 > due72 > later）。
--      product_name / image_url 取自 ops_products（键 code=款号；图片优先
--      main_image_url，兜底 external_image_url），取不到返回 NULL。
--      权限口径与 ops_chase_supplier_list 一致：内部用户看全部，
--      供应商账号只看自己（supplier_id 过滤），其余拒绝。
--   2) ops_chase_supplier_list 末尾追加 product_name / image_url 两列
--      （不改现有列序），款式卡片直接用，前端少拼一次图。
--
-- 本文件用 -- @@SPLIT@@ 注释分块，便于 Management API 分段执行（请求体≤4KB）。

-- @@SPLIT@@ ============ 1. 接口A：催供应商（末尾追加款名/款图） ============
DROP FUNCTION IF EXISTS public.ops_chase_supplier_list();

CREATE FUNCTION public.ops_chase_supplier_list()
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

REVOKE ALL ON FUNCTION public.ops_chase_supplier_list() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_supplier_list() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_supplier_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_supplier_list() TO service_role;

-- @@SPLIT@@ ============ 2. 接口F：催货时间轴（按承诺发货日 × 款号） ============
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
  WITH agg AS (
    SELECT (c.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date AS d_date,
           c.style_no AS s_no,
           sum(c.match_qty) AS s_qty,
           min(array_position(ARRAY['overdue','due24','due48','due72','later'], c.urgency)) AS u_ord
    FROM public.ops_chase_match_core() c
    WHERE c.category = 'urge_supplier'
      AND (v_supplier IS NULL OR c.supplier_id = v_supplier)
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
  '催货时间轴：urge_supplier 匹配结果按（latest_ship_time 东八区日期 × 款号）聚合，urgency 取该组最高紧急档；款名/款图取自 ops_products（code=款号），取不到为 NULL。权限同 ops_chase_supplier_list。';

REVOKE ALL ON FUNCTION public.ops_chase_deadline_timeline() FROM public;
REVOKE ALL ON FUNCTION public.ops_chase_deadline_timeline() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_deadline_timeline() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ops_chase_deadline_timeline() TO service_role;
