-- =============================================================================
-- Covering indexes for unindexed foreign keys
-- (Supabase performance advisor lint 0001, 2026-06-11, 20 findings)
-- Idempotent via IF NOT EXISTS.
-- =============================================================================

create index if not exists idx_approval_actions_approver_id on public.approval_actions (approver_id);
create index if not exists idx_approval_actions_expense_id on public.approval_actions (expense_id);
create index if not exists idx_audit_logs_expense_id on public.audit_logs (expense_id);
create index if not exists idx_audit_logs_user_id on public.audit_logs (user_id);
create index if not exists idx_bank_accounts_owner_entity_id on public.bank_accounts (owner_entity_id);
create index if not exists idx_bank_accounts_related_entity_id on public.bank_accounts (related_entity_id);
create index if not exists idx_cash_transactions_operator_id on public.cash_transactions (operator_id);
create index if not exists idx_cash_tx_categories_parent_id on public.cash_tx_categories (parent_id);
create index if not exists idx_expense_receipts_expense_id on public.expense_receipts (expense_id);
create index if not exists idx_expenses_category_id on public.expenses (category_id);
create index if not exists idx_expenses_user_id on public.expenses (user_id);
create index if not exists idx_jst_outbound_order_items_outbound_order_id on public.jst_outbound_order_items (outbound_order_id);
create index if not exists idx_ops_arrival_items_arrival_id on public.ops_arrival_items (arrival_id);
create index if not exists idx_ops_arrivals_operator_id on public.ops_arrivals (operator_id);
create index if not exists idx_ops_product_mapping_exceptions_resolved_sku_id on public.ops_product_mapping_exceptions (resolved_sku_id);
create index if not exists idx_ops_skus_product_id on public.ops_skus (product_id);
create index if not exists idx_ops_supplier_bills_auditor_id on public.ops_supplier_bills (auditor_id);
create index if not exists idx_ops_user_roles_role_code on public.ops_user_roles (role_code);
create index if not exists idx_profiles_manager_id on public.profiles (manager_id);
create index if not exists idx_shop_bank_account_bindings_platform_id on public.shop_bank_account_bindings (platform_id);
