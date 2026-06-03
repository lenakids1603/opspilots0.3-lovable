
-- ============ jst_sales_orders ============
CREATE TABLE public.jst_sales_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  jst_o_id text NOT NULL UNIQUE,
  so_id text,
  shop_id text,
  shop_name text,
  status text,
  order_type text,
  created_time timestamptz,
  modified_time timestamptz,
  pay_time timestamptz,
  io_id text,
  io_date timestamptz,
  l_id text,
  lc_id text,
  logistics_company text,
  pay_amount numeric NOT NULL DEFAULT 0,
  paid_amount numeric NOT NULL DEFAULT 0,
  free_amount numeric NOT NULL DEFAULT 0,
  freight numeric NOT NULL DEFAULT 0,
  weight numeric NOT NULL DEFAULT 0,
  f_weight numeric NOT NULL DEFAULT 0,
  buyer_message text,
  seller_remark text,
  labels jsonb,
  merge_so_id text,
  receiver_province text,
  receiver_city text,
  receiver_district text,
  receiver_mobile_masked text,
  raw_data jsonb,
  sync_batch_id text,
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.jst_sales_orders TO authenticated;
GRANT ALL ON public.jst_sales_orders TO service_role;
ALTER TABLE public.jst_sales_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "internal read jst_sales_orders" ON public.jst_sales_orders
  FOR SELECT TO authenticated USING (is_ops_internal(auth.uid()));
CREATE POLICY "admin write jst_sales_orders" ON public.jst_sales_orders
  FOR ALL TO authenticated
  USING (has_ops_role(auth.uid(),'admin'::ops_role_code))
  WITH CHECK (has_ops_role(auth.uid(),'admin'::ops_role_code));

CREATE INDEX idx_jst_sales_orders_so_id ON public.jst_sales_orders(so_id);
CREATE INDEX idx_jst_sales_orders_shop_id ON public.jst_sales_orders(shop_id);
CREATE INDEX idx_jst_sales_orders_status ON public.jst_sales_orders(status);
CREATE INDEX idx_jst_sales_orders_created_time ON public.jst_sales_orders(created_time);
CREATE INDEX idx_jst_sales_orders_modified_time ON public.jst_sales_orders(modified_time);

-- ============ jst_sales_order_items ============
CREATE TABLE public.jst_sales_order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_order_id uuid NOT NULL,
  jst_o_id text NOT NULL,
  so_id text,
  shop_id text,
  item_index int NOT NULL DEFAULT 0,
  jst_item_id text,
  sku_id text,
  i_id text,
  sku_code text,
  shop_sku_id text,
  product_name text,
  sku_name text,
  qty numeric NOT NULL DEFAULT 0,
  sale_price numeric NOT NULL DEFAULT 0,
  amount numeric NOT NULL DEFAULT 0,
  paid_amount numeric NOT NULL DEFAULT 0,
  refund_status text,
  pic text,
  supplier_id text,
  supplier_name text,
  item_unique_key text NOT NULL UNIQUE,
  raw_item_data jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.jst_sales_order_items TO authenticated;
GRANT ALL ON public.jst_sales_order_items TO service_role;
ALTER TABLE public.jst_sales_order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "internal read jst_sales_order_items" ON public.jst_sales_order_items
  FOR SELECT TO authenticated USING (is_ops_internal(auth.uid()));
CREATE POLICY "admin write jst_sales_order_items" ON public.jst_sales_order_items
  FOR ALL TO authenticated
  USING (has_ops_role(auth.uid(),'admin'::ops_role_code))
  WITH CHECK (has_ops_role(auth.uid(),'admin'::ops_role_code));

CREATE INDEX idx_jst_sales_order_items_jst_o_id ON public.jst_sales_order_items(jst_o_id);
CREATE INDEX idx_jst_sales_order_items_so_id ON public.jst_sales_order_items(so_id);
CREATE INDEX idx_jst_sales_order_items_sku_id ON public.jst_sales_order_items(sku_id);
CREATE INDEX idx_jst_sales_order_items_i_id ON public.jst_sales_order_items(i_id);
CREATE INDEX idx_jst_sales_order_items_shop_id ON public.jst_sales_order_items(shop_id);
