-- 存量待发货复核 cron:每 2 小时(避开北京 19:00–24:00 高峰)(2026-06-14,任务B)
--
-- 调度 jst-sync-sales-orders 的 start_pendingship_recheck:取库内
-- status∈(Question,WaitConfirm) 且 synced_at < now()-8h 的订单,按 so_id 点查 JST 回写
-- 真实状态,把掉出 modified 增量窗的已发货/关闭/取消单从催货需求里清掉(根因修复)。
--
-- 高峰避让(双保险):
--   1) cron 调度表本身避开北京 19:00–24:00 = UTC 11:00–16:00(只在 UTC
--      0,2,4,6,8,10,16,18,20,22 整点 :10 触发);
--   2) 函数 start 处对 trigger_type='cron' 再判一次高峰直接跳过,运行中进入高峰也暂停。
-- :10 触发避开 :00/:15/:20/:25/:35/:40/:50 等既有同步与 */5 快照高频点。
-- 复用守卫:函数内若已有 running 复核链(心跳<5min)则直接复用,避免并发双链。
-- 存量(约 2.6 万)随前几次 off-peak 触发逐链清完,之后保持新鲜;对 JST 限频温和
-- (每批点查 20 单,点查节奏被同一落库路径自然拉开)。

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'jst_pendingship_recheck_2h') THEN
    PERFORM cron.unschedule('jst_pendingship_recheck_2h');
  END IF;
END
$do$;

SELECT cron.schedule(
  'jst_pendingship_recheck_2h',
  '10 0,2,4,6,8,10,16,18,20,22 * * *',
  $$select public.invoke_jst_sync('jst-sync-sales-orders', '{"action":"start_pendingship_recheck","hours":8,"trigger_type":"cron"}'::jsonb)$$
);
