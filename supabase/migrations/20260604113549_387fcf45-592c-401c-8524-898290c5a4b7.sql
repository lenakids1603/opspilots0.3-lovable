-- 1) Drop partial unique indexes
DROP INDEX IF EXISTS public.jst_aftersale_received_orders_unique_key_idx;
DROP INDEX IF EXISTS public.jst_aftersale_received_items_unique_key_idx;

-- 2) Backfill nulls/empties using id as fallback
UPDATE public.jst_aftersale_received_orders
SET received_unique_key = id::text
WHERE received_unique_key IS NULL OR btrim(received_unique_key) = '';

UPDATE public.jst_aftersale_received_items
SET item_unique_key = id::text
WHERE item_unique_key IS NULL OR btrim(item_unique_key) = '';

-- 3) De-duplicate any rows that now collide before adding the unique index
DELETE FROM public.jst_aftersale_received_items a
USING public.jst_aftersale_received_items b
WHERE a.ctid < b.ctid
  AND a.item_unique_key = b.item_unique_key;

DELETE FROM public.jst_aftersale_received_orders a
USING public.jst_aftersale_received_orders b
WHERE a.ctid < b.ctid
  AND a.received_unique_key = b.received_unique_key;

-- 4) NOT NULL
ALTER TABLE public.jst_aftersale_received_orders
  ALTER COLUMN received_unique_key SET NOT NULL;
ALTER TABLE public.jst_aftersale_received_items
  ALTER COLUMN item_unique_key SET NOT NULL;

-- 5) Full (non-partial) unique indexes for onConflict
CREATE UNIQUE INDEX IF NOT EXISTS jst_aftersale_received_orders_unique_key_idx
  ON public.jst_aftersale_received_orders(received_unique_key);

CREATE UNIQUE INDEX IF NOT EXISTS jst_aftersale_received_items_unique_key_idx
  ON public.jst_aftersale_received_items(item_unique_key);