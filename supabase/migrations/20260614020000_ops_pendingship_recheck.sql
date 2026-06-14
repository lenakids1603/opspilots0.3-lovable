-- 存量待发货复核:候选 keyset 分页 RPC + 支撑索引(2026-06-14,任务B)
--
-- 背景:库内 status∈(Question,WaitConfirm) 的订单,发货状态可能滞后于 JST——
-- 订单实际已发货/关闭/归档,但因掉出 modified 增量同步窗,本地一直停在待发货,
-- 持续挂在催货需求里(样本 o_id=19322047)。任务B 的复核同步取这些"陈旧待发货"
-- 订单,按 so_id 逐批向 JST 点查(orders/single/query,不带 modified 窗),用同一
-- 落库路径回写真实状态。
--
-- 本 RPC 仅供复核同步取候选:keyset 游标 (synced_at, jst_o_id) 严格前进,
-- 即便条件 upsert 触发器对"未变更仍待发货"的订单跳过写入(synced_at 不动),
-- 单次扫描内游标也不会回头重取(避免死循环)。回写后状态变更的订单 synced_at
-- 被刷新到 now() > cutoff,自然离开候选集。
--
-- 安全:SECURITY DEFINER 只读;REVOKE public/anon/authenticated,仅 service_role 可执行。

-- @@SPLIT@@ ============ 1. 候选支撑索引(待发货子集,小而快) ============
CREATE INDEX IF NOT EXISTS idx_jst_sales_orders_pending_recheck
  ON public.jst_sales_orders (synced_at, jst_o_id)
  WHERE status IN ('Question', 'WaitConfirm');

-- @@SPLIT@@ ============ 2. 候选 keyset 分页 RPC ============
CREATE OR REPLACE FUNCTION public.ops_pendingship_recheck_candidates(
  _cutoff timestamptz,
  _after_synced timestamptz DEFAULT NULL,
  _after_oid text DEFAULT NULL,
  _limit int DEFAULT 40
)
RETURNS TABLE (jst_o_id text, so_id text, synced_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.jst_o_id, o.so_id, o.synced_at
  FROM public.jst_sales_orders o
  WHERE o.status IN ('Question', 'WaitConfirm')
    AND o.synced_at < _cutoff
    AND (
      _after_synced IS NULL
      OR o.synced_at > _after_synced
      OR (o.synced_at = _after_synced AND o.jst_o_id > _after_oid)
    )
  ORDER BY o.synced_at ASC, o.jst_o_id ASC
  LIMIT greatest(1, least(coalesce(_limit, 40), 200))
$$;

COMMENT ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) IS
  '存量待发货复核取候选:status∈(Question,WaitConfirm) 且 synced_at<_cutoff,按 (synced_at,jst_o_id) keyset 游标分页升序返回。仅复核同步(service_role)调用。';

REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM anon;
REVOKE ALL ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ops_pendingship_recheck_candidates(timestamptz, timestamptz, text, int) TO service_role;
