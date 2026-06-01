import { useCallback, useEffect, useState } from "react";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { Plus, Pencil, Trash2, X } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "@/hooks/use-toast";
import { fmtMoney } from "@/lib/finance";

type AnyRow = Record<string, any>;
type FieldDef = {
  key: string;
  label: string;
  type?: "text" | "number" | "select" | "textarea";
  required?: boolean;
  options?: { value: string; label: string }[];
  render?: (v: any, row: AnyRow) => React.ReactNode;
  default?: any;
};

export default function FinanceMasterDataPage() {
  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-bold">财务基础资料</h1>
        <p className="text-[12px] text-muted-foreground mt-1">维护经营主体、银行账户、店铺、收支分类</p>
      </div>

      <Tabs defaultValue="entities">
        <TabsList>
          <TabsTrigger value="entities">经营主体</TabsTrigger>
          <TabsTrigger value="banks">银行账户</TabsTrigger>
          <TabsTrigger value="shops">店铺</TabsTrigger>
          <TabsTrigger value="categories">收支分类</TabsTrigger>
        </TabsList>

        <TabsContent value="entities"><EntitiesTab /></TabsContent>
        <TabsContent value="banks"><BanksTab /></TabsContent>
        <TabsContent value="shops"><ShopsTab /></TabsContent>
        <TabsContent value="categories"><CategoriesTab /></TabsContent>
      </Tabs>
    </div>
  );
}

/* ---------- Generic CRUD table ---------- */
function CrudTable({
  table, columns, fields, title,
}: {
  table: string;
  columns: { key: string; label: string; render?: (v: any, r: AnyRow) => React.ReactNode; className?: string }[];
  fields: FieldDef[];
  title: string;
}) {
  const [rows, setRows] = useState<AnyRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<AnyRow | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.from(table as any).select("*")
      .is("deleted_at", null).order("created_at", { ascending: false });
    setLoading(false);
    if (error) { toast({ title: "加载失败", description: error.message, variant: "destructive" }); return; }
    setRows(data ?? []);
  }, [table]);

  useEffect(() => { load(); }, [load]);

  const handleDelete = async (r: AnyRow) => {
    if (!confirm(`确认删除？`)) return;
    const { error } = await supabase.from(table as any)
      .update({ deleted_at: new Date().toISOString() } as any).eq("id", r.id);
    if (error) { toast({ title: "删除失败", description: error.message, variant: "destructive" }); return; }
    toast({ title: "已删除" }); load();
  };

  return (
    <Card className="overflow-hidden">
      <div className="flex items-center justify-between px-4 py-3 border-b">
        <div className="text-[13px] font-medium">{title} · 共 {rows.length} 条</div>
        <Button size="sm" onClick={() => { setEditing(null); setOpen(true); }}>
          <Plus className="w-4 h-4 mr-1" /> 新增
        </Button>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-[12.5px]">
          <thead className="bg-muted/40 text-muted-foreground">
            <tr className="text-left">
              {columns.map(c => <th key={c.key} className={`px-3 py-2.5 font-normal ${c.className ?? ""}`}>{c.label}</th>)}
              <th className="px-3 py-2.5 font-normal text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            {loading && <tr><td colSpan={columns.length + 1} className="text-center py-8 text-muted-foreground">加载中...</td></tr>}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={columns.length + 1} className="text-center py-12 text-muted-foreground">暂无数据</td></tr>
            )}
            {rows.map(r => (
              <tr key={r.id} className="border-t hover:bg-muted/30">
                {columns.map(c => (
                  <td key={c.key} className={`px-3 py-2.5 ${c.className ?? ""}`}>
                    {c.render ? c.render(r[c.key], r) : (r[c.key] ?? "-")}
                  </td>
                ))}
                <td className="px-3 py-2.5 text-right">
                  <button onClick={() => { setEditing(r); setOpen(true); }} className="w-7 h-7 rounded-md hover:bg-muted inline-flex items-center justify-center">
                    <Pencil className="w-3.5 h-3.5" />
                  </button>
                  <button onClick={() => handleDelete(r)} className="w-7 h-7 rounded-md hover:bg-muted text-rose-500 inline-flex items-center justify-center">
                    <Trash2 className="w-3.5 h-3.5" />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <EditDrawer open={open} onOpenChange={setOpen} table={table} fields={fields}
        initial={editing} title={title} onSaved={load} />
    </Card>
  );
}

function EditDrawer({
  open, onOpenChange, table, fields, initial, title, onSaved,
}: {
  open: boolean; onOpenChange: (v: boolean) => void;
  table: string; fields: FieldDef[]; initial: AnyRow | null; title: string; onSaved: () => void;
}) {
  const [form, setForm] = useState<AnyRow>({});
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    if (initial) setForm({ ...initial });
    else {
      const init: AnyRow = {};
      fields.forEach(f => { init[f.key] = f.default ?? ""; });
      setForm(init);
    }
  }, [open, initial, fields]);

  const handleSave = async () => {
    for (const f of fields) {
      if (f.required && !form[f.key] && form[f.key] !== 0) {
        toast({ title: `${f.label} 必填`, variant: "destructive" }); return;
      }
    }
    setSaving(true);
    const payload: AnyRow = {};
    fields.forEach(f => {
      let v = form[f.key];
      if (f.type === "number") v = v === "" || v == null ? null : Number(v);
      if (v === "") v = null;
      payload[f.key] = v;
    });
    const res = initial
      ? await supabase.from(table as any).update(payload).eq("id", initial.id)
      : await supabase.from(table as any).insert(payload);
    setSaving(false);
    if (res.error) { toast({ title: "保存失败", description: res.error.message, variant: "destructive" }); return; }
    toast({ title: initial ? "已更新" : "已新增" });
    onSaved(); onOpenChange(false);
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-full sm:max-w-md p-0 flex flex-col">
        <div className="px-6 py-4 border-b flex justify-between items-start">
          <h2 className="text-[15px] font-semibold">{initial ? "编辑" : "新增"} · {title}</h2>
          <button onClick={() => onOpenChange(false)} className="w-8 h-8 rounded-md hover:bg-muted flex items-center justify-center">
            <X className="w-4 h-4" />
          </button>
        </div>
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          {fields.map(f => (
            <div key={f.key}>
              <label className="block text-[12px] text-foreground/80 mb-1.5">
                {f.label}{f.required && <span className="text-rose-500 ml-0.5">*</span>}
              </label>
              {f.type === "select" ? (
                <select value={form[f.key] ?? ""} onChange={e => setForm(s => ({ ...s, [f.key]: e.target.value }))}
                  className="h-10 w-full rounded-md border border-border bg-white px-3 text-[13px]">
                  <option value="">-- 选择 --</option>
                  {f.options?.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
                </select>
              ) : f.type === "textarea" ? (
                <textarea value={form[f.key] ?? ""} onChange={e => setForm(s => ({ ...s, [f.key]: e.target.value }))}
                  rows={3} className="w-full rounded-md border border-border bg-white px-3 py-2 text-[13px]" />
              ) : (
                <Input type={f.type === "number" ? "number" : "text"} value={form[f.key] ?? ""}
                  onChange={e => setForm(s => ({ ...s, [f.key]: e.target.value }))} className="h-10" />
              )}
            </div>
          ))}
        </div>
        <div className="px-6 py-3 border-t bg-muted/30 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => onOpenChange(false)}>取消</Button>
          <Button onClick={handleSave} disabled={saving}>{saving ? "保存中..." : "保存"}</Button>
        </div>
      </SheetContent>
    </Sheet>
  );
}

/* ---------- Tabs ---------- */
function EntitiesTab() {
  return (
    <div className="mt-4">
      <CrudTable
        title="经营主体"
        table="business_entities"
        columns={[
          { key: "name", label: "主体名称" },
          { key: "code", label: "编码" },
          { key: "entity_type", label: "类型", render: v => v === "individual" ? "个体户" : "公司" },
          { key: "legal_person", label: "法人" },
          { key: "annual_flow_limit", label: "年度额度", render: v => fmtMoney(Number(v ?? 0)) },
          { key: "status", label: "状态" },
        ]}
        fields={[
          { key: "name", label: "主体名称", required: true },
          { key: "code", label: "编码" },
          { key: "entity_type", label: "类型", type: "select", required: true, default: "individual",
            options: [{ value: "individual", label: "个体户" }, { value: "company", label: "公司" }] },
          { key: "legal_person", label: "法人" },
          { key: "registration_no", label: "注册号" },
          { key: "tax_no", label: "税号" },
          { key: "annual_flow_limit", label: "年度流水额度", type: "number", default: 5000000 },
          { key: "status", label: "状态", type: "select", default: "active",
            options: [{ value: "active", label: "启用" }, { value: "disabled", label: "停用" }] },
          { key: "remark", label: "备注", type: "textarea" },
        ]}
      />
    </div>
  );
}

function BanksTab() {
  const [entities, setEntities] = useState<{ value: string; label: string }[]>([]);
  useEffect(() => {
    supabase.from("business_entities").select("id,name").is("deleted_at", null).order("name")
      .then(({ data }) => setEntities((data ?? []).map(e => ({ value: e.id, label: e.name }))));
  }, []);

  return (
    <div className="mt-4">
      <CrudTable
        title="银行账户"
        table="bank_accounts"
        columns={[
          { key: "account_name", label: "账户名" },
          { key: "bank_name", label: "开户行" },
          { key: "account_no_masked", label: "账号尾段" },
          { key: "currency", label: "币种" },
          { key: "current_balance", label: "当前余额", render: v => fmtMoney(Number(v ?? 0)) },
          { key: "status", label: "状态" },
        ]}
        fields={[
          { key: "entity_id", label: "所属主体", type: "select", required: true, options: entities },
          { key: "account_name", label: "账户名", required: true },
          { key: "bank_name", label: "开户行" },
          { key: "account_no_masked", label: "账号（仅尾段 / 脱敏）" },
          { key: "account_type", label: "账户类型", type: "select", default: "bank",
            options: [
              { value: "bank", label: "银行" }, { value: "alipay", label: "支付宝" },
              { value: "wechat", label: "微信" }, { value: "cash", label: "现金" },
            ] },
          { key: "currency", label: "币种", default: "CNY" },
          { key: "current_balance", label: "当前余额（手动维护）", type: "number", default: 0 },
          { key: "status", label: "状态", type: "select", default: "active",
            options: [{ value: "active", label: "启用" }, { value: "disabled", label: "停用" }] },
          { key: "remark", label: "备注", type: "textarea" },
        ]}
      />
    </div>
  );
}

function ShopsTab() {
  const [entities, setEntities] = useState<{ value: string; label: string }[]>([]);
  const [platforms, setPlatforms] = useState<{ value: string; label: string }[]>([]);
  useEffect(() => {
    supabase.from("business_entities").select("id,name").is("deleted_at", null).order("name")
      .then(({ data }) => setEntities((data ?? []).map(e => ({ value: e.id, label: e.name }))));
    supabase.from("platforms").select("id,name").is("deleted_at", null).order("name")
      .then(({ data }) => setPlatforms((data ?? []).map(p => ({ value: p.id, label: p.name }))));
  }, []);

  return (
    <div className="mt-4">
      <CrudTable
        title="店铺"
        table="shops"
        columns={[
          { key: "name", label: "店铺名" },
          { key: "code", label: "店铺编码" },
          { key: "external_shop_id", label: "外部店铺 ID" },
          { key: "status", label: "状态" },
        ]}
        fields={[
          { key: "entity_id", label: "所属主体", type: "select", required: true, options: entities },
          { key: "platform_id", label: "所属平台", type: "select", required: true, options: platforms },
          { key: "name", label: "店铺名", required: true },
          { key: "code", label: "店铺编码" },
          { key: "external_shop_id", label: "外部店铺 ID" },
          { key: "status", label: "状态", type: "select", default: "active",
            options: [{ value: "active", label: "启用" }, { value: "disabled", label: "停用" }] },
          { key: "remark", label: "备注", type: "textarea" },
        ]}
      />
    </div>
  );
}

function CategoriesTab() {
  return (
    <div className="mt-4">
      <CrudTable
        title="收支分类"
        table="cash_tx_categories"
        columns={[
          { key: "name", label: "名称" },
          { key: "code", label: "代码" },
          { key: "direction", label: "方向", render: v => v === "in" ? "收入" : v === "out" ? "支出" : "转账" },
          { key: "sort_order", label: "排序" },
          { key: "status", label: "状态" },
        ]}
        fields={[
          { key: "code", label: "代码", required: true },
          { key: "name", label: "名称", required: true },
          { key: "direction", label: "方向", type: "select", required: true, default: "out",
            options: [{ value: "in", label: "收入" }, { value: "out", label: "支出" }, { value: "transfer", label: "内部转账" }] },
          { key: "sort_order", label: "排序", type: "number", default: 100 },
          { key: "status", label: "状态", type: "select", default: "active",
            options: [{ value: "active", label: "启用" }, { value: "disabled", label: "停用" }] },
        ]}
      />
    </div>
  );
}
