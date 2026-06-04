import { useEffect, useState } from "react";
import { PageHeader } from "@/components/ops/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { RefreshCw } from "lucide-react";


type Row = {
  id: string;
  platform: string | null;
  shop_id: string | null;
  shop_name: string | null;
  online_item_code: string | null;
  online_sku_code: string | null;
  source_table: string | null;
  reason: string | null;
  status: string;
  raw_data: any;
  created_at: string;
};

export default function ProductMappingExceptionsPage() {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(false);
  const [keyword, setKeyword] = useState("");
  const [status, setStatusFilter] = useState<string>("pending");

  const load = async () => {
    setLoading(true);
    let q = supabase
      .from("ops_product_mapping_exceptions")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(500);
    if (status !== "all") q = q.eq("status", status);
    if (keyword.trim()) {
      const k = `%${keyword.trim()}%`;
      q = q.or(`online_sku_code.ilike.${k},online_item_code.ilike.${k},shop_name.ilike.${k},shop_id.ilike.${k}`);
    }
    const { data, error } = await q;
    if (error) toast.error(error.message);
    setRows((data as any) ?? []);
    setLoading(false);
  };

  useEffect(() => { load(); /* eslint-disable-next-line */ }, [status]);

  const setRowStatus = async (id: string, next: string) => {
    const { error } = await supabase.from("ops_product_mapping_exceptions")
      .update({ status: next, resolved_at: next === "resolved" ? new Date().toISOString() : null })
      .eq("id", id);
    if (error) { toast.error(error.message); return; }
    toast.success("已更新");
    load();
  };

  return (
    <div>
      <PageHeader
        breadcrumb={["商品系统", "商品映射异常"]}
        title="商品映射异常"
        description="订单 / 出库 / 退款中出现了线上商品编码，但无法匹配到内部 SKU 主档"
        actions={<Button size="sm" variant="outline" onClick={load} disabled={loading}><RefreshCw className={`w-4 h-4 mr-1 ${loading ? "animate-spin" : ""}`} /> 刷新</Button>}
      />

      <Card className="p-4">
        <div className="flex items-center gap-2 mb-3">
          <Input
            placeholder="搜索线上 SKU / 商品编码 / 店铺"
            value={keyword}
            onChange={(e) => setKeyword(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && load()}
            className="max-w-xs"
          />
          <Select value={status} onValueChange={setStatusFilter}>
            <SelectTrigger className="w-32"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="pending">待处理</SelectItem>
              <SelectItem value="resolved">已解决</SelectItem>
              <SelectItem value="ignored">已忽略</SelectItem>
              <SelectItem value="all">全部</SelectItem>
            </SelectContent>
          </Select>
          <Button size="sm" variant="outline" onClick={load}>搜索</Button>
          <span className="text-xs text-muted-foreground ml-auto">共 {rows.length} 条</span>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-xs text-muted-foreground">
              <tr className="border-b">
                <th className="text-left p-2">平台</th>
                <th className="text-left p-2">店铺</th>
                <th className="text-left p-2">线上商品编码</th>
                <th className="text-left p-2">线上 SKU</th>
                <th className="text-left p-2">来源</th>
                <th className="text-left p-2">原因</th>
                <th className="text-left p-2">状态</th>
                <th className="text-left p-2">时间</th>
                <th className="text-right p-2">操作</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b hover:bg-muted/40">
                  <td className="p-2">{r.platform ?? "-"}</td>
                  <td className="p-2 text-xs">{r.shop_name ?? r.shop_id ?? "-"}</td>
                  <td className="p-2 font-mono text-xs">{r.online_item_code ?? "-"}</td>
                  <td className="p-2 font-mono text-xs">{r.online_sku_code ?? "-"}</td>
                  <td className="p-2 text-xs text-muted-foreground">{r.source_table ?? "-"}</td>
                  <td className="p-2 text-xs">{r.reason ?? "-"}</td>
                  <td className="p-2"><Badge variant={r.status === "pending" ? "destructive" : "secondary"}>{r.status}</Badge></td>
                  <td className="p-2 text-xs">{new Date(r.created_at).toLocaleString("zh-CN")}</td>
                  <td className="p-2 text-right">
                    {r.status === "pending" && (
                      <div className="flex gap-1 justify-end">
                        <Button size="sm" variant="outline" onClick={() => setRowStatus(r.id, "resolved")}>标记已解决</Button>
                        <Button size="sm" variant="ghost" onClick={() => setRowStatus(r.id, "ignored")}>忽略</Button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr><td colSpan={9} className="py-12 text-center text-muted-foreground">暂无异常记录</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}
