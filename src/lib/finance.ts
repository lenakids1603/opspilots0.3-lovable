export type CashDirection = "in" | "out" | "transfer";

export interface BusinessEntity {
  id: string;
  name: string;
  code: string | null;
  entity_type: "individual" | "company";
  legal_person: string | null;
  annual_flow_limit: number;
  status: string;
  remark: string | null;
}

export interface BankAccount {
  id: string;
  entity_id: string;
  account_name: string;
  bank_name: string | null;
  account_no_masked: string | null;
  currency: string;
  current_balance: number;
  status: string;
}

export interface Platform {
  id: string;
  code: string;
  name: string;
  status: string;
}

export interface Shop {
  id: string;
  entity_id: string;
  platform_id: string;
  name: string;
  code: string | null;
  status: string;
}

export interface CashTxCategory {
  id: string;
  code: string;
  name: string;
  direction: CashDirection;
  sort_order: number;
  status: string;
}

export interface CashTransaction {
  id: string;
  tx_no: string | null;
  entity_id: string;
  bank_account_id: string;
  direction: CashDirection;
  amount: number;
  currency: string;
  occurred_at: string;
  category_id: string | null;
  shop_id: string | null;
  supplier_id: string | null;
  counterparty: string | null;
  summary: string | null;
  attachment_path: string | null;
  status: string;
  remark: string | null;
  created_at: string;
}

export const DIRECTION_LABEL: Record<CashDirection, string> = {
  in: "收入",
  out: "支出",
  transfer: "内部转账",
};

export const DIRECTION_COLOR: Record<CashDirection, string> = {
  in: "text-emerald-600",
  out: "text-rose-600",
  transfer: "text-violet-600",
};

export const fmtMoney = (n: number, currency = "CNY") => {
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  return `${sign}${currency === "CNY" ? "¥" : ""}${abs.toLocaleString("zh-CN", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
};
