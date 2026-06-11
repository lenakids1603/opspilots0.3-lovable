-- =============================================================================
-- 同步 upsert 增量条件优化 — 第 2 步:跳过未变更行的触发器(2026-06-11)
--
-- ⚠️ 必须在 20260611150000(补列)应用、且新版 edge functions 部署完成之后
--    再应用本迁移(部署顺序见 20260611150000 头部说明)。
--
-- 目的:聚水潭各同步函数重复 upsert 同一窗口时,"内容未变/更旧"的记录跳过实际
-- 写入(减少 WAL/死元组/autovacuum 压力)。PostgREST(supabase-js .upsert())无法
-- 表达 ON CONFLICT ... DO UPDATE ... WHERE,故用 BEFORE UPDATE 触发器等价实现:
-- 当传入行的 JST modified 不比库内已存值新时,RETURN NULL 取消该行 UPDATE。
--
-- 安全边界:
-- 1. 仅对 current_user = 'service_role'(同步函数写入)生效;authenticated(前端)、
--    postgres(迁移/人工修复)的 UPDATE 完全不受影响。
-- 2. 库内 modified 为 NULL 的旧数据、或传入 modified 为 NULL 时,不拦截。
-- 3. 守护列:即便 modified 未变,守护列变化仍放行(退款先于订单 modified 变化
--    到达时,订单 internal_order_type 重分类必须落库)。
-- 4. 跳过的行不出现在 upsert 的 RETURNING 里,同步函数已改为 maybeSingle + 回查。
--
-- 刻意排除的表:
-- * shipping_risk_orders / order_lookup_index:每次同步需刷新 remaining_hours /
--   expires_at 等时效字段,跳过会导致风险等级/过期清理失真。
-- * sales_*_summary 系列:由 RPC 重算,非 upsert 路径。
-- * purchase_orders 等采购表:供应商门户/内部确认流也经 service_role 写入且
--   不带 modified 变更,挂触发器会误拦业务更新。
-- 本迁移可重复执行。
-- =============================================================================

-- TG_ARGV[0] = modified 列名;TG_ARGV[1..] = 守护列名(任一变化则放行)
create or replace function public.jst_sync_skip_stale_update()
returns trigger
language plpgsql
as $$
declare
  old_j jsonb;
  new_j jsonb;
  old_mod timestamptz;
  new_mod timestamptz;
  i int;
begin
  -- 仅拦截同步写入(service_role);其他角色一律放行
  if current_user <> 'service_role' then
    return new;
  end if;
  old_j := to_jsonb(old);
  new_j := to_jsonb(new);
  old_mod := (old_j ->> tg_argv[0])::timestamptz;
  new_mod := (new_j ->> tg_argv[0])::timestamptz;
  -- 边界:任一侧 modified 为 NULL 时不拦截(旧数据必须仍能被更新)
  if old_mod is null or new_mod is null then
    return new;
  end if;
  if new_mod > old_mod then
    return new;
  end if;
  -- 守护列变化则放行(跨表派生字段,如退款联动的订单分类)
  for i in 1 .. tg_nargs - 1 loop
    if (old_j -> tg_argv[i]) is distinct from (new_j -> tg_argv[i]) then
      return new;
    end if;
  end loop;
  -- 内容未变/更旧:跳过本次 UPDATE(该行不出现在 RETURNING 中)
  return null;
end $$;

-- 销售订单:modified_time;守护 internal_order_type(退款可能先于订单 modified 到达)
drop trigger if exists trg_jst_sync_skip_stale on public.jst_sales_orders;
create trigger trg_jst_sync_skip_stale before update on public.jst_sales_orders
  for each row execute function public.jst_sync_skip_stale_update('modified_time', 'internal_order_type');

drop trigger if exists trg_jst_sync_skip_stale on public.sales_order_light_items;
create trigger trg_jst_sync_skip_stale before update on public.sales_order_light_items
  for each row execute function public.jst_sync_skip_stale_update('modified_time', 'internal_order_type');

drop trigger if exists trg_jst_sync_skip_stale on public.jst_sales_order_items;
create trigger trg_jst_sync_skip_stale before update on public.jst_sales_order_items
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

-- 出库(发货包裹)
drop trigger if exists trg_jst_sync_skip_stale on public.warehouse_shipping_packages;
create trigger trg_jst_sync_skip_stale before update on public.warehouse_shipping_packages
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

drop trigger if exists trg_jst_sync_skip_stale on public.warehouse_shipping_package_items;
create trigger trg_jst_sync_skip_stale before update on public.warehouse_shipping_package_items
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

-- 退货退款单
drop trigger if exists trg_jst_sync_skip_stale on public.jst_refund_orders;
create trigger trg_jst_sync_skip_stale before update on public.jst_refund_orders
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

drop trigger if exists trg_jst_sync_skip_stale on public.jst_refund_order_items;
create trigger trg_jst_sync_skip_stale before update on public.jst_refund_order_items
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

-- 售后收货单
drop trigger if exists trg_jst_sync_skip_stale on public.jst_aftersale_received_orders;
create trigger trg_jst_sync_skip_stale before update on public.jst_aftersale_received_orders
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');

drop trigger if exists trg_jst_sync_skip_stale on public.jst_aftersale_received_items;
create trigger trg_jst_sync_skip_stale before update on public.jst_aftersale_received_items
  for each row execute function public.jst_sync_skip_stale_update('modified_at_jst');
