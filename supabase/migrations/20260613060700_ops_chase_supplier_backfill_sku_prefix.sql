CREATE OR REPLACE FUNCTION public.ops_chase_refresh_risk_meta(_item_keys text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sku int; v_sup_sku int; v_sup_archive int; v_sup_po int; v_sup_prefix int; v_zombie int; v_excluded int;
  v_snap_at timestamptz; v_snap jsonb;
BEGIN
  UPDATE public.shipping_risk_orders r
  SET sku_code = l.sku_id
  FROM public.sales_order_light_items l
  WHERE l.item_unique_key = r.item_unique_key
    AND coalesce(r.sku_code, '') = '' AND coalesce(l.sku_id, '') <> ''
    AND (_item_keys IS NULL OR r.item_unique_key = ANY(_item_keys));
  GET DIAGNOSTICS v_sku = ROW_COUNT;

  -- 权威来源：按SKU查商品主档，主档有供应商则以主档为准（含纠正历史按款号误配的行）
  UPDATE public.shipping_risk_orders r
  SET supplier_name = m.supplier_name
  FROM (
    SELECT s.sku_code, coalesce(p.supplier_name_snapshot, sup.name) AS supplier_name
    FROM public.ops_skus s
    LEFT JOIN public.ops_products p ON p.id = s.product_id
    LEFT JOIN public.ops_suppliers sup ON sup.id = coalesce(s.supplier_id, p.supplier_id)
    WHERE coalesce(p.supplier_name_snapshot, sup.name) IS NOT NULL
  ) m
  WHERE r.sku_code = m.sku_code
    AND r.supplier_name IS DISTINCT FROM m.supplier_name
    AND (_item_keys IS NULL OR r.item_unique_key = ANY(_item_keys));
  GET DIAGNOSTICS v_sup_sku = ROW_COUNT;

  -- 兜底1：主档按款号（仅补空，SKU不在主档时才会走到这里）
  UPDATE public.shipping_risk_orders r
  SET supplier_name = m.supplier_name
  FROM (
    SELECT DISTINCT ON (p.style_no) p.style_no,
           coalesce(p.supplier_name_snapshot, s.name) AS supplier_name
    FROM public.ops_products p
    LEFT JOIN public.ops_suppliers s ON s.id = p.supplier_id
    WHERE coalesce(p.style_no, '') <> ''
      AND coalesce(p.supplier_name_snapshot, s.name) IS NOT NULL
    ORDER BY p.style_no, p.updated_at DESC
  ) m
  WHERE r.style_no = m.style_no AND coalesce(r.supplier_name, '') = ''
    AND (_item_keys IS NULL OR r.item_unique_key = ANY(_item_keys));
  GET DIAGNOSTICS v_sup_archive = ROW_COUNT;

  -- 兜底2：采购单按款号（仅补空）
  UPDATE public.shipping_risk_orders r
  SET supplier_name = m.supplier_name
  FROM (
    SELECT DISTINCT ON (poi.style_no) poi.style_no, po.supplier_name
    FROM public.purchase_order_items poi
    JOIN public.purchase_orders po ON po.id = poi.purchase_order_id
    WHERE coalesce(po.supplier_name, '') <> '' AND coalesce(poi.style_no, '') <> ''
      AND coalesce(po.status, '') <> 'Delete'
    ORDER BY poi.style_no, po.po_date DESC NULLS LAST
  ) m
  WHERE r.style_no = m.style_no AND coalesce(r.supplier_name, '') = ''
    AND (_item_keys IS NULL OR r.item_unique_key = ANY(_item_keys));
  GET DIAGNOSTICS v_sup_po = ROW_COUNT;

  -- 兜底3：SKU编码最长前缀=真款号(主档有供应商)。解决平台自动生成的垃圾款号导致
  -- SKU在主档挂到无供应商记录、查不到供应商的情况（仅补空，取最长/最具体的款号前缀，码长>=6，排除垃圾号）
  UPDATE public.shipping_risk_orders r
  SET supplier_name = m.supplier_name
  FROM (
    SELECT DISTINCT ON (e.item_unique_key) e.item_unique_key, s.sup AS supplier_name
    FROM public.shipping_risk_orders e
    JOIN (
      SELECT p.code, coalesce(p.supplier_name_snapshot, sup.name) AS sup
      FROM public.ops_products p
      LEFT JOIN public.ops_suppliers sup ON sup.id = p.supplier_id
      WHERE coalesce(p.supplier_name_snapshot, sup.name) IS NOT NULL
        AND p.code !~ '^\d{12,}' AND length(p.code) >= 6
    ) s ON e.sku_code LIKE s.code || '%'
    WHERE coalesce(e.supplier_name, '') = '' AND coalesce(e.sku_code, '') <> ''
      AND (_item_keys IS NULL OR e.item_unique_key = ANY(_item_keys))
    ORDER BY e.item_unique_key, length(s.code) DESC
  ) m
  WHERE r.item_unique_key = m.item_unique_key AND coalesce(r.supplier_name, '') = ''
    AND (_item_keys IS NULL OR r.item_unique_key = ANY(_item_keys));
  GET DIAGNOSTICS v_sup_prefix = ROW_COUNT;

  DELETE FROM public.shipping_risk_orders r
  WHERE r.order_status IN ('Split', 'Merged', 'Delivering');
  GET DIAGNOSTICS v_zombie = ROW_COUNT;

  -- scope=all 的排除款直接物理移除（与原逻辑一致）
  DELETE FROM public.shipping_risk_orders r
  USING public.ops_chase_excluded_styles e
  WHERE e.scope = 'all'
    AND (e.style_no IS NULL OR lower(e.style_no) = lower(coalesce(r.style_no, '')))
    AND (e.sku IS NULL OR e.sku = coalesce(r.sku_code, ''));
  GET DIAGNOSTICS v_excluded = ROW_COUNT;

  -- 快照5分钟内新鲜则跳过刷新（与原逻辑一致）
  v_snap_at := (SELECT max(s.refreshed_at) FROM public.ops_chase_match_snapshot s);
  IF v_snap_at IS NULL OR v_snap_at < now() - interval '5 minutes' THEN
    v_snap := public.ops_chase_refresh_match_snapshot();
  ELSE
    v_snap := jsonb_build_object('skipped', 'fresh', 'refreshed_at', v_snap_at);
  END IF;

  RETURN jsonb_build_object(
    'sku_backfilled', v_sku,
    'supplier_from_sku_master', v_sup_sku,
    'supplier_from_archive', v_sup_archive,
    'supplier_from_po', v_sup_po,
    'supplier_from_sku_prefix', v_sup_prefix,
    'zombies_removed', v_zombie,
    'excluded_removed', v_excluded,
    'match_snapshot', v_snap);
END
$function$
