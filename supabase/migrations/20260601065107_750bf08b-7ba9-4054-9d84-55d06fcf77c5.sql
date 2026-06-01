-- Seed platforms
INSERT INTO public.platforms (code, name) VALUES
  ('douyin','抖音'),
  ('taobao','淘宝'),
  ('tmall','天猫'),
  ('kuaishou','快手'),
  ('xiaohongshu','小红书')
ON CONFLICT (code) DO NOTHING;

-- Seed cash_tx_categories (out)
INSERT INTO public.cash_tx_categories (code, name, direction, sort_order) VALUES
  ('supplier_payment','供应商付款','out',10),
  ('salary','工资','out',20),
  ('shipping','快递费','out',30),
  ('ads','投流费用','out',40),
  ('rent','房租','out',50),
  ('utilities','水电','out',60),
  ('office','办公用品','out',70),
  ('warehouse_fee','仓库费用','out',80),
  ('temp_labor','临时工工资','out',90),
  ('other_out','其他','out',100),
  ('platform_settlement','平台回款','in',10),
  ('other_in','其他收入','in',20)
ON CONFLICT (code) DO NOTHING;