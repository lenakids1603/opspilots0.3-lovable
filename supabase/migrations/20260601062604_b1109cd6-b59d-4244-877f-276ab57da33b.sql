-- ============================================================
-- Batch 1: 补全外键 + 修类型 + 给 purchase items 加内部商品映射
-- 不改 RLS/GRANT；所有目标表当前 0 行
-- 幂等：所有约束/列均有存在性检查
-- ============================================================

-- 1. profiles.supplier_id → ops_suppliers(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'profiles_supplier_id_fkey') THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_supplier_id_fkey
      FOREIGN KEY (supplier_id) REFERENCES public.ops_suppliers(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_profiles_supplier_id ON public.profiles(supplier_id);

-- 2. ops_user_roles.user_id → auth.users(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_user_roles_user_id_fkey') THEN
    ALTER TABLE public.ops_user_roles
      ADD CONSTRAINT ops_user_roles_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id)
      ON UPDATE CASCADE ON DELETE CASCADE;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_user_roles_user_id ON public.ops_user_roles(user_id);

-- 3. ops_user_roles.role_code → ops_roles(code)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_user_roles_role_code_fkey') THEN
    ALTER TABLE public.ops_user_roles
      ADD CONSTRAINT ops_user_roles_role_code_fkey
      FOREIGN KEY (role_code) REFERENCES public.ops_roles(code)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

-- 4. ops_products.supplier_id → ops_suppliers(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_products_supplier_id_fkey') THEN
    ALTER TABLE public.ops_products
      ADD CONSTRAINT ops_products_supplier_id_fkey
      FOREIGN KEY (supplier_id) REFERENCES public.ops_suppliers(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_products_supplier_id ON public.ops_products(supplier_id);

-- 5. ops_skus.supplier_id → ops_suppliers(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_skus_supplier_id_fkey') THEN
    ALTER TABLE public.ops_skus
      ADD CONSTRAINT ops_skus_supplier_id_fkey
      FOREIGN KEY (supplier_id) REFERENCES public.ops_suppliers(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_skus_supplier_id ON public.ops_skus(supplier_id);

-- 6. ops_arrivals.supplier_id → ops_suppliers(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_arrivals_supplier_id_fkey') THEN
    ALTER TABLE public.ops_arrivals
      ADD CONSTRAINT ops_arrivals_supplier_id_fkey
      FOREIGN KEY (supplier_id) REFERENCES public.ops_suppliers(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_arrivals_supplier_id ON public.ops_arrivals(supplier_id);

-- 7. ops_arrivals.operator_id → profiles(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_arrivals_operator_id_fkey') THEN
    ALTER TABLE public.ops_arrivals
      ADD CONSTRAINT ops_arrivals_operator_id_fkey
      FOREIGN KEY (operator_id) REFERENCES public.profiles(id)
      ON UPDATE CASCADE ON DELETE SET NULL;
  END IF;
END $$;

-- 8. ops_arrival_items.sku_id → ops_skus(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_arrival_items_sku_id_fkey') THEN
    ALTER TABLE public.ops_arrival_items
      ADD CONSTRAINT ops_arrival_items_sku_id_fkey
      FOREIGN KEY (sku_id) REFERENCES public.ops_skus(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_arrival_items_sku_id ON public.ops_arrival_items(sku_id);

-- 9. ops_supplier_bills.supplier_id → ops_suppliers(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_supplier_bills_supplier_id_fkey') THEN
    ALTER TABLE public.ops_supplier_bills
      ADD CONSTRAINT ops_supplier_bills_supplier_id_fkey
      FOREIGN KEY (supplier_id) REFERENCES public.ops_suppliers(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_ops_supplier_bills_supplier_id ON public.ops_supplier_bills(supplier_id);

-- 10. ops_supplier_bills.auditor_id → profiles(id)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ops_supplier_bills_auditor_id_fkey') THEN
    ALTER TABLE public.ops_supplier_bills
      ADD CONSTRAINT ops_supplier_bills_auditor_id_fkey
      FOREIGN KEY (auditor_id) REFERENCES public.profiles(id)
      ON UPDATE CASCADE ON DELETE SET NULL;
  END IF;
END $$;

-- 11. ops_arrivals.arrived_at: date → timestamptz
DO $$
DECLARE v_type text;
BEGIN
  SELECT data_type INTO v_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='ops_arrivals' AND column_name='arrived_at';
  IF v_type = 'date' THEN
    ALTER TABLE public.ops_arrivals
      ALTER COLUMN arrived_at TYPE timestamptz USING (arrived_at::timestamptz),
      ALTER COLUMN arrived_at SET DEFAULT now();
  END IF;
END $$;

-- 12. purchase_order_items: 新增 sku_id / product_id + FK + 索引
ALTER TABLE public.purchase_order_items
  ADD COLUMN IF NOT EXISTS sku_id     uuid,
  ADD COLUMN IF NOT EXISTS product_id uuid;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_order_items_sku_id_fkey') THEN
    ALTER TABLE public.purchase_order_items
      ADD CONSTRAINT purchase_order_items_sku_id_fkey
      FOREIGN KEY (sku_id) REFERENCES public.ops_skus(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_order_items_product_id_fkey') THEN
    ALTER TABLE public.purchase_order_items
      ADD CONSTRAINT purchase_order_items_product_id_fkey
      FOREIGN KEY (product_id) REFERENCES public.ops_products(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_poi_sku_id     ON public.purchase_order_items(sku_id);
CREATE INDEX IF NOT EXISTS idx_poi_product_id ON public.purchase_order_items(product_id);

-- 13. purchase_receipt_items: 同上
ALTER TABLE public.purchase_receipt_items
  ADD COLUMN IF NOT EXISTS sku_id     uuid,
  ADD COLUMN IF NOT EXISTS product_id uuid;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_receipt_items_sku_id_fkey') THEN
    ALTER TABLE public.purchase_receipt_items
      ADD CONSTRAINT purchase_receipt_items_sku_id_fkey
      FOREIGN KEY (sku_id) REFERENCES public.ops_skus(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_receipt_items_product_id_fkey') THEN
    ALTER TABLE public.purchase_receipt_items
      ADD CONSTRAINT purchase_receipt_items_product_id_fkey
      FOREIGN KEY (product_id) REFERENCES public.ops_products(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_pri_sku_id     ON public.purchase_receipt_items(sku_id);
CREATE INDEX IF NOT EXISTS idx_pri_product_id ON public.purchase_receipt_items(product_id);
