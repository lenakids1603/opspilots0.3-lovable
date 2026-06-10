export type AppRole = 'employee' | 'manager' | 'finance';
export type UserType = 'internal' | 'supplier';

export interface Profile {
  id: string;
  full_name: string;
  department: string;
  manager_id: string | null;
  username: string | null;
  phone: string | null;
  user_type: UserType;
  created_at: string;
  updated_at: string;
}

export interface UserRole {
  id: string;
  user_id: string;
  role: AppRole;
}

// ===== Legacy expense template stubs (dead code, retained for type compatibility) =====
export type ExpenseStatus = 'draft' | 'submitted' | 'pending_manager' | 'pending_finance' | 'approved' | 'rejected' | 'paid';
export type ExpenseCategory = string;
export interface Expense {
  id: string;
  user_id: string;
  category_id?: string | null;
  amount: number;
  currency?: string;
  description?: string | null;
  status: ExpenseStatus;
  submitted_at?: string | null;
  approved_at?: string | null;
  paid_at?: string | null;
  created_at: string;
  updated_at: string;
  [k: string]: any;
}
export interface ApprovalAction {
  id: string;
  expense_id: string;
  user_id: string;
  action: string;
  comment?: string | null;
  created_at: string;
  [k: string]: any;
}
export interface AuditLog {
  id: string;
  user_id?: string | null;
  action: string;
  details?: any;
  created_at: string;
  [k: string]: any;
}
export const STATUS_CONFIG: Record<string, { label: string; color: string; variant?: any }> = {
  draft: { label: '草稿', color: 'gray' },
  submitted: { label: '已提交', color: 'blue' },
  pending_manager: { label: '待经理审批', color: 'yellow' },
  pending_finance: { label: '待财务审批', color: 'yellow' },
  approved: { label: '已批准', color: 'green' },
  rejected: { label: '已拒绝', color: 'red' },
  paid: { label: '已支付', color: 'green' },
};
