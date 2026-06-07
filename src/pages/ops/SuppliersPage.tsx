import { useEffect, useMemo, useState } from "react";
import { PageHeader } from "@/components/ops/PageHeader";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Card, CardContent } from "@/components/ui/card";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { Power, PowerOff, Pencil, Info, Loader2, Eye } from "lucide-react";

type Supplier = {
  id: string;
  jst_supplier_id: string | null;
  code: string;
  name: string;
  contact: string | null;
  phone: string | null;
  address: string | null;
  email: string | null;
  status: string;
  confirm_status: "unconfirmed" | "confirmed" | "archived";
  confirmed_at: string | null;
  archived_at: string | null;
  archived_reason: string;
  remark: string | null;
  manual_contact_name: string;
  manual_contact_phone: string;
  manual_address: string;
  raw_jst_json: any;
  last_synced_at: string | null;
};

type AuditRow = {
  id: string; supplier_id: string; old_confirm_status: string; new_confirm_status: string;
  reason: string; operated_by: string | null; operated_at: string;
};

const erpStatusOf = (r: Pick<Supplier, "confirm_status">): "enabled" | "disabled" =>
  r.confirm_status === "confirmed" ? "enabled" : "disabled";

const TAB_LABEL: Record<string, string> = { enabled: "已启用", disabled: "已禁用", all: "全部" };

const DISABLE_REASONS = ["历史供应商", "暂不合作", "聚水潭已停用", "测试供应商", "重复供应商", "其他"];
const ENABLE_REMARKS = ["核心供应商", "当前合作供应商", "财务已确认", "其他"];

export default function SuppliersPage() {
  const [rows, setRows] = useState<Supplier[]>([]);
  const [audits, setAudits] = useState<AuditRow[]>([]);
  const [tab, setTab] = useState<string>("enabled");
  const [keyword, setKeyword] = useState("");
  const [jstFilter, setJstFilter] = useState<string>("all");
  const [loading, setLoading] = useState(false);

  const [actionRow, setActionRow] = useState<Supplier | null>(null);
  const [actionType, setActionType] = useState<"enable" | "disable" | null>(null);
  const [reason, setReason] = useState("");
  const [reasonPreset, setReasonPreset] = useState<string>("");
  const [submitting, setSubmitting] = useState(false);

  const [editRow, setEditRow] = useState<Supplier | null>(null);
  const [editForm, setEditForm] = useState({ manual_contact_name: "", manual_contact_phone: "", manual_address: "", remark: "" });

  const [detailRow, setDetailRow] = useState<Supplier | null>(null);
  const [showRaw, setShowRaw] = useState(false);

  const load = async () => {
    setLoading(true);
    const [s, a] = await Promise.all([
      supabase.from("ops_suppliers").select("*").order("updated_at", { ascending: false }),
      supabase.from("ops_supplier_confirm_audit_logs").select("*")
        .order("operated_at", { ascending: false }).limit(500),
    ]);
    setRows((s.data as any) ?? []);
    setAudits((a.data as any) ?? []);
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const stats = useMemo(() => {
    const enabled = rows.filter(r => erpStatusOf(r) === "enabled").length;
    const disabled = rows.length - enabled;
    const jst = rows.filter(r => r.jst_supplier_id);
    const jstActive = jst.filter(r => r.status === "active").length;
    const jstDisabled = jst.filter(r => r.status === "disabled").length;
    return { enabled, disabled, jstTotal: jst.length, jstActive, jstDisabled };
  }, [rows]);

  // 默认启用 tab，但若无启用则切到 disabled 一次
  useEffect(() => {
    if (!loading && stats.enabled === 0 && tab === "enabled" && rows.length > 0) setTab("disabled");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading, rows.length]);

  const filtered = useMemo(() => {
    const kw = keyword.trim().toLowerCase();
    return rows
      .filter(r => {
        const erp = erpStatusOf(r);
        if (tab === "all") return true;
        return erp === tab;
      })
      .filter(r => jstFilter === "all" || r.status === jstFilter)
      .filter(r => !kw || [
        r.name, r.code, r.jst_supplier_id,
        r.manual_contact_name || r.contact,
        r.manual_contact_phone || r.phone,
        r.manual_address || r.address,
      ].filter(Boolean).some(v => String(v).toLowerCase().includes(kw)));
  }, [rows, tab, keyword, jstFilter]);

  const displayContact = (r: Supplier) => r.manual_contact_name || r.contact || "";
  const displayPhone = (r: Supplier) => r.manual_contact_phone || r.phone || "";
  const displayAddress = (r: Supplier) => r.manual_address || r.address || "";

  const openAction = (row: Supplier, type: "enable" | "disable") => {
    setActionRow(row); setActionType(type); setReason(""); setReasonPreset("");
  };

  const submitAction = async () => {
    if (!actionRow || !actionType) return;
    setSubmitting(true);
    try {
      const { data: u } = await supabase.auth.getUser();
      const uid = u.user?.id ?? null;
      const now = new Date().toISOString();
      const oldStatus = actionRow.confirm_status;
      let patch: any = {};
      let newStatus: Supplier["confirm_status"];
      const finalReason = reasonPreset === "其他" || reasonPreset === "" ? reason.trim() : reasonPreset + (reason.trim() ? `：${reason.trim()}` : "");

      if (actionType === "enable") {
        newStatus = "confirmed";
        patch = { confirm_status: newStatus, confirmed_by: uid, confirmed_at: now, archived_reason: "", archived_at: null, archived_by: null };
      } else {
        if (!finalReason) { toast.error("请填写禁用原因"); setSubmitting(false); return; }
        newStatus = "archived";
        patch = { confirm_status: newStatus, archived_reason: finalReason, archived_at: now, archived_by: uid };
      }

      const { error } = await supabase.from("ops_suppliers").update(patch).eq("id", actionRow.id);
      if (error) throw error;

      await supabase.from("ops_supplier_confirm_audit_logs").insert({
        supplier_id: actionRow.id,
        old_confirm_status: oldStatus,
        new_confirm_status: newStatus,
        reason: finalReason || (actionType === "enable" ? "启用为有效供应商" : "禁用"),
        operated_by: uid,
      });

      toast.success(actionType === "enable" ? "已启用" : "已禁用");
      setActionRow(null); setActionType(null);
      await load();
    } catch (e: any) {
      toast.error(e?.message ?? "操作失败");
    } finally {
      setSubmitting(false);
    }
  };

  const openEdit = (r: Supplier) => {
    setEditRow(r);
    setEditForm({
      manual_contact_name: r.manual_contact_name ?? "",
      manual_contact_phone: r.manual_contact_phone ?? "",
      manual_address: r.manual_address ?? "",
      remark: r.remark ?? "",
    });
  };
  const submitEdit = async () => {
    if (!editRow) return;
    setSubmitting(true);
    try {
      const { error } = await supabase.from("ops_suppliers").update(editForm).eq("id", editRow.id);
      if (error) throw error;
      toast.success("已保存");
      setEditRow(null);
      await load();
    } catch (e: any) { toast.error(e?.message ?? "保存失败"); }
    finally { setSubmitting(false); }
  };

  const auditFor = (id: string) => audits.filter(a => a.supplier_id === id);

  return (
    <div>
      <PageHeader
        breadcrumb={["供应商系统", "供应商档案"]}
        title="供应商档案"
        description="管理 ERP 当前可用的供应商"
      />

      <Alert className="mb-4">
        <Info className="h-4 w-4" />
        <AlertTitle>关于供应商范围</AlertTitle>
        <AlertDescription>
          这里管理 ERP 当前可用的供应商。聚水潭会同步所有历史供应商，但只有启用后的供应商才会进入供应商账号、账单核对、采购入库核对和付款记录。
        </AlertDescription>
      </Alert>

      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
        {[
          { label: "ERP 已启用", value: stats.enabled, accent: "text-emerald-600" },
          { label: "ERP 已禁用", value: stats.disabled, accent: "text-muted-foreground" },
          { label: "聚水潭原始供应商", value: stats.jstTotal },
          { label: "聚水潭 active", value: stats.jstActive },
          { label: "聚水潭 disabled", value: stats.jstDisabled },
        ].map((s, i) => (
          <Card key={i}>
            <CardContent className="p-3">
              <div className="text-xs text-muted-foreground">{s.label}</div>
              <div className={`text-2xl font-semibold mt-1 ${s.accent ?? ""}`}>{s.value}</div>
            </CardContent>
          </Card>
        ))}
      </div>

      <div className="flex items-center gap-3 mb-3 flex-wrap">
        <Input
          placeholder="搜索名称 / 联系人 / 电话 / 地址 / 编码 / 聚水潭ID"
          value={keyword}
          onChange={(e) => setKeyword(e.target.value)}
          className="max-w-sm"
        />
        <div className="flex items-center gap-2 text-sm">
          <span className="text-muted-foreground">聚水潭状态</span>
          <Select value={jstFilter} onValueChange={setJstFilter}>
            <SelectTrigger className="w-32 h-9"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">全部</SelectItem>
              <SelectItem value="active">active</SelectItem>
              <SelectItem value="disabled">disabled</SelectItem>
            </SelectContent>
          </Select>
        </div>
        {loading && <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />}
      </div>

      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="enabled">已启用 <span className="ml-1.5 text-xs opacity-60">{stats.enabled}</span></TabsTrigger>
          <TabsTrigger value="disabled">已禁用 <span className="ml-1.5 text-xs opacity-60">{stats.disabled}</span></TabsTrigger>
          <TabsTrigger value="all">全部 <span className="ml-1.5 text-xs opacity-60">{rows.length}</span></TabsTrigger>
        </TabsList>

        {stats.enabled === 0 && tab === "disabled" && (
          <Alert className="mt-3">
            <Info className="h-4 w-4" />
            <AlertDescription>当前还没有启用供应商，请从禁用列表中启用常用供应商。</AlertDescription>
          </Alert>
        )}

        <TabsContent value={tab} className="mt-3">
          <div className="border rounded-md bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>供应商名称</TableHead>
                  <TableHead>联系人</TableHead>
                  <TableHead>联系电话</TableHead>
                  <TableHead>地址</TableHead>
                  <TableHead>聚水潭状态</TableHead>
                  <TableHead>ERP 状态</TableHead>
                  <TableHead>备注</TableHead>
                  <TableHead className="text-right">操作</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filtered.length === 0 && (
                  <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground text-sm">暂无数据</TableCell></TableRow>
                )}
                {filtered.map(r => {
                  const erp = erpStatusOf(r);
                  return (
                    <TableRow key={r.id}>
                      <TableCell>
                        <button className="font-medium text-left hover:underline" onClick={() => setDetailRow(r)}>
                          {r.name}
                        </button>
                      </TableCell>
                      <TableCell className="text-sm">{displayContact(r) || <span className="text-muted-foreground">—</span>}</TableCell>
                      <TableCell className="text-sm">{displayPhone(r) || <span className="text-muted-foreground">—</span>}</TableCell>
                      <TableCell className="text-sm max-w-[260px] truncate" title={displayAddress(r)}>
                        {displayAddress(r) || <span className="text-muted-foreground">—</span>}
                      </TableCell>
                      <TableCell>
                        {r.jst_supplier_id
                          ? <Badge variant="outline" className="text-xs">聚水潭：{r.status || "—"}</Badge>
                          : <span className="text-xs text-muted-foreground">非聚水潭</span>}
                      </TableCell>
                      <TableCell>
                        {erp === "enabled"
                          ? <Badge className="bg-emerald-600">已启用</Badge>
                          : <Badge variant="secondary">已禁用</Badge>}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground max-w-[180px] truncate" title={r.remark ?? ""}>
                        {r.remark || "—"}
                      </TableCell>
                      <TableCell className="text-right space-x-1">
                        {erp === "disabled"
                          ? <Button size="sm" variant="outline" onClick={() => openAction(r, "enable")}>
                              <Power className="w-3.5 h-3.5 mr-1" />启用
                            </Button>
                          : <Button size="sm" variant="outline" onClick={() => openAction(r, "disable")}>
                              <PowerOff className="w-3.5 h-3.5 mr-1" />禁用
                            </Button>}
                        <Button size="sm" variant="ghost" onClick={() => openEdit(r)}>
                          <Pencil className="w-3.5 h-3.5 mr-1" />编辑
                        </Button>
                        <Button size="sm" variant="ghost" onClick={() => setDetailRow(r)}>
                          <Eye className="w-3.5 h-3.5 mr-1" />详情
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </TabsContent>
      </Tabs>

      {/* 启用 / 禁用 弹窗 */}
      <Dialog open={!!actionRow} onOpenChange={(o) => { if (!o) { setActionRow(null); setActionType(null); } }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{actionType === "enable" ? "启用供应商" : "禁用供应商"}</DialogTitle>
            <DialogDescription>{actionRow?.name}（{actionRow?.code}）</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label>{actionType === "enable" ? "启用备注" : "禁用原因（必填）"}</Label>
              <Select value={reasonPreset} onValueChange={setReasonPreset}>
                <SelectTrigger><SelectValue placeholder="选择常用原因（可选）" /></SelectTrigger>
                <SelectContent>
                  {(actionType === "enable" ? ENABLE_REMARKS : DISABLE_REASONS).map(r => (
                    <SelectItem key={r} value={r}>{r}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Textarea
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={actionType === "enable" ? "补充说明（可选）" : "补充说明，例如：原供应商已停止合作"}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => { setActionRow(null); setActionType(null); }}>取消</Button>
            <Button onClick={submitAction} disabled={submitting}>
              {submitting && <Loader2 className="w-3.5 h-3.5 mr-1 animate-spin" />}确定
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 编辑联系人 / 地址 / 备注 */}
      <Dialog open={!!editRow} onOpenChange={(o) => { if (!o) setEditRow(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>编辑供应商信息</DialogTitle>
            <DialogDescription>{editRow?.name}（{editRow?.code}）</DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label>联系人（人工维护）</Label>
              <Input value={editForm.manual_contact_name}
                onChange={(e) => setEditForm({ ...editForm, manual_contact_name: e.target.value })}
                placeholder={editRow?.contact || "聚水潭未返回，可手动补充"} />
            </div>
            <div className="space-y-1.5">
              <Label>联系电话（人工维护）</Label>
              <Input value={editForm.manual_contact_phone}
                onChange={(e) => setEditForm({ ...editForm, manual_contact_phone: e.target.value })}
                placeholder={editRow?.phone || "聚水潭未返回，可手动补充"} />
            </div>
            <div className="space-y-1.5">
              <Label>地址（人工维护）</Label>
              <Textarea value={editForm.manual_address}
                onChange={(e) => setEditForm({ ...editForm, manual_address: e.target.value })}
                placeholder={editRow?.address || "聚水潭未返回，可手动补充"} />
            </div>
            <div className="space-y-1.5">
              <Label>备注</Label>
              <Textarea value={editForm.remark}
                onChange={(e) => setEditForm({ ...editForm, remark: e.target.value })} />
            </div>
            <p className="text-xs text-muted-foreground">
              人工维护的字段不会被后续聚水潭同步覆盖；当人工字段为空时，前端会显示聚水潭同步值。
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditRow(null)}>取消</Button>
            <Button onClick={submitEdit} disabled={submitting}>
              {submitting && <Loader2 className="w-3.5 h-3.5 mr-1 animate-spin" />}保存
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 详情抽屉 */}
      <Sheet open={!!detailRow} onOpenChange={(o) => { if (!o) { setDetailRow(null); setShowRaw(false); } }}>
        <SheetContent className="w-full sm:max-w-xl overflow-y-auto">
          {detailRow && (
            <>
              <SheetHeader>
                <SheetTitle>{detailRow.name}</SheetTitle>
                <SheetDescription>编码 {detailRow.code}</SheetDescription>
              </SheetHeader>

              <div className="mt-4 space-y-5 text-sm">
                <section>
                  <div className="text-xs font-medium text-muted-foreground mb-2">基础信息</div>
                  <dl className="grid grid-cols-3 gap-y-2">
                    <dt className="text-muted-foreground">联系人</dt>
                    <dd className="col-span-2">{displayContact(detailRow) || "—"}
                      {detailRow.manual_contact_name && <span className="ml-2 text-xs text-emerald-600">人工</span>}
                    </dd>
                    <dt className="text-muted-foreground">联系电话</dt>
                    <dd className="col-span-2">{displayPhone(detailRow) || "—"}
                      {detailRow.manual_contact_phone && <span className="ml-2 text-xs text-emerald-600">人工</span>}
                    </dd>
                    <dt className="text-muted-foreground">地址</dt>
                    <dd className="col-span-2">{displayAddress(detailRow) || "—"}
                      {detailRow.manual_address && <span className="ml-2 text-xs text-emerald-600">人工</span>}
                    </dd>
                    <dt className="text-muted-foreground">邮箱</dt>
                    <dd className="col-span-2">{detailRow.email || "—"}</dd>
                    <dt className="text-muted-foreground">备注</dt>
                    <dd className="col-span-2 whitespace-pre-wrap">{detailRow.remark || "—"}</dd>
                  </dl>
                </section>

                <section>
                  <div className="text-xs font-medium text-muted-foreground mb-2">系统信息</div>
                  <dl className="grid grid-cols-3 gap-y-2">
                    <dt className="text-muted-foreground">聚水潭 ID</dt>
                    <dd className="col-span-2">{detailRow.jst_supplier_id || "—"}</dd>
                    <dt className="text-muted-foreground">聚水潭状态</dt>
                    <dd className="col-span-2">{detailRow.status || "—"}</dd>
                    <dt className="text-muted-foreground">最近同步</dt>
                    <dd className="col-span-2">{detailRow.last_synced_at ? new Date(detailRow.last_synced_at).toLocaleString("zh-CN") : "—"}</dd>
                    <dt className="text-muted-foreground">ERP 状态</dt>
                    <dd className="col-span-2">
                      {erpStatusOf(detailRow) === "enabled"
                        ? <Badge className="bg-emerald-600">已启用</Badge>
                        : <Badge variant="secondary">已禁用</Badge>}
                      {detailRow.confirm_status === "archived" && detailRow.archived_reason && (
                        <span className="ml-2 text-xs text-muted-foreground">原因：{detailRow.archived_reason}</span>
                      )}
                    </dd>
                  </dl>
                  {detailRow.raw_jst_json ? (
                    <div className="mt-3">
                      <Button size="sm" variant="ghost" onClick={() => setShowRaw(v => !v)}>
                        {showRaw ? "隐藏" : "查看"} 历史调试数据（raw JSON）
                      </Button>
                      {showRaw && (
                        <>
                          <p className="mt-2 text-[11px] text-muted-foreground">
                            新同步默认不保存完整 raw JSON，以避免数据库被海量数据撑爆。下面是旧版历史 raw，仅供排查。
                          </p>
                          <pre className="mt-2 bg-muted p-2 rounded text-[11px] overflow-auto max-h-72">
                            {JSON.stringify(detailRow.raw_jst_json, null, 2)}
                          </pre>
                        </>
                      )}
                    </div>
                  ) : null}
                </section>

                <section>
                  <div className="text-xs font-medium text-muted-foreground mb-2">状态变更记录</div>
                  {auditFor(detailRow.id).length === 0 && (
                    <div className="text-xs text-muted-foreground">暂无变更记录</div>
                  )}
                  <ul className="space-y-2">
                    {auditFor(detailRow.id).map(a => {
                      const oldErp = a.old_confirm_status === "confirmed" ? "已启用" : a.old_confirm_status ? "已禁用" : "(空)";
                      const newErp = a.new_confirm_status === "confirmed" ? "已启用" : "已禁用";
                      return (
                        <li key={a.id} className="text-xs border-l-2 border-muted pl-2">
                          <div>{oldErp} → <span className="font-medium">{newErp}</span></div>
                          {a.reason && <div className="text-muted-foreground">原因：{a.reason}</div>}
                          <div className="text-muted-foreground">{new Date(a.operated_at).toLocaleString("zh-CN")}</div>
                        </li>
                      );
                    })}
                  </ul>
                </section>

                <div className="flex gap-2 pt-2">
                  {erpStatusOf(detailRow) === "disabled"
                    ? <Button onClick={() => { openAction(detailRow, "enable"); setDetailRow(null); }}>
                        <Power className="w-3.5 h-3.5 mr-1" />启用
                      </Button>
                    : <Button variant="outline" onClick={() => { openAction(detailRow, "disable"); setDetailRow(null); }}>
                        <PowerOff className="w-3.5 h-3.5 mr-1" />禁用
                      </Button>}
                  <Button variant="ghost" onClick={() => { openEdit(detailRow); setDetailRow(null); }}>
                    <Pencil className="w-3.5 h-3.5 mr-1" />编辑信息
                  </Button>
                </div>
              </div>
            </>
          )}
        </SheetContent>
      </Sheet>
    </div>
  );
}
