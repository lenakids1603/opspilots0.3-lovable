-- Lightweight outbound package statistics.
-- This migration is intended for dev/staging validation first. It does not
-- copy, delete, or clean any historical jst_outbound_* data.

CREATE TABLE IF NOT EXISTS public.warehouse_shipping_packages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  package_unique_key text NOT NULL UNIQUE,
  io_id text NOT NULL,
  so_id text,
  o_id text,
  shop_id text,
  shop_name text,
  wh_id text,
  warehouse_name text,
  send_date timestamptz,
  logistics_company text,
  tracking_number text,
  weight numeric,
  shipping_method text,
  status text,
  modified_at_jst timestamptz,
  synced_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.warehouse_shipping_package_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_unique_key text NOT NULL UNIQUE,
  package_id uuid NOT NULL REFERENCES public.warehouse_shipping_packages(id) ON DELETE CASCADE,
  package_unique_key text NOT NULL,
  io_id text NOT NULL,
  so_id text,
  o_id text,
  sku_id text,
  sku_code text,
  style_no text,
  product_name text,
  qty numeric NOT NULL DEFAULT 0,
  synced_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_send_date
  ON public.warehouse_shipping_packages(send_date DESC);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_shop_date
  ON public.warehouse_shipping_packages(shop_id, send_date DESC);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_wh_date
  ON public.warehouse_shipping_packages(wh_id, send_date DESC);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_logistics_date
  ON public.warehouse_shipping_packages(logistics_company, send_date DESC);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_tracking
  ON public.warehouse_shipping_packages(tracking_number);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_packages_modified
  ON public.warehouse_shipping_packages(modified_at_jst DESC);

CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_package_items_package
  ON public.warehouse_shipping_package_items(package_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_package_items_io_id
  ON public.warehouse_shipping_package_items(io_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_package_items_sku
  ON public.warehouse_shipping_package_items(sku_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_package_items_sku_code
  ON public.warehouse_shipping_package_items(sku_code);
CREATE INDEX IF NOT EXISTS idx_warehouse_shipping_package_items_style
  ON public.warehouse_shipping_package_items(style_no);

GRANT SELECT ON public.warehouse_shipping_packages TO authenticated;
GRANT SELECT ON public.warehouse_shipping_package_items TO authenticated;
GRANT ALL ON public.warehouse_shipping_packages TO service_role;
GRANT ALL ON public.warehouse_shipping_package_items TO service_role;

ALTER TABLE public.warehouse_shipping_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouse_shipping_package_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "internal read warehouse_shipping_packages" ON public.warehouse_shipping_packages;
CREATE POLICY "internal read warehouse_shipping_packages"
  ON public.warehouse_shipping_packages
  FOR SELECT TO authenticated
  USING (public.is_ops_internal(auth.uid()));

DROP POLICY IF EXISTS "internal read warehouse_shipping_package_items" ON public.warehouse_shipping_package_items;
CREATE POLICY "internal read warehouse_shipping_package_items"
  ON public.warehouse_shipping_package_items
  FOR SELECT TO authenticated
  USING (public.is_ops_internal(auth.uid()));

DROP POLICY IF EXISTS "admin write warehouse_shipping_packages" ON public.warehouse_shipping_packages;
CREATE POLICY "admin write warehouse_shipping_packages"
  ON public.warehouse_shipping_packages
  FOR ALL TO authenticated
  USING (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code))
  WITH CHECK (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code));

DROP POLICY IF EXISTS "admin write warehouse_shipping_package_items" ON public.warehouse_shipping_package_items;
CREATE POLICY "admin write warehouse_shipping_package_items"
  ON public.warehouse_shipping_package_items
  FOR ALL TO authenticated
  USING (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code))
  WITH CHECK (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code));
