-- 早期销售汇总回补(2026-01-01 ~ 2026-02-28)落表 + 幂等工作表(2026-06-12)
--
-- 背景:1-2 月订单只需店铺×日汇总(拍下口径),明细即拉即弃,不进
-- jst_sales_orders / sales_order_light_items。
--
-- 设计:
--   * platform_daily_summary:店铺×日 唯一键的最终汇总表。独立于
--     sales_daily_summary —— 后者由 refresh_sales_summaries_for_order_items
--     按 light 明细重算,若把 aggregate 行写进去,未来任何 1-2 月旧单被增量
--     同步触达时,该日×店铺会被"仅含 1 单"的重算结果覆盖掉。
--   * sales_backfill_order_agg:订单粒度瘦工作表(只有头表金额,无 SKU 明细),
--     o_id 主键 —— 同步引擎的窗口拆分/瞬时重试/边界重叠都只会对同一 o_id
--     重复 upsert 相同值,绝对幂等。汇总 = 对工作表按日重算,而非增量累加。
--     验收通过后此表可整表删除(删除前需用户确认)。
--   * 拍下口径:order_count/ordered_amount 含全部状态(含发货前取消、含未付款);
--     cancelled_* 为其中 status=Cancelled 的子集;paid_amount 为实付。
--     与聚水潭销售主题分析对账时若有口径差(合并/拆分单),以 5 月明细回补
--     的对账结论统一解释。

CREATE TABLE IF NOT EXISTS public.platform_daily_summary (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  summary_date date NOT NULL,
  shop_id text NOT NULL DEFAULT '',
  shop_name text,
  order_count int NOT NULL DEFAULT 0,
  ordered_amount numeric NOT NULL DEFAULT 0,
  paid_amount numeric NOT NULL DEFAULT 0,
  cancelled_order_count int NOT NULL DEFAULT 0,
  cancelled_amount numeric NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'backfill_aggregate',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (summary_date, shop_id)
);

CREATE INDEX IF NOT EXISTS idx_platform_daily_summary_date ON public.platform_daily_summary(summary_date);

CREATE TABLE IF NOT EXISTS public.sales_backfill_order_agg (
  o_id text PRIMARY KEY,
  summary_date date NOT NULL,
  shop_id text NOT NULL DEFAULT '',
  shop_name text,
  status text,
  ordered_amount numeric NOT NULL DEFAULT 0,
  paid_amount numeric NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  synced_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_backfill_order_agg_date ON public.sales_backfill_order_agg(summary_date);

ALTER TABLE public.platform_daily_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_backfill_order_agg ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.platform_daily_summary TO authenticated;
GRANT ALL ON public.platform_daily_summary TO service_role;
GRANT ALL ON public.sales_backfill_order_agg TO service_role;

DROP POLICY IF EXISTS "internal read platform_daily_summary" ON public.platform_daily_summary;
CREATE POLICY "internal read platform_daily_summary" ON public.platform_daily_summary
  FOR SELECT TO authenticated USING (public.is_ops_internal((SELECT auth.uid())));

-- 按日期范围从工作表重算汇总(全删全建该范围,幂等)
CREATE OR REPLACE FUNCTION public.sales_backfill_recompute_daily(_from date, _to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_rows int;
BEGIN
  DELETE FROM public.platform_daily_summary
  WHERE summary_date >= _from AND summary_date <= _to AND source = 'backfill_aggregate';

  INSERT INTO public.platform_daily_summary (
    summary_date, shop_id, shop_name, order_count, ordered_amount, paid_amount,
    cancelled_order_count, cancelled_amount, source, updated_at
  )
  SELECT
    w.summary_date,
    coalesce(w.shop_id, ''),
    max(w.shop_name),
    count(*)::int,
    coalesce(sum(w.ordered_amount), 0),
    coalesce(sum(w.paid_amount), 0),
    count(*) FILTER (WHERE w.is_cancelled)::int,
    coalesce(sum(w.ordered_amount) FILTER (WHERE w.is_cancelled), 0),
    'backfill_aggregate',
    now()
  FROM public.sales_backfill_order_agg w
  WHERE w.summary_date >= _from AND w.summary_date <= _to
  GROUP BY w.summary_date, coalesce(w.shop_id, '');
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('from', _from, 'to', _to, 'summary_rows', v_rows);
END
$fn$;

REVOKE ALL ON FUNCTION public.sales_backfill_recompute_daily(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sales_backfill_recompute_daily(date, date) FROM anon;
REVOKE ALL ON FUNCTION public.sales_backfill_recompute_daily(date, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.sales_backfill_recompute_daily(date, date) TO service_role;
