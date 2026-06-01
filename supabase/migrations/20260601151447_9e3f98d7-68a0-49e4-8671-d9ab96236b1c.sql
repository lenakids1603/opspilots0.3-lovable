UPDATE public.jst_sync_runs
SET status = 'cancelled',
    finished_at = COALESCE(finished_at, now()),
    error_message = CASE WHEN error_message = '' THEN '开发占位记录，未调用聚水潭 API' ELSE error_message END,
    current_total_summary = '[占位] ' || current_total_summary
WHERE (current_total_summary ILIKE '%尚未接入%' OR current_total_summary ILIKE '%未真正调用%')
  AND status IN ('running','aborted');