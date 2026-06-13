-- 催货页 7 天待发货全景:按供应状态统计 7 天内 / 已逾期 的件数与单数
--
-- 背景:催货页头部原「7 天内共 174 件」只统计 urge_supplier 一类,严重低估真实
-- 待发货盘子(实测 7 天内 ≈ 17,277 件、已过发货截止 ≈ 906 件)。新增
-- ops_chase_demand_overview() 按 category 各返回一行,供前端头部主数字
-- (SUM(qty_7d))、红色逾期数(SUM(qty_overdue))与五状态分解使用,数值一律实时取自
-- 本函数,不在前端写死。
--
-- 口径:读 ops_chase_match_snapshot 快照(独立 pg_cron 5 分钟兜底刷新);
-- 7 天窗口 = latest_ship_time <= now() + 7d;逾期 = latest_ship_time <= now()。
-- category 五类:in_transit(货在路上)/gap(无采购单)/late_order(会迟到)/
-- closed_short(厂家少交)/urge_supplier(催供应商)。
--
-- 本函数已由 Claude 在 staging 先行 + 生产部署完毕(两库一致);本迁移文件仅补登记
-- 到 git,保持迁移历史完整、与线上对象一致。权限:authenticated 可执行、anon 已
-- REVOKE、函数体内 is_ops_internal 二次校验。

CREATE OR REPLACE FUNCTION public.ops_chase_demand_overview()
RETURNS TABLE(
  category text, qty_7d numeric, orders_7d bigint,
  qty_overdue numeric, orders_overdue bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_ops_internal(auth.uid()) THEN
    RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT s.category,
    coalesce(sum(s.match_qty) FILTER (WHERE s.latest_ship_time <= now() + interval '7 days'),0),
    count(DISTINCT s.o_id) FILTER (WHERE s.latest_ship_time <= now() + interval '7 days'),
    coalesce(sum(s.match_qty) FILTER (WHERE s.latest_ship_time <= now()),0),
    count(DISTINCT s.o_id) FILTER (WHERE s.latest_ship_time <= now())
  FROM public.ops_chase_match_snapshot s
  WHERE s.latest_ship_time IS NOT NULL
    AND s.latest_ship_time <= now() + interval '7 days'
  GROUP BY s.category;
END
$function$;
REVOKE ALL ON FUNCTION public.ops_chase_demand_overview() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ops_chase_demand_overview() FROM anon;
GRANT EXECUTE ON FUNCTION public.ops_chase_demand_overview() TO authenticated;
