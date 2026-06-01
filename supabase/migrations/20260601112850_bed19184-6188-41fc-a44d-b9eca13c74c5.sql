ALTER TABLE public.ops_suppliers
  ADD COLUMN IF NOT EXISTS manual_contact_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS manual_contact_phone text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS manual_address text NOT NULL DEFAULT '';