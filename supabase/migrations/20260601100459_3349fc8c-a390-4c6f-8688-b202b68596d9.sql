CREATE TABLE IF NOT EXISTS public.jst_suppliers_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  jst_supplier_id text NOT NULL UNIQUE,
  supplier_name text NOT NULL DEFAULT '',
  supplier_code text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT '',
  raw_json jsonb,
  last_sync_at timestamptz,
  matched_ops_supplier_id uuid,
  skip_reason text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.jst_suppliers_raw TO authenticated;
GRANT ALL ON public.jst_suppliers_raw TO service_role;

ALTER TABLE public.jst_suppliers_raw ENABLE ROW LEVEL SECURITY;

CREATE POLICY "internal read jst_suppliers_raw" ON public.jst_suppliers_raw
  FOR SELECT TO authenticated USING (is_ops_internal(auth.uid()));

CREATE POLICY "admin write jst_suppliers_raw" ON public.jst_suppliers_raw
  FOR ALL TO authenticated
  USING (has_ops_role(auth.uid(), 'admin'::ops_role_code))
  WITH CHECK (has_ops_role(auth.uid(), 'admin'::ops_role_code));

CREATE INDEX IF NOT EXISTS idx_jst_suppliers_raw_code ON public.jst_suppliers_raw(supplier_code);
CREATE INDEX IF NOT EXISTS idx_jst_suppliers_raw_name ON public.jst_suppliers_raw(supplier_name);