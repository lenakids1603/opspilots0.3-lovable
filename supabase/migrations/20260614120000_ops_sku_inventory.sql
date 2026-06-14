-- 聚水潭库存快照表 ops_sku_inventory（2026-06-14）
--
-- 用途：商品详情页「库存」Tab + 催货页采购缺口的「可用库存」计算。
-- 来源：聚水潭「库存查询」/open/inventory/query（POST，与 sku/query 同构）。
--
-- ★ 探活实测结论（2026-06-14，jst-debug-inventory-fields，命中真实 JST）：
--   1) modified_begin/end 必填（裸拉报 code=170）；窗口≤7 天；page_size≤100。
--   2) 响应字段：sku_id, i_id, name, qty, order_lock, pick_lock, purchase_qty,
--      return_qty, defective_qty, modified, ts；查具体仓时**回传 wms_co_id**，
--      查全仓（不传 wms_co_id）则无。allocate_qty/virtual_qty/in_qty 实测**恒 0**→不存。
--   3) 仓库：现有 3 仓，但 7 天内只有主仓 10843291 有库存行（卓强 11799039 /
--      云仓 12525996 = 0）。表按 SKU×仓库（超集，留未来），同步实际几乎只写主仓。
--   4) 可用口径：pick_lock ⊆ order_lock（待发是订单占用的子集，铁证：pick_lock>0
--      的行 order_lock 必>0 且 pick_lock≤order_lock）→ 可用 = qty − order_lock
--      （不可再减 pick_lock，会重复扣）。可用**允许为负**（预售：order_lock≫qty；
--      qty 本身偶为负）；available 列先不落（公式待老板后台抽验定稿），催货侧直接
--      按 qty−order_lock 现算，pick_lock 仅留作展示。
--
-- 快照式：每 (sku_code, wms_co_id) 一行，upsert 覆盖当前量；不存历史、不存 raw JSON。

CREATE TABLE IF NOT EXISTS public.ops_sku_inventory (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_code     text NOT NULL,                 -- = JST sku_id（商品编码），关联 ops_skus.sku_code
  jst_sku_id   text,                          -- JST sku_id 原值（此接口与 sku_code 同值，对齐其它表）
  wms_co_id    text NOT NULL,                 -- 分仓编号 = jst_warehouses.jst_wms_co_id（响应/请求两侧均有）
  warehouse_name text,                        -- 仓库名（写入时反查 jst_warehouses 冗余，可空）

  qty          numeric NOT NULL DEFAULT 0,    -- 主仓实际库存（可为负）
  order_lock   numeric NOT NULL DEFAULT 0,    -- 订单占有数（含待发子集）；可用 = qty − order_lock
  pick_lock    numeric NOT NULL DEFAULT 0,    -- 仓库待发数（order_lock 的子集，仅展示，勿再扣减）
  purchase_qty numeric NOT NULL DEFAULT 0,    -- 采购在途数
  return_qty   numeric NOT NULL DEFAULT 0,    -- 销退仓库存
  defective_qty numeric NOT NULL DEFAULT 0,   -- 次品库存

  jst_modified_at timestamptz,                -- JST 行 modified（增量水位）
  last_synced_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ops_sku_inventory_sku_wms_uk UNIQUE (sku_code, wms_co_id)
);

COMMENT ON TABLE public.ops_sku_inventory IS
  '聚水潭库存快照（SKU×仓库当前量，upsert 覆盖式，无历史）。来源 /open/inventory/query；'
  '可用 = qty − order_lock（pick_lock⊆order_lock，勿重复扣），允许为负（预售/缺口）。';

CREATE INDEX IF NOT EXISTS idx_ops_sku_inventory_sku ON public.ops_sku_inventory(sku_code);
CREATE INDEX IF NOT EXISTS idx_ops_sku_inventory_wms ON public.ops_sku_inventory(wms_co_id);

DROP TRIGGER IF EXISTS trg_ops_sku_inventory_updated ON public.ops_sku_inventory;
CREATE TRIGGER trg_ops_sku_inventory_updated
  BEFORE UPDATE ON public.ops_sku_inventory
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 写入仅经 service_role（边缘函数）；内部用户只读（详情页库存 Tab 直查）；供应商不可见。
ALTER TABLE public.ops_sku_inventory ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.ops_sku_inventory TO authenticated;
GRANT ALL ON public.ops_sku_inventory TO service_role;

DROP POLICY IF EXISTS "select ops_sku_inventory" ON public.ops_sku_inventory;
CREATE POLICY "select ops_sku_inventory" ON public.ops_sku_inventory
  AS permissive FOR SELECT TO authenticated
  USING (public.is_ops_internal((select auth.uid())));

NOTIFY pgrst, 'reload schema';
