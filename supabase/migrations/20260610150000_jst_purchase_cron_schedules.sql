-- 聚水潭同步自动调度（第三批）：采购单 / 采购入库单
--  两者共用同一个 Edge Function（jst-sync-purchase-orders），以 action 区分：
--    start_po_job      → 采购单   (purchase.query,  落 purchase_orders / purchase_order_items)
--    start_inbound_job → 采购入库 (purchasein.query, 落 purchase_receipts / purchase_receipt_items)
--  走断点续跑 job 协议（jst_sync_jobs）：trigger_type=cron 时函数自动开启 auto_continue，
--  由后端自调用驱动 tick 直至完成；存在活跃任务时复用续跑，不会堆积。
--  幂等：external_po_id / external_poi_id / external_io_id / external_ioi_id 唯一键 upsert，
--  重复同步同一窗口不会产生重复数据。
--  调度间隔 1 小时、同步窗口 3 小时（minutes=180），窗口重叠靠 upsert 去重。
--  执行分钟错开现有任务（:20 退款、:35 售后），采购单 :40、采购入库 :50。
--  依赖：public.invoke_jst_sync（见 20260610064400_jst_sync_cron_schedules.sql），
--       Vault 密钥 jst_sync_cron_secret 已配置。
--  ★ 函数 URL 由 invoke_jst_sync 决定，当前指向 staging；生产上线时替换该函数中的项目 Ref。

do $cleanup$
begin
  if exists (select 1 from cron.job where jobname = 'jst_purchase_orders_hourly') then
    perform cron.unschedule('jst_purchase_orders_hourly');
  end if;
  if exists (select 1 from cron.job where jobname = 'jst_purchase_inbound_hourly') then
    perform cron.unschedule('jst_purchase_inbound_hourly');
  end if;
end
$cleanup$;

select cron.schedule(
  'jst_purchase_orders_hourly',
  '40 * * * *',
  $job$ select public.invoke_jst_sync('jst-sync-purchase-orders', '{"action": "start_po_job", "minutes": 180, "trigger_type": "cron"}'::jsonb) $job$
);

select cron.schedule(
  'jst_purchase_inbound_hourly',
  '50 * * * *',
  $job$ select public.invoke_jst_sync('jst-sync-purchase-orders', '{"action": "start_inbound_job", "minutes": 180, "trigger_type": "cron"}'::jsonb) $job$
);
