-- Warehouse master data synced from JST (聚水潭)
CREATE TABLE public.jst_warehouses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  jst_wms_co_id text NOT NULL UNIQUE,
  name text NOT NULL DEFAULT '',
  type text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'active',
  remark text NOT NULL DEFAULT '',
  raw_jst_json jsonb,
  last_synced_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.jst_warehouses TO authenticated;
GRANT ALL ON public.jst_warehouses TO service_role;

ALTER TABLE public.jst_warehouses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "internal read jst_warehouses"
  ON public.jst_warehouses FOR SELECT
  TO authenticated
  USING (public.is_ops_internal(auth.uid()));

CREATE POLICY "admin write jst_warehouses"
  ON public.jst_warehouses FOR ALL
  TO authenticated
  USING (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code))
  WITH CHECK (public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code));

CREATE INDEX idx_jst_warehouses_status ON public.jst_warehouses(status);