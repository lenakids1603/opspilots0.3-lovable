import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table";
import {
  Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription,
} from "@/components/ui/sheet";
import { toast } from "@/hooks/use-toast";
import { RefreshCw, Activity, Eye } from "lucide-react";
import { zhStatus } from "@/lib/statusLabel";

const FUNCTION_NAME = "jst-sync-outbound-orders";
const SYNC_TYPE = "outbound_orders";
const PAGE_SIZE = 20;

const STATUS_LABEL: Record<string, { label: string; cls: string }> = {
  success: { label: "正常", cls: "bg-emerald-100 text-emerald-700" },
  partial_failed: { label: "部分失败", cls: "bg-amber-100 text-amber-700" },
  partial: { label: "部分完成", cls: "bg-amber-100 text-amber-700" },
  timeout_partial: { label: "超时未完成", cls: "bg-amber-100 text-amber-700" },
  running: { label: "同步中", cls: "bg-blue-100 text-blue-700" },
  failed: { label: "异常", cls: "bg-rose-100 text-rose-700" },
  none: { label: "暂未同步", cls: "bg-slate-100 text-slate-700" },
};

const fmt = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleString("zh-CN", { hour12: false }) : "-";

export function OutboundSyncCards() {
  const qc = useQueryClient();
  const [customStart, setCustomStart] = useState("");
  const [customEnd, setCustomEnd] = useState("");
  const [page, setPage] = useState(0);
  const [keyword, setKeyword] = useState("");
  const [detailId, setDetailId] = useState<string | null>(null);

  const countQ = useQuery({
    queryKey: ["warehouse_shipping_package_count"],
    queryFn: async () => {
      const { count, error } = await (supabase as any)
        .from("warehouse_shipping_packages")
        .select("id", { count: "exact", head: true });
      if (error) throw error;
      return count ?? 0;
    },
    refetchInterval: 8000,
  });

  const lastLogQ = useQuery({
    queryKey: ["outbound_last_log"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("jst_sync_logs")
        .select("id,status,started_at,ended_at,message,error_detail,fetched_orders_count,fetched_items_count")
        .eq("sync_type", SYNC_TYPE)
        .order("started_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    refetchInterval: 5000,
  });

  const listQ = useQuery({
    queryKey: ["warehouse_shipping_package_preview", page, keyword],
    queryFn: async () => {
      let query = (supabase as any)
        .from("warehouse_shipping_packages")
        .select("id,io_id,o_id,shop_name,warehouse_name,wh_id,status,logistics_company,tracking_number,send_date,weight,shipping_method", { count: "exact" })
        .order("send_date", { ascending: false, nullsFirst: false })
        .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);
      const kw = keyword.trim().replace(/[,()]/g, "");
      if (kw) query = query.or(`io_id.ilike.%${kw}%,o_id.ilike.%${kw}%,tracking_number.ilike.%${kw}%`);
      const { data, count, error } = await query;
      if (error) throw error;
      return { rows: data ?? [], total: count ?? 0 };
    },
  });

  const detailQ = useQuery({
    enabled: !!detailId,
    queryKey: ["warehouse_shipping_package_detail", detailId],
    queryFn: async () => {
      const [pkg, items] = await Promise.all([
        (supabase as any).from("warehouse_shipping_packages").select("*").eq("id", detailId!).maybeSingle(),
        (supabase as any).from("warehouse_shipping_package_items").select("*").eq("package_id", detailId!).order("sku_id", { ascending: true, nullsFirst: false }),
      ]);
      if (pkg.error) throw pkg.error;
      if (items.error) throw items.error;
      return { pkg: pkg.data, items: items.data ?? [] };
    },
  });

  const syncMut = useMutation({
    mutationFn: async (payload: { hours?: number; days?: number; start_time?: string; end_time?: string; requested_range?: string }) => {
      const { data, error } = await supabase.functions.invoke(FUNCTION_NAME, {
        body: { action: "start_outbound_job", ...payload },
      });
      if (error) throw new Error(error.message);
      if (data?.ok === false) throw new Error(data?.error ?? "同步失败");
      return data;
    },
    onSuccess: () => {
      toast({ title: "已创建出库轻量同步任务", description: "后台运行中，刷新查看进度" });
      qc.invalidateQueries({ queryKey: ["warehouse_shipping_package_count"] });
      qc.invalidateQueries({ queryKey: ["outbound_last_log"] });
      setTimeout(() => qc.invalidateQueries({ queryKey: ["warehouse_shipping_package_preview"] }), 4000);
    },
    onError: (error: unknown) => {
      toast({ title: "出库轻量同步失败", description: (error as Error).message, variant: "destructive" });
    },
  });

  const log = lastLogQ.data;
  const statusKey = !log ? "none" : (log.status as string);
  const meta = STATUS_LABEL[statusKey] ?? STATUS_LABEL.none;
  const totalPages = Math.max(1, Math.ceil((listQ.data?.total ?? 0) / PAGE_SIZE));

  return (
    <div className="p-5 space-y-4">
      <div className="rounded-md border border-sky-300 bg-sky-50/60 px-4 py-2.5 text-xs text-sky-800">
        聚水潭出库 API 仅用于仓库实际发货包裹统计；同步写入轻量包裹表和包裹 SKU 明细，不再写旧重型出库表。
      </div>

      <Card>
        <CardContent className="p-4 space-y-3">
          <div className="flex items-center gap-2">
            <Activity className="w-4 h-4 text-muted-foreground" />
            <div className="font-medium text-sm">出库轻量同步</div>
            <Badge variant="secondary" className={meta.cls}>{meta.label}</Badge>
            <div className="flex-1" />
            <span className="text-xs text-muted-foreground">
              已同步 <span className="font-semibold tabular-nums text-foreground">{(countQ.data ?? 0).toLocaleString("zh-CN")}</span> 个包裹
            </span>
          </div>

          <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <div>最近同步：<span className="text-foreground">{fmt(log?.ended_at ?? log?.started_at)}</span></div>
            <div>本次结果：<span className="text-foreground">
              {log ? `${log.fetched_orders_count ?? 0} 包裹 / ${log.fetched_items_count ?? 0} 明细` : "-"}
            </span></div>
          </div>

          {log?.message && (
            <div className="text-[11px] text-muted-foreground bg-muted/30 rounded px-2 py-1.5 break-all">
              {log.message}
            </div>
          )}
          {log?.error_detail && (
            <div className="text-[11px] text-rose-600 break-all">错误：{log.error_detail}</div>
          )}

          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" disabled={syncMut.isPending}
              onClick={() => syncMut.mutate({ hours: 2, requested_range: "2h_test" })}>
              <RefreshCw className={`w-3.5 h-3.5 mr-1 ${syncMut.isPending ? "animate-spin" : ""}`} />
              最近 2 小时测试同步
            </Button>
            <Button size="sm" disabled={syncMut.isPending}
              onClick={() => syncMut.mutate({ days: 1, requested_range: "1d" })}>最近 1 天同步</Button>
          </div>

          <div className="flex flex-wrap items-center gap-2 pt-1 border-t border-border">
            <span className="text-xs text-muted-foreground">自定义范围：</span>
            <Input type="datetime-local" value={customStart} onChange={(e) => setCustomStart(e.target.value)}
              className="h-8 w-[180px] text-xs" />
            <span className="text-xs text-muted-foreground">→</span>
            <Input type="datetime-local" value={customEnd} onChange={(e) => setCustomEnd(e.target.value)}
              className="h-8 w-[180px] text-xs" />
            <Button size="sm" variant="outline" disabled={syncMut.isPending || !customStart || !customEnd}
              onClick={() => syncMut.mutate({
                start_time: new Date(customStart).toISOString(),
                end_time: new Date(customEnd).toISOString(),
                requested_range: "custom",
              })}>同步该范围</Button>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="p-4 space-y-3">
          <div className="flex items-center gap-2">
            <div className="text-sm font-medium">发货包裹预览</div>
            <div className="flex-1" />
            <Input
              placeholder="搜索包裹号 / 订单号 / 快递单号"
              value={keyword}
              onChange={(e) => { setKeyword(e.target.value); setPage(0); }}
              className="h-8 w-[280px] text-xs"
            />
          </div>

          <div className="rounded-md border overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="whitespace-nowrap">包裹号</TableHead>
                  <TableHead className="whitespace-nowrap">订单号</TableHead>
                  <TableHead className="whitespace-nowrap">店铺</TableHead>
                  <TableHead className="whitespace-nowrap">仓库</TableHead>
                  <TableHead className="whitespace-nowrap">状态</TableHead>
                  <TableHead className="whitespace-nowrap">快递公司</TableHead>
                  <TableHead className="whitespace-nowrap">快递单号</TableHead>
                  <TableHead className="whitespace-nowrap">发货日期</TableHead>
                  <TableHead className="whitespace-nowrap text-right">重量</TableHead>
                  <TableHead className="whitespace-nowrap">发货方式</TableHead>
                  <TableHead className="whitespace-nowrap text-right">操作</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {listQ.isLoading && (
                  <TableRow><TableCell colSpan={11} className="text-center text-xs text-muted-foreground py-6">加载中...</TableCell></TableRow>
                )}
                {!listQ.isLoading && (listQ.data?.rows.length ?? 0) === 0 && (
                  <TableRow><TableCell colSpan={11} className="text-center text-xs text-muted-foreground py-6">暂无轻量包裹数据</TableCell></TableRow>
                )}
                {listQ.data?.rows.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell className="font-mono text-xs">{row.io_id}</TableCell>
                    <TableCell className="font-mono text-xs">{row.o_id ?? "-"}</TableCell>
                    <TableCell className="text-xs">{row.shop_name ?? "-"}</TableCell>
                    <TableCell className="text-xs">{row.warehouse_name ?? row.wh_id ?? "-"}</TableCell>
                    <TableCell className="text-xs">{zhStatus(row.status)}</TableCell>
                    <TableCell className="text-xs">{row.logistics_company ?? "-"}</TableCell>
                    <TableCell className="font-mono text-xs">{row.tracking_number ?? "-"}</TableCell>
                    <TableCell className="text-xs whitespace-nowrap">{fmt(row.send_date)}</TableCell>
                    <TableCell className="text-xs text-right tabular-nums">{row.weight ?? "-"}</TableCell>
                    <TableCell className="text-xs">{row.shipping_method ?? "-"}</TableCell>
                    <TableCell className="text-right">
                      <Button size="sm" variant="ghost" onClick={() => setDetailId(row.id)}>
                        <Eye className="w-3.5 h-3.5 mr-1" />详情
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>

          <div className="flex items-center justify-between text-xs text-muted-foreground">
            <div>共 {listQ.data?.total ?? 0} 条 · 第 {page + 1} / {totalPages} 页</div>
            <div className="flex gap-2">
              <Button size="sm" variant="outline" disabled={page === 0}
                onClick={() => setPage((value) => Math.max(0, value - 1))}>上一页</Button>
              <Button size="sm" variant="outline" disabled={page + 1 >= totalPages}
                onClick={() => setPage((value) => value + 1)}>下一页</Button>
            </div>
          </div>
        </CardContent>
      </Card>

      <Sheet open={!!detailId} onOpenChange={(open) => !open && setDetailId(null)}>
        <SheetContent side="right" className="w-full sm:max-w-2xl overflow-y-auto">
          <SheetHeader>
            <SheetTitle>发货包裹详情</SheetTitle>
            <SheetDescription className="font-mono text-xs">
              {detailQ.data?.pkg?.io_id ?? ""}
            </SheetDescription>
          </SheetHeader>

          {detailQ.isLoading && <div className="py-6 text-xs text-muted-foreground">加载中...</div>}

          {detailQ.data?.pkg && (
            <div className="mt-4 space-y-4">
              <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-xs">
                <div><span className="text-muted-foreground">订单号：</span>{detailQ.data.pkg.o_id ?? "-"}</div>
                <div><span className="text-muted-foreground">店铺：</span>{detailQ.data.pkg.shop_name ?? "-"}</div>
                <div><span className="text-muted-foreground">仓库：</span>{detailQ.data.pkg.warehouse_name ?? detailQ.data.pkg.wh_id ?? "-"}</div>
                <div><span className="text-muted-foreground">状态：</span>{zhStatus(detailQ.data.pkg.status)}</div>
                <div><span className="text-muted-foreground">快递公司：</span>{detailQ.data.pkg.logistics_company ?? "-"}</div>
                <div><span className="text-muted-foreground">快递单号：</span><span className="font-mono">{detailQ.data.pkg.tracking_number ?? "-"}</span></div>
                <div><span className="text-muted-foreground">发货日期：</span>{fmt(detailQ.data.pkg.send_date)}</div>
                <div><span className="text-muted-foreground">重量：</span>{detailQ.data.pkg.weight ?? "-"}</div>
                <div><span className="text-muted-foreground">发货方式：</span>{detailQ.data.pkg.shipping_method ?? "-"}</div>
                <div><span className="text-muted-foreground">同步时间：</span>{fmt(detailQ.data.pkg.synced_at)}</div>
              </div>

              <div>
                <div className="text-sm font-medium mb-2">SKU 明细（{detailQ.data.items.length}）</div>
                <div className="rounded-md border overflow-x-auto">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-xs">SKU</TableHead>
                        <TableHead className="text-xs">款号</TableHead>
                        <TableHead className="text-xs">商品名称</TableHead>
                        <TableHead className="text-xs text-right">数量</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {detailQ.data.items.length === 0 && (
                        <TableRow><TableCell colSpan={4} className="text-center text-xs text-muted-foreground py-4">暂无明细</TableCell></TableRow>
                      )}
                      {detailQ.data.items.map((item) => (
                        <TableRow key={item.id}>
                          <TableCell className="font-mono text-xs">{item.sku_code ?? item.sku_id ?? "-"}</TableCell>
                          <TableCell className="font-mono text-xs">{item.style_no ?? "-"}</TableCell>
                          <TableCell className="text-xs">{item.product_name ?? "-"}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{Number(item.qty ?? 0)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              </div>
            </div>
          )}
        </SheetContent>
      </Sheet>
    </div>
  );
}

export default OutboundSyncCards;
