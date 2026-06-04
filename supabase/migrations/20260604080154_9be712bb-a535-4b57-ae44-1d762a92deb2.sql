ALTER TABLE public.jst_sync_jobs ALTER COLUMN max_window_days TYPE numeric(8,3) USING max_window_days::numeric;
ALTER TABLE public.jst_sync_log_details ADD COLUMN IF NOT EXISTS error_type text;