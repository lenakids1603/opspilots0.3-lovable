-- 商品主档同步支撑字段（jst-sync-products 增量同步）
-- 1) lead_time_days：交期（天），人工维护，同步永不写入；
-- 2) manual_fields：字段级来源标记——列在其中的字段视为人工维护，JST 同步不覆盖
--    （如 supplier_id / cost_price / name，含「劝退-原XX供应商」这类供应商标注所在字段）；
-- 3) jst_modified_at：聚水潭商品资料 modified 水位，增量同步据此跳过未变更行。

ALTER TABLE public.ops_products
  ADD COLUMN IF NOT EXISTS lead_time_days integer,
  ADD COLUMN IF NOT EXISTS manual_fields text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS jst_modified_at timestamptz;

ALTER TABLE public.ops_skus
  ADD COLUMN IF NOT EXISTS manual_fields text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS jst_modified_at timestamptz;

COMMENT ON COLUMN public.ops_products.lead_time_days IS '交期(天)，人工维护；JST 同步永不写此列';
COMMENT ON COLUMN public.ops_products.manual_fields IS '人工维护字段名列表；列在此处的字段 JST 同步不覆盖';
COMMENT ON COLUMN public.ops_products.jst_modified_at IS '聚水潭商品资料 modified（取该款下 SKU 的最大值）';
COMMENT ON COLUMN public.ops_skus.manual_fields IS '人工维护字段名列表；列在此处的字段 JST 同步不覆盖';
COMMENT ON COLUMN public.ops_skus.jst_modified_at IS '聚水潭商品资料 modified；增量同步据此跳过未变更行';
