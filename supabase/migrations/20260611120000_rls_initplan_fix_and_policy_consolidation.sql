-- =============================================================================
-- RLS performance fix (Supabase performance advisor, 2026-06-11)
--
-- 1. auth_rls_initplan (lint 0003, 133 findings): every auth.uid() call inside
--    a policy expression is rewritten as (select auth.uid()) so Postgres
--    evaluates it once per statement (InitPlan) instead of once per row.
-- 2. multiple_permissive_policies (lint 0006, 53 findings): on tables where
--    several permissive policies applied to the same role/action, the
--    FOR ALL write policies are split into per-action policies and the
--    overlapping action policies are merged into a single policy whose
--    expression is the OR of the originals. Semantics are unchanged
--    (permissive policies already combined with OR).
--
-- Idempotent: re-running this migration yields the same final state.
-- Generated from the production pg_policies snapshot; behavior-preserving.
-- =============================================================================

-- ----- approval_actions -----
drop policy if exists "Approvers can view own actions" on public."approval_actions";
drop policy if exists "Finance can view all approvals" on public."approval_actions";
drop policy if exists "Only finance can insert approvals" on public."approval_actions";
drop policy if exists "Users can view approvals on own expenses" on public."approval_actions";
drop policy if exists "select approval_actions" on public."approval_actions";
create policy "select approval_actions" on public."approval_actions"
  as permissive for select to authenticated
  using (((approver_id = (select auth.uid()))
   OR has_role((select auth.uid()), 'finance'::app_role)
   OR (EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = approval_actions.expense_id) AND (expenses.user_id = (select auth.uid())))))));
create policy "Only finance can insert approvals" on public."approval_actions"
  as permissive for insert to authenticated
  with check (has_role((select auth.uid()), 'finance'::app_role));

-- ----- audit_logs -----
drop policy if exists "Finance can view all audit logs" on public."audit_logs";
drop policy if exists "System can insert audit logs" on public."audit_logs";
drop policy if exists "Users can view own audit logs" on public."audit_logs";
drop policy if exists "select audit_logs" on public."audit_logs";
create policy "select audit_logs" on public."audit_logs"
  as permissive for select to authenticated
  using ((has_role((select auth.uid()), 'finance'::app_role)
   OR ((user_id = (select auth.uid())) OR (EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = audit_logs.expense_id) AND (expenses.user_id = (select auth.uid()))))))));
create policy "System can insert audit logs" on public."audit_logs"
  as permissive for insert to authenticated
  with check ((user_id = (select auth.uid())));

-- ----- bank_accounts -----
drop policy if exists "delete bank_accounts" on public."bank_accounts";
drop policy if exists "finance read bank_accounts" on public."bank_accounts";
drop policy if exists "finance write bank_accounts" on public."bank_accounts";
drop policy if exists "insert bank_accounts" on public."bank_accounts";
drop policy if exists "select bank_accounts" on public."bank_accounts";
drop policy if exists "update bank_accounts" on public."bank_accounts";
create policy "select bank_accounts" on public."bank_accounts"
  as permissive for select to authenticated
  using (((can_read_finance((select auth.uid())) AND (deleted_at IS NULL))
   OR can_write_finance((select auth.uid()))));
create policy "insert bank_accounts" on public."bank_accounts"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update bank_accounts" on public."bank_accounts"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete bank_accounts" on public."bank_accounts"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- business_entities -----
drop policy if exists "delete business_entities" on public."business_entities";
drop policy if exists "finance read business_entities" on public."business_entities";
drop policy if exists "finance write business_entities" on public."business_entities";
drop policy if exists "insert business_entities" on public."business_entities";
drop policy if exists "select business_entities" on public."business_entities";
drop policy if exists "update business_entities" on public."business_entities";
create policy "select business_entities" on public."business_entities"
  as permissive for select to authenticated
  using (((can_read_finance((select auth.uid())) AND (deleted_at IS NULL))
   OR can_write_finance((select auth.uid()))));
create policy "insert business_entities" on public."business_entities"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update business_entities" on public."business_entities"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete business_entities" on public."business_entities"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- cash_transactions -----
drop policy if exists "delete cash_transactions" on public."cash_transactions";
drop policy if exists "finance read cash_transactions" on public."cash_transactions";
drop policy if exists "finance write cash_transactions" on public."cash_transactions";
drop policy if exists "insert cash_transactions" on public."cash_transactions";
drop policy if exists "select cash_transactions" on public."cash_transactions";
drop policy if exists "update cash_transactions" on public."cash_transactions";
create policy "select cash_transactions" on public."cash_transactions"
  as permissive for select to authenticated
  using (((can_read_finance((select auth.uid())) AND (deleted_at IS NULL))
   OR can_write_finance((select auth.uid()))));
create policy "insert cash_transactions" on public."cash_transactions"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update cash_transactions" on public."cash_transactions"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete cash_transactions" on public."cash_transactions"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- cash_tx_categories -----
drop policy if exists "delete cash_tx_categories" on public."cash_tx_categories";
drop policy if exists "finance write cash_tx_categories" on public."cash_tx_categories";
drop policy if exists "insert cash_tx_categories" on public."cash_tx_categories";
drop policy if exists "internal read cash_tx_categories" on public."cash_tx_categories";
drop policy if exists "select cash_tx_categories" on public."cash_tx_categories";
drop policy if exists "update cash_tx_categories" on public."cash_tx_categories";
create policy "select cash_tx_categories" on public."cash_tx_categories"
  as permissive for select to authenticated
  using ((can_write_finance((select auth.uid()))
   OR (is_ops_internal((select auth.uid())) AND (deleted_at IS NULL))));
create policy "insert cash_tx_categories" on public."cash_tx_categories"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update cash_tx_categories" on public."cash_tx_categories"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete cash_tx_categories" on public."cash_tx_categories"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- expense_categories -----
drop policy if exists "Only finance can delete categories" on public."expense_categories";
drop policy if exists "Only finance can insert categories" on public."expense_categories";
drop policy if exists "Only finance can update categories" on public."expense_categories";
create policy "Only finance can delete categories" on public."expense_categories"
  as permissive for delete to authenticated
  using (has_role((select auth.uid()), 'finance'::app_role));
create policy "Only finance can insert categories" on public."expense_categories"
  as permissive for insert to authenticated
  with check (has_role((select auth.uid()), 'finance'::app_role));
create policy "Only finance can update categories" on public."expense_categories"
  as permissive for update to authenticated
  using (has_role((select auth.uid()), 'finance'::app_role));

-- ----- expense_receipts -----
drop policy if exists "Finance can view all receipts" on public."expense_receipts";
drop policy if exists "Managers can view team receipts" on public."expense_receipts";
drop policy if exists "Users can manage own receipts" on public."expense_receipts";
drop policy if exists "delete expense_receipts" on public."expense_receipts";
drop policy if exists "insert expense_receipts" on public."expense_receipts";
drop policy if exists "select expense_receipts" on public."expense_receipts";
drop policy if exists "update expense_receipts" on public."expense_receipts";
create policy "select expense_receipts" on public."expense_receipts"
  as permissive for select to authenticated
  using ((has_role((select auth.uid()), 'finance'::app_role)
   OR (EXISTS ( SELECT 1
   FROM expenses e
  WHERE ((e.id = expense_receipts.expense_id) AND has_role((select auth.uid()), 'manager'::app_role) AND is_manager_of((select auth.uid()), e.user_id))))
   OR (EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = expense_receipts.expense_id) AND (expenses.user_id = (select auth.uid())))))));
create policy "insert expense_receipts" on public."expense_receipts"
  as permissive for insert to authenticated
  with check ((EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = expense_receipts.expense_id) AND (expenses.user_id = (select auth.uid()))))));
create policy "update expense_receipts" on public."expense_receipts"
  as permissive for update to authenticated
  using ((EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = expense_receipts.expense_id) AND (expenses.user_id = (select auth.uid()))))))
  with check ((EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = expense_receipts.expense_id) AND (expenses.user_id = (select auth.uid()))))));
create policy "delete expense_receipts" on public."expense_receipts"
  as permissive for delete to authenticated
  using ((EXISTS ( SELECT 1
   FROM expenses
  WHERE ((expenses.id = expense_receipts.expense_id) AND (expenses.user_id = (select auth.uid()))))));

-- ----- expenses -----
drop policy if exists "Finance can update all expenses" on public."expenses";
drop policy if exists "Finance can view all expenses" on public."expenses";
drop policy if exists "Managers can view team expenses" on public."expenses";
drop policy if exists "Users can CRUD own expenses" on public."expenses";
drop policy if exists "delete expenses" on public."expenses";
drop policy if exists "insert expenses" on public."expenses";
drop policy if exists "select expenses" on public."expenses";
drop policy if exists "update expenses" on public."expenses";
create policy "select expenses" on public."expenses"
  as permissive for select to authenticated
  using ((has_role((select auth.uid()), 'finance'::app_role)
   OR (has_role((select auth.uid()), 'manager'::app_role) AND is_manager_of((select auth.uid()), user_id))
   OR (user_id = (select auth.uid()))));
create policy "insert expenses" on public."expenses"
  as permissive for insert to authenticated
  with check ((user_id = (select auth.uid())));
create policy "update expenses" on public."expenses"
  as permissive for update to authenticated
  using ((has_role((select auth.uid()), 'finance'::app_role)
   OR (user_id = (select auth.uid()))))
  with check ((has_role((select auth.uid()), 'finance'::app_role)
   OR (user_id = (select auth.uid()))));
create policy "delete expenses" on public."expenses"
  as permissive for delete to authenticated
  using ((user_id = (select auth.uid())));

-- ----- jst_aftersale_received_items -----
drop policy if exists "admin write jst_aftersale_received_items" on public."jst_aftersale_received_items";
drop policy if exists "delete jst_aftersale_received_items" on public."jst_aftersale_received_items";
drop policy if exists "insert jst_aftersale_received_items" on public."jst_aftersale_received_items";
drop policy if exists "internal read jst_aftersale_received_items" on public."jst_aftersale_received_items";
drop policy if exists "select jst_aftersale_received_items" on public."jst_aftersale_received_items";
drop policy if exists "update jst_aftersale_received_items" on public."jst_aftersale_received_items";
create policy "select jst_aftersale_received_items" on public."jst_aftersale_received_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_aftersale_received_items" on public."jst_aftersale_received_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_aftersale_received_items" on public."jst_aftersale_received_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_aftersale_received_items" on public."jst_aftersale_received_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_aftersale_received_orders -----
drop policy if exists "admin write jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
drop policy if exists "delete jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
drop policy if exists "insert jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
drop policy if exists "internal read jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
drop policy if exists "select jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
drop policy if exists "update jst_aftersale_received_orders" on public."jst_aftersale_received_orders";
create policy "select jst_aftersale_received_orders" on public."jst_aftersale_received_orders"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_aftersale_received_orders" on public."jst_aftersale_received_orders"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_aftersale_received_orders" on public."jst_aftersale_received_orders"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_aftersale_received_orders" on public."jst_aftersale_received_orders"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_api_debug_payloads -----
drop policy if exists "admin write jst_api_debug_payloads" on public."jst_api_debug_payloads";
drop policy if exists "delete jst_api_debug_payloads" on public."jst_api_debug_payloads";
drop policy if exists "insert jst_api_debug_payloads" on public."jst_api_debug_payloads";
drop policy if exists "internal read jst_api_debug_payloads" on public."jst_api_debug_payloads";
drop policy if exists "select jst_api_debug_payloads" on public."jst_api_debug_payloads";
drop policy if exists "update jst_api_debug_payloads" on public."jst_api_debug_payloads";
create policy "select jst_api_debug_payloads" on public."jst_api_debug_payloads"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_api_debug_payloads" on public."jst_api_debug_payloads"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_api_debug_payloads" on public."jst_api_debug_payloads"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_api_debug_payloads" on public."jst_api_debug_payloads"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_outbound_order_items -----
drop policy if exists "admin write jst_outbound_order_items" on public."jst_outbound_order_items";
drop policy if exists "delete jst_outbound_order_items" on public."jst_outbound_order_items";
drop policy if exists "insert jst_outbound_order_items" on public."jst_outbound_order_items";
drop policy if exists "internal read jst_outbound_order_items" on public."jst_outbound_order_items";
drop policy if exists "select jst_outbound_order_items" on public."jst_outbound_order_items";
drop policy if exists "update jst_outbound_order_items" on public."jst_outbound_order_items";
create policy "select jst_outbound_order_items" on public."jst_outbound_order_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_outbound_order_items" on public."jst_outbound_order_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_outbound_order_items" on public."jst_outbound_order_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_outbound_order_items" on public."jst_outbound_order_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_outbound_orders -----
drop policy if exists "admin write jst_outbound_orders" on public."jst_outbound_orders";
drop policy if exists "delete jst_outbound_orders" on public."jst_outbound_orders";
drop policy if exists "insert jst_outbound_orders" on public."jst_outbound_orders";
drop policy if exists "internal read jst_outbound_orders" on public."jst_outbound_orders";
drop policy if exists "select jst_outbound_orders" on public."jst_outbound_orders";
drop policy if exists "update jst_outbound_orders" on public."jst_outbound_orders";
create policy "select jst_outbound_orders" on public."jst_outbound_orders"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_outbound_orders" on public."jst_outbound_orders"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_outbound_orders" on public."jst_outbound_orders"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_outbound_orders" on public."jst_outbound_orders"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_refund_order_items -----
drop policy if exists "admin write jst_refund_order_items" on public."jst_refund_order_items";
drop policy if exists "delete jst_refund_order_items" on public."jst_refund_order_items";
drop policy if exists "insert jst_refund_order_items" on public."jst_refund_order_items";
drop policy if exists "internal read jst_refund_order_items" on public."jst_refund_order_items";
drop policy if exists "select jst_refund_order_items" on public."jst_refund_order_items";
drop policy if exists "update jst_refund_order_items" on public."jst_refund_order_items";
create policy "select jst_refund_order_items" on public."jst_refund_order_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_refund_order_items" on public."jst_refund_order_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_refund_order_items" on public."jst_refund_order_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_refund_order_items" on public."jst_refund_order_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_refund_orders -----
drop policy if exists "admin write jst_refund_orders" on public."jst_refund_orders";
drop policy if exists "delete jst_refund_orders" on public."jst_refund_orders";
drop policy if exists "insert jst_refund_orders" on public."jst_refund_orders";
drop policy if exists "internal read jst_refund_orders" on public."jst_refund_orders";
drop policy if exists "select jst_refund_orders" on public."jst_refund_orders";
drop policy if exists "update jst_refund_orders" on public."jst_refund_orders";
create policy "select jst_refund_orders" on public."jst_refund_orders"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_refund_orders" on public."jst_refund_orders"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_refund_orders" on public."jst_refund_orders"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_refund_orders" on public."jst_refund_orders"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sales_order_items -----
drop policy if exists "admin write jst_sales_order_items" on public."jst_sales_order_items";
drop policy if exists "delete jst_sales_order_items" on public."jst_sales_order_items";
drop policy if exists "insert jst_sales_order_items" on public."jst_sales_order_items";
drop policy if exists "internal read jst_sales_order_items" on public."jst_sales_order_items";
drop policy if exists "select jst_sales_order_items" on public."jst_sales_order_items";
drop policy if exists "update jst_sales_order_items" on public."jst_sales_order_items";
create policy "select jst_sales_order_items" on public."jst_sales_order_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sales_order_items" on public."jst_sales_order_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sales_order_items" on public."jst_sales_order_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sales_order_items" on public."jst_sales_order_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sales_orders -----
drop policy if exists "admin write jst_sales_orders" on public."jst_sales_orders";
drop policy if exists "delete jst_sales_orders" on public."jst_sales_orders";
drop policy if exists "insert jst_sales_orders" on public."jst_sales_orders";
drop policy if exists "internal read jst_sales_orders" on public."jst_sales_orders";
drop policy if exists "select jst_sales_orders" on public."jst_sales_orders";
drop policy if exists "update jst_sales_orders" on public."jst_sales_orders";
create policy "select jst_sales_orders" on public."jst_sales_orders"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sales_orders" on public."jst_sales_orders"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sales_orders" on public."jst_sales_orders"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sales_orders" on public."jst_sales_orders"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sales_refund_daily_summary -----
drop policy if exists "admin write jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
drop policy if exists "delete jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
drop policy if exists "insert jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
drop policy if exists "internal read jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
drop policy if exists "select jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
drop policy if exists "update jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary";
create policy "select jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sales_refund_daily_summary" on public."jst_sales_refund_daily_summary"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sales_refund_raw -----
drop policy if exists "admin write jst_sales_refund_raw" on public."jst_sales_refund_raw";
drop policy if exists "delete jst_sales_refund_raw" on public."jst_sales_refund_raw";
drop policy if exists "insert jst_sales_refund_raw" on public."jst_sales_refund_raw";
drop policy if exists "internal read jst_sales_refund_raw" on public."jst_sales_refund_raw";
drop policy if exists "select jst_sales_refund_raw" on public."jst_sales_refund_raw";
drop policy if exists "update jst_sales_refund_raw" on public."jst_sales_refund_raw";
create policy "select jst_sales_refund_raw" on public."jst_sales_refund_raw"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sales_refund_raw" on public."jst_sales_refund_raw"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sales_refund_raw" on public."jst_sales_refund_raw"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sales_refund_raw" on public."jst_sales_refund_raw"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_shop_mapping_audit_logs -----
drop policy if exists "admin insert mapping audit" on public."jst_shop_mapping_audit_logs";
drop policy if exists "internal read mapping audit" on public."jst_shop_mapping_audit_logs";
create policy "admin insert mapping audit" on public."jst_shop_mapping_audit_logs"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "internal read mapping audit" on public."jst_shop_mapping_audit_logs"
  as permissive for select to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- jst_shop_mappings -----
drop policy if exists "admin write jst_shop_mappings" on public."jst_shop_mappings";
drop policy if exists "delete jst_shop_mappings" on public."jst_shop_mappings";
drop policy if exists "insert jst_shop_mappings" on public."jst_shop_mappings";
drop policy if exists "internal read jst_shop_mappings" on public."jst_shop_mappings";
drop policy if exists "select jst_shop_mappings" on public."jst_shop_mappings";
drop policy if exists "update jst_shop_mappings" on public."jst_shop_mappings";
create policy "select jst_shop_mappings" on public."jst_shop_mappings"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_shop_mappings" on public."jst_shop_mappings"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_shop_mappings" on public."jst_shop_mappings"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_shop_mappings" on public."jst_shop_mappings"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_suppliers_raw -----
drop policy if exists "admin write jst_suppliers_raw" on public."jst_suppliers_raw";
drop policy if exists "delete jst_suppliers_raw" on public."jst_suppliers_raw";
drop policy if exists "insert jst_suppliers_raw" on public."jst_suppliers_raw";
drop policy if exists "internal read jst_suppliers_raw" on public."jst_suppliers_raw";
drop policy if exists "select jst_suppliers_raw" on public."jst_suppliers_raw";
drop policy if exists "update jst_suppliers_raw" on public."jst_suppliers_raw";
create policy "select jst_suppliers_raw" on public."jst_suppliers_raw"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_suppliers_raw" on public."jst_suppliers_raw"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_suppliers_raw" on public."jst_suppliers_raw"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_suppliers_raw" on public."jst_suppliers_raw"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_errors -----
drop policy if exists "admin write jst_sync_errors" on public."jst_sync_errors";
drop policy if exists "delete jst_sync_errors" on public."jst_sync_errors";
drop policy if exists "insert jst_sync_errors" on public."jst_sync_errors";
drop policy if exists "internal read jst_sync_errors" on public."jst_sync_errors";
drop policy if exists "select jst_sync_errors" on public."jst_sync_errors";
drop policy if exists "update jst_sync_errors" on public."jst_sync_errors";
create policy "select jst_sync_errors" on public."jst_sync_errors"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sync_errors" on public."jst_sync_errors"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sync_errors" on public."jst_sync_errors"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sync_errors" on public."jst_sync_errors"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_jobs -----
drop policy if exists "admin write jst_sync_jobs" on public."jst_sync_jobs";
drop policy if exists "delete jst_sync_jobs" on public."jst_sync_jobs";
drop policy if exists "insert jst_sync_jobs" on public."jst_sync_jobs";
drop policy if exists "internal read jst_sync_jobs" on public."jst_sync_jobs";
drop policy if exists "select jst_sync_jobs" on public."jst_sync_jobs";
drop policy if exists "update jst_sync_jobs" on public."jst_sync_jobs";
create policy "select jst_sync_jobs" on public."jst_sync_jobs"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sync_jobs" on public."jst_sync_jobs"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sync_jobs" on public."jst_sync_jobs"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sync_jobs" on public."jst_sync_jobs"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_log_details -----
drop policy if exists "admin write jst_sync_log_details" on public."jst_sync_log_details";
drop policy if exists "delete jst_sync_log_details" on public."jst_sync_log_details";
drop policy if exists "insert jst_sync_log_details" on public."jst_sync_log_details";
drop policy if exists "internal read jst_sync_log_details" on public."jst_sync_log_details";
drop policy if exists "select jst_sync_log_details" on public."jst_sync_log_details";
drop policy if exists "update jst_sync_log_details" on public."jst_sync_log_details";
create policy "select jst_sync_log_details" on public."jst_sync_log_details"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sync_log_details" on public."jst_sync_log_details"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sync_log_details" on public."jst_sync_log_details"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sync_log_details" on public."jst_sync_log_details"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_logs -----
drop policy if exists "internal read sync logs" on public."jst_sync_logs";
create policy "internal read sync logs" on public."jst_sync_logs"
  as permissive for select to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- jst_sync_metrics -----
drop policy if exists "admin write jst_sync_metrics" on public."jst_sync_metrics";
drop policy if exists "delete jst_sync_metrics" on public."jst_sync_metrics";
drop policy if exists "insert jst_sync_metrics" on public."jst_sync_metrics";
drop policy if exists "internal read jst_sync_metrics" on public."jst_sync_metrics";
drop policy if exists "select jst_sync_metrics" on public."jst_sync_metrics";
drop policy if exists "update jst_sync_metrics" on public."jst_sync_metrics";
create policy "select jst_sync_metrics" on public."jst_sync_metrics"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sync_metrics" on public."jst_sync_metrics"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sync_metrics" on public."jst_sync_metrics"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sync_metrics" on public."jst_sync_metrics"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_modules -----
drop policy if exists "admin write jst_sync_modules" on public."jst_sync_modules";
drop policy if exists "delete jst_sync_modules" on public."jst_sync_modules";
drop policy if exists "insert jst_sync_modules" on public."jst_sync_modules";
drop policy if exists "internal read jst_sync_modules" on public."jst_sync_modules";
drop policy if exists "select jst_sync_modules" on public."jst_sync_modules";
drop policy if exists "update jst_sync_modules" on public."jst_sync_modules";
create policy "select jst_sync_modules" on public."jst_sync_modules"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_sync_modules" on public."jst_sync_modules"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_sync_modules" on public."jst_sync_modules"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_sync_modules" on public."jst_sync_modules"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- jst_sync_runs -----
drop policy if exists "admin delete jst_sync_runs" on public."jst_sync_runs";
drop policy if exists "admin update jst_sync_runs" on public."jst_sync_runs";
drop policy if exists "internal insert jst_sync_runs" on public."jst_sync_runs";
drop policy if exists "internal read jst_sync_runs" on public."jst_sync_runs";
create policy "admin delete jst_sync_runs" on public."jst_sync_runs"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "admin update jst_sync_runs" on public."jst_sync_runs"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "internal insert jst_sync_runs" on public."jst_sync_runs"
  as permissive for insert to authenticated
  with check ((is_ops_internal((select auth.uid())) AND (created_by = (select auth.uid()))));
create policy "internal read jst_sync_runs" on public."jst_sync_runs"
  as permissive for select to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- jst_sync_state -----
drop policy if exists "internal read sync state" on public."jst_sync_state";
create policy "internal read sync state" on public."jst_sync_state"
  as permissive for select to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- jst_warehouses -----
drop policy if exists "admin write jst_warehouses" on public."jst_warehouses";
drop policy if exists "delete jst_warehouses" on public."jst_warehouses";
drop policy if exists "insert jst_warehouses" on public."jst_warehouses";
drop policy if exists "internal read jst_warehouses" on public."jst_warehouses";
drop policy if exists "select jst_warehouses" on public."jst_warehouses";
drop policy if exists "update jst_warehouses" on public."jst_warehouses";
create policy "select jst_warehouses" on public."jst_warehouses"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert jst_warehouses" on public."jst_warehouses"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update jst_warehouses" on public."jst_warehouses"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete jst_warehouses" on public."jst_warehouses"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- ops_arrival_items -----
drop policy if exists "delete ops_arrival_items" on public."ops_arrival_items";
drop policy if exists "insert ops_arrival_items" on public."ops_arrival_items";
drop policy if exists "internal full arrival items" on public."ops_arrival_items";
drop policy if exists "select ops_arrival_items" on public."ops_arrival_items";
drop policy if exists "supplier reads own arrival items" on public."ops_arrival_items";
drop policy if exists "update ops_arrival_items" on public."ops_arrival_items";
create policy "select ops_arrival_items" on public."ops_arrival_items"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (EXISTS ( SELECT 1
   FROM ops_arrivals a
  WHERE ((a.id = ops_arrival_items.arrival_id) AND (a.supplier_id = supplier_id_of((select auth.uid()))))))));
create policy "insert ops_arrival_items" on public."ops_arrival_items"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update ops_arrival_items" on public."ops_arrival_items"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete ops_arrival_items" on public."ops_arrival_items"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- ops_arrivals -----
drop policy if exists "delete ops_arrivals" on public."ops_arrivals";
drop policy if exists "insert ops_arrivals" on public."ops_arrivals";
drop policy if exists "internal full arrivals" on public."ops_arrivals";
drop policy if exists "select ops_arrivals" on public."ops_arrivals";
drop policy if exists "supplier reads own arrivals" on public."ops_arrivals";
drop policy if exists "update ops_arrivals" on public."ops_arrivals";
create policy "select ops_arrivals" on public."ops_arrivals"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (supplier_id = supplier_id_of((select auth.uid())))));
create policy "insert ops_arrivals" on public."ops_arrivals"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update ops_arrivals" on public."ops_arrivals"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete ops_arrivals" on public."ops_arrivals"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- ops_params -----
drop policy if exists "admin write ops_params" on public."ops_params";
drop policy if exists "delete ops_params" on public."ops_params";
drop policy if exists "insert ops_params" on public."ops_params";
drop policy if exists "internal read ops_params" on public."ops_params";
drop policy if exists "select ops_params" on public."ops_params";
drop policy if exists "update ops_params" on public."ops_params";
create policy "select ops_params" on public."ops_params"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert ops_params" on public."ops_params"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update ops_params" on public."ops_params"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete ops_params" on public."ops_params"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- ops_product_mapping_exceptions -----
drop policy if exists "delete ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions";
drop policy if exists "insert ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions";
drop policy if exists "ops_admin_write_mapping_exceptions" on public."ops_product_mapping_exceptions";
drop policy if exists "ops_internal_read_mapping_exceptions" on public."ops_product_mapping_exceptions";
drop policy if exists "select ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions";
drop policy if exists "update ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions";
create policy "select ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete ops_product_mapping_exceptions" on public."ops_product_mapping_exceptions"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- ops_products -----
drop policy if exists "delete ops_products" on public."ops_products";
drop policy if exists "insert ops_products" on public."ops_products";
drop policy if exists "internal full products" on public."ops_products";
drop policy if exists "select ops_products" on public."ops_products";
drop policy if exists "supplier reads own products" on public."ops_products";
drop policy if exists "update ops_products" on public."ops_products";
create policy "select ops_products" on public."ops_products"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (supplier_id = supplier_id_of((select auth.uid())))));
create policy "insert ops_products" on public."ops_products"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update ops_products" on public."ops_products"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete ops_products" on public."ops_products"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- ops_sku_aliases -----
drop policy if exists "internal full aliases" on public."ops_sku_aliases";
create policy "internal full aliases" on public."ops_sku_aliases"
  as permissive for all to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));

-- ----- ops_skus -----
drop policy if exists "delete ops_skus" on public."ops_skus";
drop policy if exists "insert ops_skus" on public."ops_skus";
drop policy if exists "internal full skus" on public."ops_skus";
drop policy if exists "select ops_skus" on public."ops_skus";
drop policy if exists "supplier reads own skus" on public."ops_skus";
drop policy if exists "update ops_skus" on public."ops_skus";
create policy "select ops_skus" on public."ops_skus"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (EXISTS ( SELECT 1
   FROM ops_products p
  WHERE ((p.id = ops_skus.product_id) AND (p.supplier_id = supplier_id_of((select auth.uid()))))))));
create policy "insert ops_skus" on public."ops_skus"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update ops_skus" on public."ops_skus"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete ops_skus" on public."ops_skus"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- ops_supplier_bills -----
drop policy if exists "delete ops_supplier_bills" on public."ops_supplier_bills";
drop policy if exists "insert ops_supplier_bills" on public."ops_supplier_bills";
drop policy if exists "internal full bills" on public."ops_supplier_bills";
drop policy if exists "select ops_supplier_bills" on public."ops_supplier_bills";
drop policy if exists "supplier reads own bills" on public."ops_supplier_bills";
drop policy if exists "update ops_supplier_bills" on public."ops_supplier_bills";
create policy "select ops_supplier_bills" on public."ops_supplier_bills"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (supplier_id = supplier_id_of((select auth.uid())))));
create policy "insert ops_supplier_bills" on public."ops_supplier_bills"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update ops_supplier_bills" on public."ops_supplier_bills"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete ops_supplier_bills" on public."ops_supplier_bills"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- ops_supplier_confirm_audit_logs -----
drop policy if exists "internal read supplier confirm audit" on public."ops_supplier_confirm_audit_logs";
drop policy if exists "privileged insert supplier confirm audit" on public."ops_supplier_confirm_audit_logs";
create policy "internal read supplier confirm audit" on public."ops_supplier_confirm_audit_logs"
  as permissive for select to authenticated
  using (is_ops_internal((select auth.uid())));
create policy "privileged insert supplier confirm audit" on public."ops_supplier_confirm_audit_logs"
  as permissive for insert to authenticated
  with check ((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code))));

-- ----- ops_suppliers -----
drop policy if exists "delete ops_suppliers" on public."ops_suppliers";
drop policy if exists "insert ops_suppliers" on public."ops_suppliers";
drop policy if exists "privileged internal can read suppliers" on public."ops_suppliers";
drop policy if exists "privileged internal can write suppliers" on public."ops_suppliers";
drop policy if exists "select ops_suppliers" on public."ops_suppliers";
drop policy if exists "supplier sees own record" on public."ops_suppliers";
drop policy if exists "update ops_suppliers" on public."ops_suppliers";
create policy "select ops_suppliers" on public."ops_suppliers"
  as permissive for select to authenticated
  using (((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code) OR has_ops_role((select auth.uid()), 'finance'::ops_role_code)))
   OR (is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code)))
   OR (id = supplier_id_of((select auth.uid())))));
create policy "insert ops_suppliers" on public."ops_suppliers"
  as permissive for insert to authenticated
  with check ((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code))));
create policy "update ops_suppliers" on public."ops_suppliers"
  as permissive for update to authenticated
  using ((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code))))
  with check ((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code))));
create policy "delete ops_suppliers" on public."ops_suppliers"
  as permissive for delete to authenticated
  using ((is_ops_internal((select auth.uid())) AND (has_ops_role((select auth.uid()), 'admin'::ops_role_code) OR has_ops_role((select auth.uid()), 'ops'::ops_role_code))));

-- ----- ops_user_roles -----
drop policy if exists "see own ops roles" on public."ops_user_roles";
create policy "see own ops roles" on public."ops_user_roles"
  as permissive for select to authenticated
  using ((user_id = (select auth.uid())));

-- ----- order_lookup_index -----
drop policy if exists "admin write order_lookup_index" on public."order_lookup_index";
drop policy if exists "delete order_lookup_index" on public."order_lookup_index";
drop policy if exists "insert order_lookup_index" on public."order_lookup_index";
drop policy if exists "internal read order_lookup_index" on public."order_lookup_index";
drop policy if exists "select order_lookup_index" on public."order_lookup_index";
drop policy if exists "update order_lookup_index" on public."order_lookup_index";
create policy "select order_lookup_index" on public."order_lookup_index"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert order_lookup_index" on public."order_lookup_index"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update order_lookup_index" on public."order_lookup_index"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete order_lookup_index" on public."order_lookup_index"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- platforms -----
drop policy if exists "delete platforms" on public."platforms";
drop policy if exists "finance write platforms" on public."platforms";
drop policy if exists "insert platforms" on public."platforms";
drop policy if exists "internal read platforms" on public."platforms";
drop policy if exists "select platforms" on public."platforms";
drop policy if exists "update platforms" on public."platforms";
create policy "select platforms" on public."platforms"
  as permissive for select to authenticated
  using ((can_write_finance((select auth.uid()))
   OR (is_ops_internal((select auth.uid())) AND (deleted_at IS NULL))));
create policy "insert platforms" on public."platforms"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update platforms" on public."platforms"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete platforms" on public."platforms"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- profiles -----
drop policy if exists "Finance can view all profiles" on public."profiles";
drop policy if exists "Managers can view managed profiles" on public."profiles";
drop policy if exists "Users can update own profile" on public."profiles";
drop policy if exists "Users can view own profile" on public."profiles";
drop policy if exists "select profiles" on public."profiles";
create policy "select profiles" on public."profiles"
  as permissive for select to authenticated
  using ((has_role((select auth.uid()), 'finance'::app_role)
   OR (manager_id = (select auth.uid()))
   OR (id = (select auth.uid()))));
create policy "Users can update own profile" on public."profiles"
  as permissive for update to authenticated
  using ((id = (select auth.uid())));

-- ----- purchase_order_items -----
drop policy if exists "delete purchase_order_items" on public."purchase_order_items";
drop policy if exists "insert purchase_order_items" on public."purchase_order_items";
drop policy if exists "internal read all poi" on public."purchase_order_items";
drop policy if exists "internal write poi" on public."purchase_order_items";
drop policy if exists "select purchase_order_items" on public."purchase_order_items";
drop policy if exists "supplier read own poi" on public."purchase_order_items";
drop policy if exists "update purchase_order_items" on public."purchase_order_items";
create policy "select purchase_order_items" on public."purchase_order_items"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR (EXISTS ( SELECT 1
   FROM purchase_orders po
  WHERE ((po.id = purchase_order_items.purchase_order_id) AND (po.supplier_id IS NOT NULL) AND (po.supplier_id = supplier_id_of((select auth.uid()))))))));
create policy "insert purchase_order_items" on public."purchase_order_items"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update purchase_order_items" on public."purchase_order_items"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete purchase_order_items" on public."purchase_order_items"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- purchase_orders -----
drop policy if exists "delete purchase_orders" on public."purchase_orders";
drop policy if exists "insert purchase_orders" on public."purchase_orders";
drop policy if exists "internal read all purchase_orders" on public."purchase_orders";
drop policy if exists "internal write purchase_orders" on public."purchase_orders";
drop policy if exists "select purchase_orders" on public."purchase_orders";
drop policy if exists "supplier read own purchase_orders" on public."purchase_orders";
drop policy if exists "update purchase_orders" on public."purchase_orders";
create policy "select purchase_orders" on public."purchase_orders"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR ((supplier_id IS NOT NULL) AND (supplier_id = supplier_id_of((select auth.uid()))))));
create policy "insert purchase_orders" on public."purchase_orders"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update purchase_orders" on public."purchase_orders"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete purchase_orders" on public."purchase_orders"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- purchase_receipt_items -----
drop policy if exists "delete purchase_receipt_items" on public."purchase_receipt_items";
drop policy if exists "insert purchase_receipt_items" on public."purchase_receipt_items";
drop policy if exists "internal read all pri" on public."purchase_receipt_items";
drop policy if exists "internal write pri" on public."purchase_receipt_items";
drop policy if exists "select purchase_receipt_items" on public."purchase_receipt_items";
drop policy if exists "supplier read own pri" on public."purchase_receipt_items";
drop policy if exists "update purchase_receipt_items" on public."purchase_receipt_items";
create policy "select purchase_receipt_items" on public."purchase_receipt_items"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR ((purchase_order_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM purchase_orders po
  WHERE ((po.id = purchase_receipt_items.purchase_order_id) AND (po.supplier_id IS NOT NULL) AND (po.supplier_id = supplier_id_of((select auth.uid())))))))));
create policy "insert purchase_receipt_items" on public."purchase_receipt_items"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update purchase_receipt_items" on public."purchase_receipt_items"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete purchase_receipt_items" on public."purchase_receipt_items"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- purchase_receipts -----
drop policy if exists "delete purchase_receipts" on public."purchase_receipts";
drop policy if exists "insert purchase_receipts" on public."purchase_receipts";
drop policy if exists "internal read all pr" on public."purchase_receipts";
drop policy if exists "internal write pr" on public."purchase_receipts";
drop policy if exists "select purchase_receipts" on public."purchase_receipts";
drop policy if exists "supplier read own pr" on public."purchase_receipts";
drop policy if exists "update purchase_receipts" on public."purchase_receipts";
create policy "select purchase_receipts" on public."purchase_receipts"
  as permissive for select to authenticated
  using ((is_ops_internal((select auth.uid()))
   OR ((purchase_order_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM purchase_orders po
  WHERE ((po.id = purchase_receipts.purchase_order_id) AND (po.supplier_id IS NOT NULL) AND (po.supplier_id = supplier_id_of((select auth.uid())))))))));
create policy "insert purchase_receipts" on public."purchase_receipts"
  as permissive for insert to authenticated
  with check (is_ops_internal((select auth.uid())));
create policy "update purchase_receipts" on public."purchase_receipts"
  as permissive for update to authenticated
  using (is_ops_internal((select auth.uid())))
  with check (is_ops_internal((select auth.uid())));
create policy "delete purchase_receipts" on public."purchase_receipts"
  as permissive for delete to authenticated
  using (is_ops_internal((select auth.uid())));

-- ----- sales_daily_summary -----
drop policy if exists "admin write sales_daily_summary" on public."sales_daily_summary";
drop policy if exists "delete sales_daily_summary" on public."sales_daily_summary";
drop policy if exists "insert sales_daily_summary" on public."sales_daily_summary";
drop policy if exists "internal read sales_daily_summary" on public."sales_daily_summary";
drop policy if exists "select sales_daily_summary" on public."sales_daily_summary";
drop policy if exists "update sales_daily_summary" on public."sales_daily_summary";
create policy "select sales_daily_summary" on public."sales_daily_summary"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert sales_daily_summary" on public."sales_daily_summary"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update sales_daily_summary" on public."sales_daily_summary"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete sales_daily_summary" on public."sales_daily_summary"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- sales_hourly_summary -----
drop policy if exists "admin write sales_hourly_summary" on public."sales_hourly_summary";
drop policy if exists "delete sales_hourly_summary" on public."sales_hourly_summary";
drop policy if exists "insert sales_hourly_summary" on public."sales_hourly_summary";
drop policy if exists "internal read sales_hourly_summary" on public."sales_hourly_summary";
drop policy if exists "select sales_hourly_summary" on public."sales_hourly_summary";
drop policy if exists "update sales_hourly_summary" on public."sales_hourly_summary";
create policy "select sales_hourly_summary" on public."sales_hourly_summary"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert sales_hourly_summary" on public."sales_hourly_summary"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update sales_hourly_summary" on public."sales_hourly_summary"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete sales_hourly_summary" on public."sales_hourly_summary"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- sales_order_light_items -----
drop policy if exists "admin write sales_order_light_items" on public."sales_order_light_items";
drop policy if exists "delete sales_order_light_items" on public."sales_order_light_items";
drop policy if exists "insert sales_order_light_items" on public."sales_order_light_items";
drop policy if exists "internal read sales_order_light_items" on public."sales_order_light_items";
drop policy if exists "select sales_order_light_items" on public."sales_order_light_items";
drop policy if exists "update sales_order_light_items" on public."sales_order_light_items";
create policy "select sales_order_light_items" on public."sales_order_light_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert sales_order_light_items" on public."sales_order_light_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update sales_order_light_items" on public."sales_order_light_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete sales_order_light_items" on public."sales_order_light_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- sales_sku_daily_summary -----
drop policy if exists "admin write sales_sku_daily_summary" on public."sales_sku_daily_summary";
drop policy if exists "delete sales_sku_daily_summary" on public."sales_sku_daily_summary";
drop policy if exists "insert sales_sku_daily_summary" on public."sales_sku_daily_summary";
drop policy if exists "internal read sales_sku_daily_summary" on public."sales_sku_daily_summary";
drop policy if exists "select sales_sku_daily_summary" on public."sales_sku_daily_summary";
drop policy if exists "update sales_sku_daily_summary" on public."sales_sku_daily_summary";
create policy "select sales_sku_daily_summary" on public."sales_sku_daily_summary"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert sales_sku_daily_summary" on public."sales_sku_daily_summary"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update sales_sku_daily_summary" on public."sales_sku_daily_summary"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete sales_sku_daily_summary" on public."sales_sku_daily_summary"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- sales_style_daily_summary -----
drop policy if exists "admin write sales_style_daily_summary" on public."sales_style_daily_summary";
drop policy if exists "delete sales_style_daily_summary" on public."sales_style_daily_summary";
drop policy if exists "insert sales_style_daily_summary" on public."sales_style_daily_summary";
drop policy if exists "internal read sales_style_daily_summary" on public."sales_style_daily_summary";
drop policy if exists "select sales_style_daily_summary" on public."sales_style_daily_summary";
drop policy if exists "update sales_style_daily_summary" on public."sales_style_daily_summary";
create policy "select sales_style_daily_summary" on public."sales_style_daily_summary"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert sales_style_daily_summary" on public."sales_style_daily_summary"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update sales_style_daily_summary" on public."sales_style_daily_summary"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete sales_style_daily_summary" on public."sales_style_daily_summary"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- shipping_risk_orders -----
drop policy if exists "admin write shipping_risk_orders" on public."shipping_risk_orders";
drop policy if exists "delete shipping_risk_orders" on public."shipping_risk_orders";
drop policy if exists "insert shipping_risk_orders" on public."shipping_risk_orders";
drop policy if exists "internal read shipping_risk_orders" on public."shipping_risk_orders";
drop policy if exists "select shipping_risk_orders" on public."shipping_risk_orders";
drop policy if exists "update shipping_risk_orders" on public."shipping_risk_orders";
create policy "select shipping_risk_orders" on public."shipping_risk_orders"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert shipping_risk_orders" on public."shipping_risk_orders"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update shipping_risk_orders" on public."shipping_risk_orders"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete shipping_risk_orders" on public."shipping_risk_orders"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- shop_bank_account_bindings -----
drop policy if exists "delete shop_bank_account_bindings" on public."shop_bank_account_bindings";
drop policy if exists "finance write shop_bank_account_bindings" on public."shop_bank_account_bindings";
drop policy if exists "insert shop_bank_account_bindings" on public."shop_bank_account_bindings";
drop policy if exists "internal read shop_bank_account_bindings" on public."shop_bank_account_bindings";
drop policy if exists "select shop_bank_account_bindings" on public."shop_bank_account_bindings";
drop policy if exists "update shop_bank_account_bindings" on public."shop_bank_account_bindings";
create policy "select shop_bank_account_bindings" on public."shop_bank_account_bindings"
  as permissive for select to authenticated
  using ((can_write_finance((select auth.uid()))
   OR is_ops_internal((select auth.uid()))));
create policy "insert shop_bank_account_bindings" on public."shop_bank_account_bindings"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update shop_bank_account_bindings" on public."shop_bank_account_bindings"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete shop_bank_account_bindings" on public."shop_bank_account_bindings"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- shops -----
drop policy if exists "delete shops" on public."shops";
drop policy if exists "finance write shops" on public."shops";
drop policy if exists "insert shops" on public."shops";
drop policy if exists "internal read shops" on public."shops";
drop policy if exists "select shops" on public."shops";
drop policy if exists "update shops" on public."shops";
create policy "select shops" on public."shops"
  as permissive for select to authenticated
  using ((can_write_finance((select auth.uid()))
   OR (is_ops_internal((select auth.uid())) AND (deleted_at IS NULL))));
create policy "insert shops" on public."shops"
  as permissive for insert to authenticated
  with check (can_write_finance((select auth.uid())));
create policy "update shops" on public."shops"
  as permissive for update to authenticated
  using (can_write_finance((select auth.uid())))
  with check (can_write_finance((select auth.uid())));
create policy "delete shops" on public."shops"
  as permissive for delete to authenticated
  using (can_write_finance((select auth.uid())));

-- ----- user_roles -----
drop policy if exists "Users can view own roles" on public."user_roles";
create policy "Users can view own roles" on public."user_roles"
  as permissive for select to authenticated
  using ((user_id = (select auth.uid())));

-- ----- warehouse_shipping_package_items -----
drop policy if exists "admin write warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
drop policy if exists "delete warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
drop policy if exists "insert warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
drop policy if exists "internal read warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
drop policy if exists "select warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
drop policy if exists "update warehouse_shipping_package_items" on public."warehouse_shipping_package_items";
create policy "select warehouse_shipping_package_items" on public."warehouse_shipping_package_items"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert warehouse_shipping_package_items" on public."warehouse_shipping_package_items"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update warehouse_shipping_package_items" on public."warehouse_shipping_package_items"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete warehouse_shipping_package_items" on public."warehouse_shipping_package_items"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));

-- ----- warehouse_shipping_packages -----
drop policy if exists "admin write warehouse_shipping_packages" on public."warehouse_shipping_packages";
drop policy if exists "delete warehouse_shipping_packages" on public."warehouse_shipping_packages";
drop policy if exists "insert warehouse_shipping_packages" on public."warehouse_shipping_packages";
drop policy if exists "internal read warehouse_shipping_packages" on public."warehouse_shipping_packages";
drop policy if exists "select warehouse_shipping_packages" on public."warehouse_shipping_packages";
drop policy if exists "update warehouse_shipping_packages" on public."warehouse_shipping_packages";
create policy "select warehouse_shipping_packages" on public."warehouse_shipping_packages"
  as permissive for select to authenticated
  using ((has_ops_role((select auth.uid()), 'admin'::ops_role_code)
   OR is_ops_internal((select auth.uid()))));
create policy "insert warehouse_shipping_packages" on public."warehouse_shipping_packages"
  as permissive for insert to authenticated
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "update warehouse_shipping_packages" on public."warehouse_shipping_packages"
  as permissive for update to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code))
  with check (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
create policy "delete warehouse_shipping_packages" on public."warehouse_shipping_packages"
  as permissive for delete to authenticated
  using (has_ops_role((select auth.uid()), 'admin'::ops_role_code));
