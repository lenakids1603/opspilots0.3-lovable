
ALTER TABLE public.jst_outbound_order_items
  ADD COLUMN IF NOT EXISTS item_unique_key text;

UPDATE public.jst_outbound_order_items
SET item_unique_key = io_id || '|' || COALESCE(ioi_id,'') || '|' || COALESCE(sku_id,'') || '|' || COALESCE(oi_id,'')
WHERE item_unique_key IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS jst_outbound_order_items_unique_key_idx
  ON public.jst_outbound_order_items (item_unique_key);
