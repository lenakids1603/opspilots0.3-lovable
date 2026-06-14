-- =============================================================================
-- 库存快照增量同步 · 每小时 cron（jst_inventory_hourly）
--
-- 沿用 public.invoke_jst_sync(fn, payload)：从 Vault 读 jst_sync_cron_secret，
--   net.http_post 带 x-cron-secret 打到函数 URL（与 销售/退款/出库/商品 cron 同一套）。
--
-- 窗口：滚动近 120 分钟（minutes:120），与小时调度刻意重叠留冗余（单次跑失也不漏）；
--   重叠由 (sku_code,wms_co_id) 唯一键 + jst_modified_at 水位（skip_stale）幂等去重，
--   物理行不翻倍。★ 不写死时间戳——每次触发都按「现在往前 120 分钟」滚动。
--   processPage 对 3 个仓各查一次（卓强/云仓秒回 0，近零成本；现仅主仓有货）。
--
-- pg_cron 使用 UTC；每小时一次。分钟取 :10（与其它 JST 同步唯一真正空闲的两个分钟
--   之一；另一为 :55）。现有占用：销售 */15(:00/:15/:30/:45)、出库 5-59/15(:05/:20/:35/:50)、
--   退款 :20、商品 :25、售后 :35、采购单/采购入库 :40/:50。
-- ★ 频率先别焊死：观察实际每窗流量后，如需更鲜可加 :55 做 2×/小时（minutes 同步下调）。
--
-- ⚠️ 部署顺序：本迁移须在「部署 jst-sync-inventory（--no-verify-jwt）+ 应用建表迁移
--   20260614120000_ops_sku_inventory.sql」之后再应用，否则首跑会打到缺函数/缺表。
-- 本迁移可重复执行（先 unschedule 同名任务再 schedule）。
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $cleanup$
begin
  if exists (select 1 from cron.job where jobname = 'jst_inventory_hourly') then
    perform cron.unschedule('jst_inventory_hourly');
  end if;
end
$cleanup$;

select cron.schedule(
  'jst_inventory_hourly',
  '10 * * * *',
  $job$ select public.invoke_jst_sync('jst-sync-inventory', '{"action":"start_inventory_job","minutes":120,"trigger_type":"cron"}'::jsonb) $job$
);
