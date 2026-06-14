-- 归档 legacy 出库表 jst_outbound_orders / jst_outbound_order_items
--
-- 背景：
--   现行出库/发货数据自 2026-06-04 起改由 jst-sync-outbound-orders 写入
--   warehouse_shipping_packages(+_items)（cron jst_outbound_orders_15min，每 15 分钟）。
--   旧的 public.jst_outbound_orders / jst_outbound_order_items 自 2026-06-04 后已无任何写入，
--   且经核查（pg_proc.prosrc 词边界匹配 / pg_views / pg_matviews / pg_trigger）数据库内
--   无任何函数、视图、触发器引用这两张表；前端不直接查询；
--   唯一的代码引用是 edge function ops-product-master-derive 的 outbound 来源分支，
--   该分支已在本次同步提交中移除（见 supabase/functions/ops-product-master-derive/index.ts）。
--
--   ⚠️ 部署顺序：必须先部署 ops-product-master-derive（去掉 outbound 分支），再执行本迁移，
--   否则两者之间的窗口内 derive 调用会因表被改名而报错。
--
-- 处理：重命名为 zz_archived_* 前缀（可逆、保留数据/索引/RLS/外键），而非删除。
--   如需回滚：把 zz_archived_jst_outbound_order_items / zz_archived_jst_outbound_orders
--   分别改名回 jst_outbound_order_items / jst_outbound_orders 即可。
--   保留期复核后如确认无用，可再行 DROP（届时连同 FK 一并删除）。
--
-- 幂等：全部用 to_regclass 守卫，源不存在或目标已存在时跳过，可安全重复执行 / 双环境执行。

-- @@SPLIT@@ 1. 先改子表（含 FK -> 父表，FK 按 OID 关联，改名不影响约束有效性）
do $$
begin
  if to_regclass('public.jst_outbound_order_items') is not null
     and to_regclass('public.zz_archived_jst_outbound_order_items') is null then
    alter table public.jst_outbound_order_items rename to zz_archived_jst_outbound_order_items;
  end if;
end $$;

-- @@SPLIT@@ 2. 再改父表
do $$
begin
  if to_regclass('public.jst_outbound_orders') is not null
     and to_regclass('public.zz_archived_jst_outbound_orders') is null then
    alter table public.jst_outbound_orders rename to zz_archived_jst_outbound_orders;
  end if;
end $$;

-- @@SPLIT@@ 3. 归档说明注释（守卫：表存在才写）
do $$
begin
  if to_regclass('public.zz_archived_jst_outbound_orders') is not null then
    execute $c$comment on table public.zz_archived_jst_outbound_orders is
      'ARCHIVED 2026-06-14：legacy 出库主表，2026-06-04 后无写入，已被 warehouse_shipping_packages 取代；无任何 DB 引用，ops-product-master-derive 的 outbound 分支已移除。可逆：改名回 jst_outbound_orders。保留期复核后可 DROP。'$c$;
  end if;
  if to_regclass('public.zz_archived_jst_outbound_order_items') is not null then
    execute $c$comment on table public.zz_archived_jst_outbound_order_items is
      'ARCHIVED 2026-06-14：legacy 出库明细表，2026-06-04 后无写入，已被 warehouse_shipping_package_items 取代。可逆：改名回 jst_outbound_order_items。保留期复核后可 DROP。'$c$;
  end if;
end $$;
