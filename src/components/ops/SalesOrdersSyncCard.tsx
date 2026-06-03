import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { InboundSyncJobPanel, type SyncPresetButton } from "./InboundSyncJobPanel";

const fmtDT = (s: any) => {
  if (!s) return "-";
  const d = new Date(s);
  return isNaN(d.getTime()) ? "-" : d.toLocaleString("zh-CN", { hour12: false });
};
const fmtNum = (n: any) => (n == null ? "-" : Number(n).toLocaleString("zh-CN"));

function buildPresets(): SyncPresetButton[] {
  // Each preset adds a 10-minute back-shift to avoid edge data loss.
  const BACK_MS = 10 * 60_000;
  return [
    {
      label: "同步最近 1 小时",
      variant: "default",
      body: (() => {
        const end = new Date();
        const start = new Date(end.getTime() - 60 * 60_000 - BACK_MS);
        return { start_time: start.toISOString(), end_time: end.toISOString(), requested_range: "1h" };
      })(),
    },
    {
      label: "同步今天",
      variant: "outline",
      body: (() => {
        const end = new Date();
        // Beijing midnight today
        const bj = new Date(end.getTime() + 8 * 3600_000);
        bj.setUTCHours(0, 0, 0, 0);
        const startMs = bj.getTime() - 8 * 3600_000 - BACK_MS;
        return { start_time: new Date(startMs).toISOString(), end_time: end.toISOString(), requested_range: "today" };
      })(),
    },
    {
      label: "同步最近 3 天",
      variant: "outline",
      body: (() => {
        const end = new Date();
        const start = new Date(end.getTime() - 3 * 86400_000 - BACK_MS);
        return { start_time: start.toISOString(), end_time: end.toISOString(), requested_range: "3d" };
      })(),
    },
  ];
}

function useRecentSalesOrders() {
  return useQuery({
    queryKey: ["jst_sales_orders", "recent50"],
    refetchInterval: 5000,
    queryFn: async () => {
      const { data, error } = await (supabase as any)
        .from("jst_sales_orders")
        .select("jst_o_id, so_id, shop_name, status, created_time, modified_time, paid_amount, pay_amount, io_id, l_id")
        .order("modified_time", { ascending: false, nullsFirst: false })
        .limit(50);
      if (error) throw error;
      return data ?? [];
    },
  });
}

function useItemCountByOrder(orderIds: string[]) {
  return useQuery({
    queryKey: ["jst_sales_order_items", "count", orderIds.join(",")],
    enabled: orderIds.length > 0,
    queryFn: async () => {
      const { data, error } = await (supabase as any)
        .from("jst_sales_order_items")
        .select("jst_o_id, qty")
        .in("jst_o_id", orderIds);
      if (error) throw error;
      const map: Record<string, { qty: number; count: number }> = {};
      for (const row of data ?? []) {
        const k = row.jst_o_id as string;
        if (!map[k]) map[k] = { qty: 0, count: 0 };
        map[k].qty += Number(row.qty ?? 0);
        map[k].count += 1;
      }
      return map;
    },
  });
}

export function SalesOrdersSyncCard() {
  const qc = useQueryClient();
  const recent = useRecentSalesOrders();
  const orderIds = (recent.data ?? []).map((r: any) => r.jst_o_id as string);
  const counts = useItemCountByOrder(orderIds);

  return (
    <div className="space-y-3">
      <div className="rounded-md border border-sky-300 bg-sky-50/60 px-4 py-2.5 text-xs text-sky-800">
        聚水潭销售订单同步（只读 · 断点续跑）：调用 <code>/open/orders/single/query</code>，按 <code>modified</code> 增量分页拉取，自动 upsert
        {" "}<code>jst_sales_orders</code> + <code>jst_sales_order_items</code>。每次开始时间自动回退 10 分钟避免边界遗漏；隐私字段第一阶段仅保留省/市/区，手机号脱敏后 4 位。
      </div>

      <InboundSyncJobPanel
        title="订单 API · 销售订单同步任务"
        syncType="sales_orders"
        functionName="jst-sync-sales-orders"
        startAction="start_sales_job"
        tickAction="tick_sales_job"
        cancelAction="cancel_sales_job"
        unitLabel="订单"
        toastTitle="已创建销售订单同步任务"
        presets={buildPresets()}
        emptyText="暂无销售订单同步任务。可选「最近 1 小时 / 今天 / 最近 3 天」，任务按 1 天窗口、每次最多 3 页分批执行，支持断点续跑。"
        onJobFinished={() => {
          qc.invalidateQueries({ queryKey: ["jst_sales_orders", "recent50"] });
        }}
      />

      <Card>
        <CardContent className="p-4 space-y-2">
          <div className="flex items-center gap-2 text-sm font-medium">
            订单同步结果预览
            <Badge variant="secondary" className="bg-slate-100 text-slate-700">最近 50 条（按修改时间倒序）</Badge>
          </div>
          <div className="rounded border overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>so_id</TableHead>
                  <TableHead>jst_o_id</TableHead>
                  <TableHead>店铺</TableHead>
                  <TableHead>状态</TableHead>
                  <TableHead>创建时间</TableHead>
                  <TableHead>修改时间</TableHead>
                  <TableHead className="text-right">实付</TableHead>
                  <TableHead className="text-right">件数</TableHead>
                  <TableHead>出库单号</TableHead>
                  <TableHead>物流单号</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {recent.isLoading && (
                  <TableRow><TableCell colSpan={10} className="text-center text-xs text-muted-foreground">加载中…</TableCell></TableRow>
                )}
                {!recent.isLoading && (recent.data ?? []).length === 0 && (
                  <TableRow><TableCell colSpan={10} className="text-center text-xs text-muted-foreground">暂无数据，先点上方按钮启动一次同步。</TableCell></TableRow>
                )}
                {(recent.data ?? []).map((r: any) => {
                  const c = counts.data?.[r.jst_o_id];
                  return (
                    <TableRow key={r.jst_o_id}>
                      <TableCell className="font-mono text-xs">{r.so_id ?? "-"}</TableCell>
                      <TableCell className="font-mono text-xs">{r.jst_o_id}</TableCell>
                      <TableCell className="text-xs">{r.shop_name ?? "-"}</TableCell>
                      <TableCell className="text-xs">{r.status ?? "-"}</TableCell>
                      <TableCell className="text-xs">{fmtDT(r.created_time)}</TableCell>
                      <TableCell className="text-xs">{fmtDT(r.modified_time)}</TableCell>
                      <TableCell className="text-xs text-right">{fmtNum(r.paid_amount ?? r.pay_amount)}</TableCell>
                      <TableCell className="text-xs text-right">{c ? fmtNum(c.qty) : "-"}</TableCell>
                      <TableCell className="font-mono text-xs">{r.io_id ?? "-"}</TableCell>
                      <TableCell className="font-mono text-xs">{r.l_id ?? "-"}</TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

export default SalesOrdersSyncCard;
