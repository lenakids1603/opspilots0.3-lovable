-- 催货页时间轴/供应商列表:口径从「只数 urge_supplier」放宽为「真实要催的盘子」
--
-- 真实要催 = 在路上吃紧(缓冲≤p_buffer_days,默认3) + 会迟到(late_order) + 供应商已逾期
-- (urge_supplier);排除 在路上宽裕(安全)、无采购单(gap→采购缺口)、劝退(quantui)。
-- 实测时间轴(实时浮动):已逾期311·24h198·48h232·72h1,590·7天8,366·合计10,697。
--
-- 两个函数同步升级(均新增可选参 p_buffer_days,签名变化故先 DROP 旧版再建):
--   * ops_chase_urgency_summary:五档汇总改读上述放宽口径(排除 quantui),供时间轴五档直读;
--   * ops_chase_supplier_list:同口径,且新增 min_buffer_days(剩余缓冲,负=晚到)与
--     po_details.buffer_days;排序改 已逾期优先(max_overdue_days DESC)、其次缓冲最紧
--     (min_buffer ASC NULLS FIRST)。
--
-- 本函数已由 Claude 在 staging 先行 + 生产部署完毕(两库一致);本迁移文件仅补登记到 git。
-- 权限:authenticated 可执行、anon 已 REVOKE、函数体内 is_ops_internal 二次校验。

DROP FUNCTION IF EXISTS public.ops_chase_urgency_summary();
CREATE OR REPLACE FUNCTION public.ops_chase_urgency_summary(p_buffer_days integer DEFAULT 3)
RETURNS TABLE(urgency text, qty numeric, order_count bigint, supplier_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_ops_internal(auth.uid()) THEN
    RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH qt AS MATERIALIZED (SELECT q.sku AS q_sku FROM public.ops_chase_quantui_skus() q),
  src AS (
    SELECT s.match_qty, s.o_id, s.supplier_id, s.supplier_name,
      CASE WHEN s.latest_ship_time <= now() THEN 'overdue'
           WHEN s.latest_ship_time <= now()+interval '24 hours' THEN 'due24'
           WHEN s.latest_ship_time <= now()+interval '48 hours' THEN 'due48'
           WHEN s.latest_ship_time <= now()+interval '72 hours' THEN 'due72'
           ELSE 'later' END AS u
    FROM public.ops_chase_match_snapshot s
    WHERE (s.category IN ('urge_supplier','late_order')
        OR (s.category='in_transit' AND (s.delivery_date IS NULL
            OR ((s.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date
                - (s.delivery_date AT TIME ZONE 'Asia/Shanghai')::date) <= p_buffer_days)))
      AND s.latest_ship_time IS NOT NULL
      AND s.latest_ship_time <= now()+interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM qt WHERE qt.q_sku = s.sku)
  ),
  agg AS (SELECT c.u, sum(c.match_qty) s_qty, count(DISTINCT c.o_id) s_orders,
            count(DISTINCT coalesce(c.supplier_id::text,c.supplier_name)) s_suppliers
          FROM src c GROUP BY c.u)
  SELECT b.u, coalesce(a.s_qty,0), coalesce(a.s_orders,0), coalesce(a.s_suppliers,0)
  FROM unnest(ARRAY['overdue','due24','due48','due72','later']) WITH ORDINALITY b(u,ord)
  LEFT JOIN agg a ON a.u=b.u ORDER BY b.ord;
END $function$;
REVOKE ALL ON FUNCTION public.ops_chase_urgency_summary(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ops_chase_urgency_summary(integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_urgency_summary(integer) TO authenticated;

DROP FUNCTION IF EXISTS public.ops_chase_supplier_list();
CREATE OR REPLACE FUNCTION public.ops_chase_supplier_list(p_buffer_days integer DEFAULT 3)
RETURNS TABLE(supplier_id uuid, supplier_name text, sku text, style_no text, total_qty numeric,
  overdue_qty numeric, due24_qty numeric, due48_qty numeric, due72_qty numeric, later_qty numeric,
  po_count integer, max_overdue_days integer, min_buffer_days integer, po_details jsonb,
  product_name text, image_url text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_supplier uuid;
BEGIN
  IF public.is_ops_internal(v_uid) THEN v_supplier := NULL;
  ELSE v_supplier := public.supplier_id_of(v_uid);
    IF v_supplier IS NULL THEN RAISE EXCEPTION '无权访问催货列表' USING ERRCODE='42501'; END IF;
  END IF;
  RETURN QUERY
  WITH qt AS MATERIALIZED (SELECT q.sku AS q_sku FROM public.ops_chase_quantui_skus() q),
  src AS (
    SELECT s.supplier_id sup_id, s.supplier_name sup_name, s.sku s_sku, s.style_no s_style,
      s.external_po_id s_po, s.delivery_date s_dd, s.match_qty s_qty,
      CASE WHEN s.delivery_date IS NOT NULL THEN greatest((now() AT TIME ZONE 'Asia/Shanghai')::date
           - (s.delivery_date AT TIME ZONE 'Asia/Shanghai')::date,0) ELSE 0 END AS od,
      CASE WHEN s.delivery_date IS NOT NULL THEN ((s.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date
           - (s.delivery_date AT TIME ZONE 'Asia/Shanghai')::date) ELSE NULL END AS buf,
      CASE WHEN s.latest_ship_time <= now() THEN 'overdue'
           WHEN s.latest_ship_time <= now()+interval '24 hours' THEN 'due24'
           WHEN s.latest_ship_time <= now()+interval '48 hours' THEN 'due48'
           WHEN s.latest_ship_time <= now()+interval '72 hours' THEN 'due72'
           ELSE 'later' END AS u
    FROM public.ops_chase_match_snapshot s
    WHERE (s.category IN ('urge_supplier','late_order')
        OR (s.category='in_transit' AND (s.delivery_date IS NULL
            OR ((s.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date
                - (s.delivery_date AT TIME ZONE 'Asia/Shanghai')::date) <= p_buffer_days)))
      AND (v_supplier IS NULL OR s.supplier_id = v_supplier)
      AND s.latest_ship_time IS NOT NULL
      AND s.latest_ship_time <= now()+interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM qt WHERE qt.q_sku = s.sku)
  ),
  per_po AS (
    SELECT c.sup_id, c.sup_name, c.s_sku, max(c.s_style) s_style, c.s_po, c.s_dd,
      max(c.od) overdue_days, min(c.buf) buffer_days, sum(c.s_qty) qty,
      sum(c.s_qty) FILTER (WHERE c.u='overdue') q_overdue,
      sum(c.s_qty) FILTER (WHERE c.u='due24') q_due24,
      sum(c.s_qty) FILTER (WHERE c.u='due48') q_due48,
      sum(c.s_qty) FILTER (WHERE c.u='due72') q_due72,
      sum(c.s_qty) FILTER (WHERE c.u='later') q_later
    FROM src c GROUP BY c.sup_id, c.sup_name, c.s_sku, c.s_po, c.s_dd
  ),
  by_sku AS (
    SELECT p.sup_id r_supplier_id, p.sup_name r_supplier_name, p.s_sku r_sku,
      max(p.s_style) r_style_no, sum(p.qty) r_total,
      coalesce(sum(p.q_overdue),0) r_overdue, coalesce(sum(p.q_due24),0) r_due24,
      coalesce(sum(p.q_due48),0) r_due48, coalesce(sum(p.q_due72),0) r_due72,
      coalesce(sum(p.q_later),0) r_later, count(DISTINCT p.s_po)::int r_po_count,
      max(p.overdue_days) r_max_overdue, min(p.buffer_days) r_min_buffer,
      jsonb_agg(jsonb_build_object('po_id',p.s_po,
        'delivery_date',(p.s_dd AT TIME ZONE 'Asia/Shanghai')::date,
        'overdue_days',p.overdue_days,'buffer_days',p.buffer_days,'qty',p.qty)
        ORDER BY p.s_dd) r_po_details
    FROM per_po p GROUP BY p.sup_id, p.sup_name, p.s_sku
  )
  SELECT b.r_supplier_id, b.r_supplier_name, b.r_sku, b.r_style_no, b.r_total,
    b.r_overdue, b.r_due24, b.r_due48, b.r_due72, b.r_later, b.r_po_count,
    b.r_max_overdue, b.r_min_buffer, b.r_po_details,
    coalesce(nullif(pr.product_name,''), CASE WHEN pr.name<>pr.code THEN pr.name END),
    coalesce(nullif(pr.main_image_url,''), nullif(pr.external_image_url,''))
  FROM by_sku b LEFT JOIN public.ops_products pr ON pr.code=b.r_style_no
  ORDER BY b.r_max_overdue DESC, b.r_min_buffer ASC NULLS FIRST, b.r_total DESC;
END $function$;
REVOKE ALL ON FUNCTION public.ops_chase_supplier_list(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ops_chase_supplier_list(integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_supplier_list(integer) TO authenticated;
