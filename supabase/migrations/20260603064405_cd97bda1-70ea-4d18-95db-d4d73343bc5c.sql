-- 1. 新增 item_unique_key 字段
ALTER TABLE public.jst_refund_order_items
  ADD COLUMN IF NOT EXISTS item_unique_key text;

-- 2. 回填已有数据
UPDATE public.jst_refund_order_items
SET item_unique_key =
  COALESCE(as_id, '') || '|' ||
  COALESCE(asi_id, '') || '|' ||
  COALESCE(sku_id, '') || '|' ||
  COALESCE(outer_oi_id, '') || '|' ||
  COALESCE(type, '')
WHERE item_unique_key IS NULL;

-- 3. 创建唯一索引（非 partial，便于 ON CONFLICT 匹配；NULL 行不会被索引）
CREATE UNIQUE INDEX IF NOT EXISTS jst_refund_order_items_item_unique_key_idx
  ON public.jst_refund_order_items(item_unique_key);

-- 4. 主表 as_id 已有 unique 约束 (jst_refund_orders_as_id_key)，无需变更