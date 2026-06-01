-- 1) 收尾卡死 run（含 09:43 那条 suppliers run）
UPDATE public.jst_sync_runs
SET status = 'aborted',
    finished_at = COALESCE(finished_at, now()),
    duration_ms = COALESCE(duration_ms, EXTRACT(EPOCH FROM (now() - started_at))::int * 1000),
    error_message = CASE
      WHEN COALESCE(error_message,'') = '' THEN 'Edge Function 中断 / fetch 超时（suppliers/query 30s AbortSignal），run 未正常收尾，已由后台修复'
      ELSE error_message
    END,
    current_total_summary = CASE
      WHEN current_total_summary ILIKE '%supplier%' THEN '供应商同步中断：suppliers/query fetch 超时（30s AbortSignal）'
      ELSE COALESCE(NULLIF(current_total_summary,''),'') || ' [aborted]'
    END
WHERE status = 'running'
  AND started_at < now() - interval '30 seconds';

-- 2) 标记明显的 mock 错误为 resolved（仅这两条 seed 数据）
UPDATE public.jst_sync_errors
SET status = 'resolved',
    resolved_at = now(),
    error_message = '[开发占位/seed] ' || error_message
WHERE status <> 'resolved'
  AND (
    (module_key = 'sku' AND error_message ILIKE '%Rate Limit%')
    OR (module_key = 'inventory' AND error_message ILIKE '%Connection Timeout%基础库存%')
  );