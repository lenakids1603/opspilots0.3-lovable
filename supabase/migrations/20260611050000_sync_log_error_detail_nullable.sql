-- jst_sync_log_details.error_detail 改为可空。
-- 背景：jst-sync-job.ts 成功页写日志明细时 error_detail 传 null（成功页本就无错误），
-- 与 NOT NULL 约束冲突；insert 被 try/catch 吞掉，但约束违反持续刷 Postgres 错误日志
-- （生产 2026-06-11 每隔几秒一次）。成功页 error_detail 为 null 是正确语义，故放开约束。

ALTER TABLE public.jst_sync_log_details
  ALTER COLUMN error_detail DROP NOT NULL;
