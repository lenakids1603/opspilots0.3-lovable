# 生产库 unused_index 清单(Supabase performance advisor,2026-06-11)

共 62 个从未被使用过的索引(lint `unused_index`,INFO 级)。**本次仅记录,未做任何删除**;
删除前需人工确认:部分索引可能服务于低频查询(月度报表、回补任务等),pg_stat 的
使用计数自上次重置以来为 0 不代表永远不会用到。

注:2026-06-11 同日新建的 20 个外键覆盖索引(`idx_*` 系列,见迁移 `20260611120100`)
刚创建必然未被使用,不在本清单内。

| 表 | 索引 |
| --- | --- |
| cash_transactions | `idx_cash_tx_bank_date` |
| cash_transactions | `idx_cash_tx_shop` |
| cash_transactions | `idx_cash_tx_supplier` |
| cash_transactions | `idx_cash_tx_supplier_bill` |
| jst_api_debug_payloads | `idx_jst_api_debug_payloads_expires` |
| jst_outbound_order_items | `idx_jst_outbound_items_sku_id` |
| jst_outbound_orders | `idx_jst_outbound_orders_shop` |
| jst_refund_order_items | `idx_jst_refund_items_as_asi` |
| jst_refund_orders | `idx_jst_refund_orders_modified` |
| jst_sales_order_items | `idx_jst_sales_order_items_i_id` |
| jst_sales_order_items | `idx_jst_sales_order_items_jst_o_id` |
| jst_sales_order_items | `idx_jst_sales_order_items_sku_id` |
| jst_sales_order_items | `idx_jst_sales_order_items_so_id` |
| jst_sales_orders | `idx_jst_sales_orders_status` |
| jst_sales_refund_daily_summary | `idx_jst_srds_entity` |
| jst_sales_refund_daily_summary | `idx_jst_srds_platform` |
| jst_sales_refund_raw | `idx_jst_srr_order` |
| jst_sales_refund_raw | `idx_jst_srr_paid` |
| jst_sales_refund_raw | `idx_jst_srr_refund` |
| jst_sales_refund_raw | `idx_jst_srr_refund_at` |
| jst_sales_refund_raw | `idx_jst_srr_run` |
| jst_sales_refund_raw | `idx_jst_srr_shop` |
| jst_shop_mapping_audit_logs | `jst_shop_mapping_audit_mapping_idx` |
| jst_suppliers_raw | `idx_jst_suppliers_raw_code` |
| jst_sync_errors | `idx_jst_sync_errors_status` |
| jst_sync_log_details | `idx_jst_sync_log_details_job` |
| jst_warehouses | `idx_jst_warehouses_status` |
| ops_arrival_items | `idx_ops_arrival_items_sku_id` |
| ops_arrivals | `idx_ops_arrivals_supplier_id` |
| ops_product_mapping_exceptions | `idx_ops_product_mapping_exceptions_status` |
| ops_products | `idx_ops_products_supplier_id` |
| ops_sku_aliases | `ops_sku_aliases_sku_idx` |
| ops_skus | `idx_ops_skus_style_no` |
| ops_skus | `idx_ops_skus_supplier_id` |
| ops_supplier_bills | `idx_ops_supplier_bills_supplier_id` |
| ops_supplier_confirm_audit_logs | `ops_supplier_confirm_audit_supplier_idx` |
| order_lookup_index | `idx_order_lookup_index_pay_time` |
| order_lookup_index | `idx_order_lookup_index_so_id` |
| purchase_order_items | `idx_poi_product_id` |
| purchase_order_items | `idx_poi_sku_id` |
| purchase_receipt_items | `idx_pri_sku_id` |
| sales_hourly_summary | `idx_sales_hourly_summary_shop` |
| sales_hourly_summary | `idx_sales_hourly_summary_style` |
| sales_order_light_items | `idx_sales_light_items_pay_time` |
| sales_order_light_items | `idx_sales_light_items_shop_date` |
| sales_order_light_items | `idx_sales_light_items_so_id` |
| sales_order_light_items | `idx_sales_light_items_style_date` |
| sales_sku_daily_summary | `idx_sales_sku_daily_summary_sku` |
| sales_style_daily_summary | `idx_sales_style_daily_summary_style` |
| shipping_risk_orders | `idx_shipping_risk_orders_shop` |
| shipping_risk_orders | `idx_shipping_risk_orders_style` |
| shops | `idx_shops_sync_active` |
| warehouse_shipping_package_items | `idx_warehouse_shipping_package_items_io_id` |
| warehouse_shipping_package_items | `idx_warehouse_shipping_package_items_package` |
| warehouse_shipping_package_items | `idx_warehouse_shipping_package_items_sku` |
| warehouse_shipping_package_items | `idx_warehouse_shipping_package_items_sku_code` |
| warehouse_shipping_package_items | `idx_warehouse_shipping_package_items_style` |
| warehouse_shipping_packages | `idx_warehouse_shipping_packages_logistics_date` |
| warehouse_shipping_packages | `idx_warehouse_shipping_packages_send_date` |
| warehouse_shipping_packages | `idx_warehouse_shipping_packages_shop_date` |
| warehouse_shipping_packages | `idx_warehouse_shipping_packages_tracking` |
| warehouse_shipping_packages | `idx_warehouse_shipping_packages_wh_date` |
