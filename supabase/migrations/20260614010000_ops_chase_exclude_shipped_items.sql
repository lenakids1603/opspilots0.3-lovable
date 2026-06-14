-- 催货页降噪:已发货明细从催货需求中剔除(2026-06-14,任务A)
--
-- 背景:催货需求来源 = shipping_risk_orders 中 status ∈ (Question, WaitConfirm)。
-- 但库内订单发货状态可能滞后(掉出 modified 增量窗、归档等),实际已发货的订单
-- 仍挂在催货需求里。出库活表 warehouse_shipping_packages(15min 同步)能查到这些
-- 发货明细,据此在「需求侧」按"项"(o_id + sku_code)剔除已发货明细。
--
-- 按"项"而非按"单"剔除:套装单部分发货时,已发的项剔除、未发的项保留,
-- 不会因为一单里有任一项发货就整单隐藏(避免漏催未发的项)。
--
-- 边界:只改读 shipping_risk_orders「需求侧」的 4 个直读函数;
--   match_core 是 FIFO 匹配源,供应商清单/紧急度汇总/催采购缺口/已结单少交/
--   催货全景/时间轴(urge_supplier 分支)均读 ops_chase_match_snapshot 快照,
--   经 match_core → 快照自动继承本次剔除(快照每 5 分钟 cron 重算 + 同步节流刷新)。
--   直读 shipping_risk_orders 的另 3 个:question_count(待审核计数)、
--   unmatched_list(供应商未匹配)、deadline_timeline(时间轴未匹配兜底分支),
--   单独补同一剔除谓词。
--
-- 谓词内联 NOT EXISTS(集合化反连接),不抽函数,避免每行 SPI 调用拖慢扫描。
-- 函数体由生产库 pg_get_functiondef 原样取出,仅在需求侧追加剔除谓词,其余不动。
-- 本文件用 -- @@SPLIT@@ 注释分块,便于 Management API 分段执行。

-- @@SPLIT@@ ============ 1. FIFO 匹配核心:需求侧剔除已发货明细 ============
CREATE OR REPLACE FUNCTION public.ops_chase_match_core()
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
    AND NOT EXISTS (
      SELECT 1 FROM public.ops_chase_excluded_styles e
      WHERE e.scope IN ('chase', 'all')
        AND (e.style_no IS NULL OR lower(e.style_no) = lower(coalesce(r.style_no, '')))
        AND (e.sku IS NULL OR e.sku = coalesce(r.sku_code, ''))
    )
    -- 已发货剔除(按项 o_id+sku_code;套装单未发的项仍保留)
    AND NOT EXISTS (
      SELECT 1 FROM public.warehouse_shipping_package_items wi
      WHERE wi.o_id = r.o_id AND wi.sku_code = r.sku_code
    )
),
supply AS (
  SELECT poi.sku_no AS sku, po.external_po_id, po.supplier_id, po.supplier_name,
         poi.delivery_date, po.status AS po_status,
         greatest(coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0), 0)::numeric AS remaining,
         sum(greatest(coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0), 0)::numeric) OVER (
           PARTITION BY poi.sku_no
           ORDER BY (po.status = 'Finished'), poi.delivery_date ASC NULLS LAST, poi.id
         ) AS s_end
  FROM public.purchase_order_items poi
  JOIN public.purchase_orders po ON po.id = poi.purchase_order_id
  WHERE po.status IN ('Confirmed', 'Finished')
    AND coalesce(poi.sku_no, '') <> ''
    AND coalesce(poi.purchase_qty, 0) - coalesce(poi.received_qty, 0) > 0
),
matched AS (
  SELECT d.sku, d.style_no, d.item_unique_key, d.o_id, d.pay_time, d.latest_ship_time,
         s.external_po_id, s.supplier_id, s.supplier_name, s.delivery_date, s.po_status,
         least(d.d_end, s.s_end) - greatest(d.d_end - d.qty, s.s_end - s.remaining) AS match_qty
  FROM demand d
  JOIN supply s ON s.sku = d.sku
  WHERE least(d.d_end, s.s_end) > greatest(d.d_end - d.qty, s.s_end - s.remaining)
),
unioned AS (
  SELECT m.sku, m.style_no,
    CASE
      WHEN m.po_status = 'Finished' THEN 'closed_short'
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

-- @@SPLIT@@ ============ 2. 待审核计数:剔除已发货明细 ============
CREATE OR REPLACE FUNCTION public.ops_chase_question_count()
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
  WHERE r.order_status = 'Question'
    AND NOT EXISTS (
      SELECT 1 FROM public.ops_chase_excluded_styles e
      WHERE e.scope IN ('chase', 'all')
        AND (e.style_no IS NULL OR lower(e.style_no) = lower(coalesce(r.style_no, '')))
        AND (e.sku IS NULL OR e.sku = coalesce(r.sku_code, ''))
    )
    -- 已发货剔除(按项 o_id+sku_code)
    AND NOT EXISTS (
      SELECT 1 FROM public.warehouse_shipping_package_items wi
      WHERE wi.o_id = r.o_id AND wi.sku_code = r.sku_code
    );
END
$$;

-- @@SPLIT@@ ============ 3. 供应商未匹配:base 剔除已发货明细 ============
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
    RAISE EXCEPTION '仅内部人员可访问' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH qt AS MATERIALIZED (
    SELECT q.sku AS q_sku FROM public.ops_chase_quantui_skus() q
  ),
  matched AS MATERIALIZED (
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
      AND NOT EXISTS (SELECT 1 FROM qt WHERE qt.q_sku = r.sku_code)
      AND NOT EXISTS (
        SELECT 1 FROM public.ops_chase_excluded_styles e
        WHERE e.scope IN ('chase', 'all')
          AND (e.style_no IS NULL OR lower(e.style_no) = lower(coalesce(r.style_no, '')))
          AND (e.sku IS NULL OR e.sku = coalesce(r.sku_code, ''))
      )
      -- 已发货剔除(按项 o_id+sku_code)
      AND NOT EXISTS (
        SELECT 1 FROM public.warehouse_shipping_package_items wi
        WHERE wi.o_id = r.o_id AND wi.sku_code = r.sku_code
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
    -- 款式图兜底:先按款号找,再按该款下任一SKU找
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

-- @@SPLIT@@ ============ 4. 时间轴:未匹配兜底分支剔除已发货明细 ============
-- urge_supplier 分支读快照(经 match_core 已继承剔除),仅改兜底直读分支。
CREATE OR REPLACE FUNCTION public.ops_chase_deadline_timeline()
RETURNS TABLE (
  deadline_date date, style_no text, product_name text, image_url text,
  qty numeric, urgency text, snapshot_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_supplier uuid;
  v_snap_at timestamptz;
BEGIN
  IF public.is_ops_internal(v_uid) THEN
    v_supplier := NULL;  -- 内部用户看全部
  ELSE
    v_supplier := public.supplier_id_of(v_uid);  -- 供应商账号只看自己
    IF v_supplier IS NULL THEN
      RAISE EXCEPTION '无权访问催货时间轴' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_snap_at := (SELECT max(s.refreshed_at) FROM public.ops_chase_match_snapshot s);

  RETURN QUERY
  WITH matched AS MATERIALIZED (
    SELECT DISTINCT s.item_unique_key
    FROM public.ops_chase_match_snapshot s
    WHERE s.category IN ('urge_supplier', 'late_order', 'in_transit', 'closed_short')
      AND coalesce(s.supplier_name, '') <> ''
  ),
  agg0 AS (
    -- 可催分支:读快照;urgency 按 latest_ship_time 现算,消除快照档位漂移
    SELECT (s.latest_ship_time AT TIME ZONE 'Asia/Shanghai')::date AS d_date,
           s.style_no AS s_no,
           s.match_qty AS s_qty,
           array_position(ARRAY['overdue','due24','due48','due72','later'],
             CASE
               WHEN s.latest_ship_time <= now() THEN 'overdue'
               WHEN s.latest_ship_time <= now() + interval '24 hours' THEN 'due24'
               WHEN s.latest_ship_time <= now() + interval '48 hours' THEN 'due48'
               WHEN s.latest_ship_time <= now() + interval '72 hours' THEN 'due72'
               ELSE 'later'
             END) AS u_ord
    FROM public.ops_chase_match_snapshot s
    WHERE s.category = 'urge_supplier'
      AND (v_supplier IS NULL OR s.supplier_id = v_supplier)
      AND s.latest_ship_time IS NOT NULL
      AND s.latest_ship_time <= now() + interval '7 days'
    UNION ALL
    -- 供应商未匹配兜底(仅内部视图):保持现场查(单遍,代价小)
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
      -- 已发货剔除(按项 o_id+sku_code)
      AND NOT EXISTS (
        SELECT 1 FROM public.warehouse_shipping_package_items wi
        WHERE wi.o_id = r.o_id AND wi.sku_code = r.sku_code
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
         (ARRAY['overdue','due24','due48','due72','later'])[a.u_ord],
         v_snap_at
  FROM agg a
  LEFT JOIN public.ops_products p ON p.code = a.s_no
  ORDER BY a.d_date ASC NULLS LAST, a.s_qty DESC, a.s_no;
END
$$;

-- @@SPLIT@@ ============ 5. 立即重刷匹配快照(让聚合侧立刻继承剔除) ============
SELECT public.ops_chase_refresh_match_snapshot();
