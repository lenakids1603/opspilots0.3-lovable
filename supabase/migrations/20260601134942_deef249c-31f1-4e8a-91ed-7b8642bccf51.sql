
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS jst_shop_id text,
  ADD COLUMN IF NOT EXISTS platform_type text,
  ADD COLUMN IF NOT EXISTS auth_status text,
  ADD COLUMN IF NOT EXISTS shop_status_raw text,
  ADD COLUMN IF NOT EXISTS raw_jst_json jsonb,
  ADD COLUMN IF NOT EXISTS last_synced_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_ignored boolean NOT NULL DEFAULT false;

ALTER TABLE public.shops ALTER COLUMN entity_id DROP NOT NULL;
ALTER TABLE public.shops ALTER COLUMN platform_id DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shops_jst_shop_id_unique
  ON public.shops (jst_shop_id) WHERE jst_shop_id IS NOT NULL AND deleted_at IS NULL;

INSERT INTO public.platforms (code, name, status)
SELECT DISTINCT
  lower(regexp_replace(m.platform_type, '\s+', '_', 'g')),
  m.platform_type, 'active'
FROM public.jst_shop_mappings m
WHERE COALESCE(m.platform_type, '') <> ''
  AND NOT EXISTS (SELECT 1 FROM public.platforms p WHERE p.deleted_at IS NULL AND p.name = m.platform_type);

UPDATE public.shops s
SET jst_shop_id = m.jst_shop_id,
    platform_type = COALESCE(s.platform_type, m.platform_type),
    auth_status   = COALESCE(s.auth_status, m.auth_status),
    shop_status_raw = COALESCE(s.shop_status_raw, m.shop_status),
    raw_jst_json  = COALESCE(s.raw_jst_json, m.raw_json),
    last_synced_at = COALESCE(s.last_synced_at, m.last_sync_at),
    is_ignored = (m.mapping_status = 'ignored'),
    updated_at = now()
FROM public.jst_shop_mappings m
WHERE m.matched_shop_id = s.id AND s.deleted_at IS NULL AND s.jst_shop_id IS NULL;

INSERT INTO public.shops (
  jst_shop_id, name, platform_type, platform_id,
  entity_id, auth_status, shop_status_raw, raw_jst_json,
  last_synced_at, is_ignored, status
)
SELECT
  m.jst_shop_id,
  COALESCE(NULLIF(m.jst_shop_name, ''), '未命名店铺'),
  m.platform_type,
  (SELECT p.id FROM public.platforms p WHERE p.deleted_at IS NULL AND p.name = m.platform_type LIMIT 1),
  m.matched_business_entity_id,
  m.auth_status,
  m.shop_status,
  m.raw_json,
  m.last_sync_at,
  (m.mapping_status = 'ignored'),
  'active'
FROM public.jst_shop_mappings m
WHERE NOT EXISTS (
  SELECT 1 FROM public.shops s
  WHERE s.deleted_at IS NULL AND s.jst_shop_id = m.jst_shop_id
);
