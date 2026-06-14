-- 存量待发货复核改「按发货紧急度优先」(2026-06-14)
--
-- 问题:ops_pendingship_recheck_candidates 原按 synced_at 升序(最久未同步优先)取候选,
-- 但催货页是按发货截止「最紧急/已逾期」展示。结果用户盯着的逾期单(如 o_id=19322047)
-- 排在 ~3.1万队列很后面,要好几天才轮到,催货页一直虚挂。
--
-- 改法:候选排序改「发货紧急度升序」——
--   * eff_ship = 该订单在 shipping_risk_orders 里所有明细的 min(latest_ship_time)
--     (最紧急的项驱动整单优先级);不在 risk 表(即不在催货页)的订单 eff_ship= 远未来哨兵
--     '9999-12-31'(排最后;用有限哨兵而非 'infinity',保证 keyset 游标经 JSON 往返无歧义);
--   * ORDER BY eff_ship ASC, jst_o_id ASC —— 已逾期最先,可见页面的单先清;
--   * keyset 游标键从 (synced_at,o_id) 改为 (eff_ship,o_id),参数 _after_synced→_after_ship;
--     edge function tick 循环同步改传 curShip(见 jst-sync-sales-orders)。
--   * 仍保留 synced_at<_cutoff(默认8h)门槛;调用量不变(同一 cron、同样单量,只换顺序)。
-- 索引:依赖既有 idx_jst_sales_orders_pending_recheck(待发货子集 synced_at/o_id 过滤)
--   + idx_shipping_risk_orders_o_id(LATERAL min 取数),均已存在,无需新建。
--
-- 签名(第2参改名)与返回列(增 eff_ship)都变,OR REPLACE 改不了,先 DROP 再 CREATE。
-- 仅复核同步(service_role)调用,DROP 期间无并发依赖。

DROP FUNCTION IF EXISTS public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int);

CREATE FUNCTION public.ops_pendingship_recheck_candidates(
  _cutoff timestamptz,
  _after_ship timestamptz DEFAULT NULL,
  _after_oid text DEFAULT NULL,
  _limit int DEFAULT 40
)
RETURNS TABLE (jst_o_id text, so_id text, synced_at timestamptz, eff_ship timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.jst_o_id, o.so_id, o.synced_at, c.eff_ship
  FROM public.jst_sales_orders o
  CROSS JOIN LATERAL (
    SELECT coalesce(min(r.latest_ship_time), '9999-12-31 00:00:00+00'::timestamptz) AS eff_ship
    FROM public.shipping_risk_orders r
    WHERE r.o_id = o.jst_o_id
  ) c
  WHERE o.status IN ('Question', 'WaitConfirm')
    AND o.synced_at < _cutoff
    AND (
      _after_ship IS NULL
      OR c.eff_ship > _after_ship
      OR (c.eff_ship = _after_ship AND o.jst_o_id > _after_oid)
    )
  ORDER BY c.eff_ship ASC, o.jst_o_id ASC
  LIMIT greatest(1, least(coalesce(_limit, 40), 200))
$$;

COMMENT ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) IS
  '存量待发货复核取候选(按发货紧急度优先):status∈(Question,WaitConfirm) 且 synced_at<_cutoff;eff_ship=min(shipping_risk_orders.latest_ship_time)(不在风险表→哨兵 9999-12-31 排最后);按 (eff_ship,jst_o_id) keyset 游标升序分页(已逾期最先)。仅复核同步(service_role)调用。';

REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM anon;
REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) TO service_role;
