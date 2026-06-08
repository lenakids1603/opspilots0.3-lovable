import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import {
  Table, TableHeader, TableBody, TableHead, TableRow, TableCell,
} from "@/components/ui/table";
import {
  Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription,
} from "@/components/ui/sheet";
import { toast } from "@/hooks/use-toast";
import { formatDateTimeCN, beijingDayRangeToUTC, todayCN } from "@/lib/datetime";

const PAGE_SIZE = 20;
const fmtInt = (n: number | null | undefined) =>
  Number(n ?? 0).toLocaleString("zh-CN", { maximumFractionDigits: 0 });

export type OutboundByStyleFilters = {
  startDate: string;
  endDate: string;
  shop: string;
  warehouse: string;
  logistics: string;
  ioId: string;
  oId: string;
  trackingNumber: string;
  sku: string;
  status: string;
  hasItems: string;
  abnormal: string;
};

type PackageMeta = {
  id: string;
  io_id: string;
  o_id: string | null;
  shop_name: string | null;
  wh_id: string | null;
  warehouse_name: string | null;
  status: string | null;
  logistics_company: string | null;
  tracking_number: string | null;
  send_date: string | null;
};

type AggItem = {
  id: string;
  package_id: string;
  io_id: string;
  sku_id: string | null;
  sku_code: string | null;
  style_no: string | null;
  product_name: string | null;
  qty: number;
  _style: string;
};

type StyleRow = {
  key: string;
  style_no: string;
  product_name: string;
  shop_name: string;
  qty: number;
  package_set: Set<string>;
  order_set: Set<string>;
  sku_set: Set<string>;
  wh_set: Set<string>;
  first_ship: string | null;
  last_ship: string | null;
};

function styleFallback(styleNo: string | null | undefined, sku: string | null | undefined, name: string | null | undefined) {
  const direct = (styleNo ?? "").trim();
  if (direct) return direct;
  const skuText = (sku ?? "").trim();
  if (skuText) {
    const matched = skuText.match(/^\d{6,12}/);
    if (matched) return matched[0];
    const segment = skuText.split(/[-_/\s]/)[0];
    if (segment) return segment;
  }
  return (name ?? "").trim() || "(未知款号)";
}

type FilterQuery<T> = T & {
  gte: (column: string, value: string) => FilterQuery<T>;
  lte: (column: string, value: string) => FilterQuery<T>;
  ilike: (column: string, value: string) => FilterQuery<T>;
  eq: (column: string, value: string) => FilterQuery<T>;
};

function applyPackageFilters<T>(q: FilterQuery<T>, filters: OutboundByStyleFilters): FilterQuery<T> {
  if (filters.startDate) {
    const range = beijingDayRangeToUTC(filters.startDate);
    if (range) q = q.gte("send_date", range.gte);
  }
  if (filters.endDate) {
    const range = beijingDayRangeToUTC(filters.endDate);
    if (range) q = q.lte("send_date", range.lte);
  }
  if (filters.shop) q = q.ilike("shop_name", `%${filters.shop}%`);
  if (filters.warehouse) q = q.ilike("warehouse_name", `%${filters.warehouse}%`);
  if (filters.logistics) q = q.ilike("logistics_company", `%${filters.logistics}%`);
  if (filters.ioId) q = q.ilike("io_id", `%${filters.ioId}%`);
  if (filters.oId) q = q.ilike("o_id", `%${filters.oId}%`);
  if (filters.trackingNumber) q = q.ilike("tracking_number", `%${filters.trackingNumber}%`);
  if (filters.status !== "all") q = q.eq("status", filters.status);
  return q;
}

function whLabel(set: Set<string>) {
  const values = Array.from(set).filter(Boolean);
  if (!values.length) return "-";
  if (values.length === 1) return values[0];
  return `${values.length} 个仓库`;
}

function useStyleAggregate(filters: OutboundByStyleFilters) {
  return useQuery({
    queryKey: ["warehouse_shipping_by_style", filters],
    queryFn: async () => {
      let q = (supabase as any)
        .from("warehouse_shipping_packages")
        .select("id, io_id, o_id, shop_name, wh_id, warehouse_name, status, logistics_company, tracking_number, send_date")
        .order("send_date", { ascending: false, nullsFirst: false })
        .limit(3000);
      q = applyPackageFilters(q, filters);

      const { data: packages, error } = await q;
      if (error) throw error;
      const packageRows = (packages ?? []) as PackageMeta[];
      const packageMap = new Map<string, PackageMeta>(packageRows.map((row) => [row.id, row]));
      const packageIds = packageRows.map((row) => row.id);
      if (!packageIds.length) return { rows: [] as StyleRow[], items: [] as AggItem[], packageMap };

      const allItems: AggItem[] = [];
      for (let i = 0; i < packageIds.length; i += 200) {
        const slice = packageIds.slice(i, i + 200);
        let itemQuery = (supabase as any)
          .from("warehouse_shipping_package_items")
          .select("id, package_id, io_id, sku_id, sku_code, style_no, product_name, qty")
          .in("package_id", slice)
          .limit(10000);
        if (filters.sku) {
          const safeSku = filters.sku.replace(/[,()]/g, "");
          itemQuery = itemQuery.or(`sku_id.ilike.%${safeSku}%,sku_code.ilike.%${safeSku}%,style_no.ilike.%${safeSku}%,product_name.ilike.%${safeSku}%`);
        }
        const { data: items, error: itemError } = await itemQuery;
        if (itemError) throw itemError;
        for (const item of items ?? []) {
          allItems.push({
            id: item.id,
            package_id: item.package_id,
            io_id: item.io_id,
            sku_id: item.sku_id,
            sku_code: item.sku_code,
            style_no: item.style_no,
            product_name: item.product_name,
            qty: Number(item.qty ?? 0),
            _style: "",
          });
        }
      }

      const packageItemCount = new Map<string, number>();
      for (const item of allItems) {
        item._style = styleFallback(item.style_no, item.sku_code ?? item.sku_id, item.product_name);
        packageItemCount.set(item.package_id, (packageItemCount.get(item.package_id) ?? 0) + 1);
      }

      const allowed = new Set<string>();
      for (const row of packageRows) {
        const count = packageItemCount.get(row.id) ?? 0;
        if (filters.hasItems === "yes" && count === 0) continue;
        if (filters.hasItems === "no" && count > 0) continue;
        if (filters.abnormal === "yes" && count > 0) continue;
        if (filters.abnormal === "no" && count === 0) continue;
        allowed.add(row.id);
      }

      const filteredItems = allItems.filter((item) => allowed.has(item.package_id));
      const styleMap = new Map<string, StyleRow>();
      for (const item of filteredItems) {
        const pkg = packageMap.get(item.package_id);
        const shop = (pkg?.shop_name ?? "").trim() || "(未知店铺)";
        const style = item._style;
        const key = `${style}__${shop}`;
        let row = styleMap.get(key);
        if (!row) {
          row = {
            key,
            style_no: style,
            product_name: item.product_name ?? "",
            shop_name: shop,
            qty: 0,
            package_set: new Set(),
            order_set: new Set(),
            sku_set: new Set(),
            wh_set: new Set(),
            first_ship: null,
            last_ship: null,
          };
          styleMap.set(key, row);
        }
        row.qty += item.qty;
        if (pkg?.io_id) row.package_set.add(pkg.io_id);
        if (pkg?.o_id) row.order_set.add(pkg.o_id);
        const sku = item.sku_code || item.sku_id || "";
        if (sku) row.sku_set.add(sku);
        const warehouse = pkg?.warehouse_name || pkg?.wh_id || "";
        if (warehouse) row.wh_set.add(warehouse);
        const shipDate = pkg?.send_date ?? null;
        if (shipDate) {
          if (!row.first_ship || shipDate < row.first_ship) row.first_ship = shipDate;
          if (!row.last_ship || shipDate > row.last_ship) row.last_ship = shipDate;
        }
        if (!row.product_name && item.product_name) row.product_name = item.product_name;
      }

      const rows = Array.from(styleMap.values())
        .sort((a, b) => String(b.last_ship ?? "").localeCompare(String(a.last_ship ?? "")));
      return { rows, items: filteredItems, packageMap };
    },
    retry: 1,
  });
}

type Props = {
  filters: OutboundByStyleFilters;
  exportRef?: React.MutableRefObject<(() => void) | null>;
};

export default function OutboundByStyleTab({ filters, exportRef }: Props) {
  const aggQ = useStyleAggregate(filters);
  const [page, setPage] = useState(0);
  const [detailKey, setDetailKey] = useState<string | null>(null);
  useEffect(() => { setPage(0); }, [filters]);

  const rows = useMemo(() => aggQ.data?.rows ?? [], [aggQ.data?.rows]);
  const totalCount = rows.length;
  const pageRows = useMemo(() => rows.slice(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE), [rows, page]);
  const detailRow = useMemo(() => rows.find((row) => row.key === detailKey) ?? null, [rows, detailKey]);
  const detailItems = useMemo(() => {
    if (!detailRow || !aggQ.data) return [] as AggItem[];
    return aggQ.data.items.filter((item) => {
      const pkg = aggQ.data.packageMap.get(item.package_id);
      const shop = (pkg?.shop_name ?? "").trim() || "(未知店铺)";
      return item._style === detailRow.style_no && shop === detailRow.shop_name;
    });
  }, [detailRow, aggQ.data]);

  const exportRows = () => {
    if (!rows.length) return toast({ title: "无数据可导出" });
    const headers = ["款号", "商品名称", "店铺", "发货件数", "包裹数", "订单数", "SKU数", "首次发货", "最近发货", "涉及仓库"];
    const lines = [headers.join(",")];
    for (const row of rows) {
      lines.push([
        row.style_no,
        row.product_name,
        row.shop_name,
        row.qty,
        row.package_set.size,
        row.order_set.size,
        row.sku_set.size,
        formatDateTimeCN(row.first_ship, { withSeconds: false }),
        formatDateTimeCN(row.last_ship, { withSeconds: false }),
        whLabel(row.wh_set),
      ].map((value) => `"${String(value ?? "").replace(/"/g, '""')}"`).join(","));
    }
    const blob = new Blob(["\uFEFF" + lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `仓库发货款式统计_${todayCN()}.csv`;
    a.click();
  };

  useEffect(() => {
    if (exportRef) exportRef.current = exportRows;
    return () => { if (exportRef) exportRef.current = null; };
  });

  return (
    <Card>
      <CardContent className="p-0">
        <div className="flex items-center justify-between p-3 border-b">
          <div className="text-xs text-muted-foreground">
            按“款号 + 店铺”聚合 · 当前筛选 {totalCount} 个款式
          </div>
        </div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>款号</TableHead>
              <TableHead>商品名称</TableHead>
              <TableHead>店铺</TableHead>
              <TableHead className="text-right">发货件数</TableHead>
              <TableHead className="text-right">包裹数</TableHead>
              <TableHead className="text-right">订单数</TableHead>
              <TableHead className="text-right">SKU 数</TableHead>
              <TableHead>最近发货</TableHead>
              <TableHead>首次发货</TableHead>
              <TableHead>仓库</TableHead>
              <TableHead>操作</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {aggQ.isLoading && <TableRow><TableCell colSpan={11} className="text-center py-12 text-muted-foreground">聚合中...</TableCell></TableRow>}
            {aggQ.error && <TableRow><TableCell colSpan={11} className="text-center py-12 text-rose-600">读取失败：{(aggQ.error as Error).message}</TableCell></TableRow>}
            {!aggQ.isLoading && !aggQ.error && totalCount === 0 && (
              <TableRow><TableCell colSpan={11} className="text-center py-12 text-muted-foreground">当前筛选下没有款式发货数据</TableCell></TableRow>
            )}
            {pageRows.map((row) => (
              <TableRow key={row.key}>
                <TableCell className="font-mono text-xs">{row.style_no}</TableCell>
                <TableCell className="text-xs">{row.product_name || "-"}</TableCell>
                <TableCell className="text-xs">{row.shop_name}</TableCell>
                <TableCell className="text-right">{fmtInt(row.qty)}</TableCell>
                <TableCell className="text-right">{fmtInt(row.package_set.size)}</TableCell>
                <TableCell className="text-right">{fmtInt(row.order_set.size)}</TableCell>
                <TableCell className="text-right">{fmtInt(row.sku_set.size)}</TableCell>
                <TableCell className="text-xs whitespace-nowrap">{formatDateTimeCN(row.last_ship, { withSeconds: false })}</TableCell>
                <TableCell className="text-xs whitespace-nowrap">{formatDateTimeCN(row.first_ship, { withSeconds: false })}</TableCell>
                <TableCell className="text-xs">{whLabel(row.wh_set)}</TableCell>
                <TableCell>
                  <Button size="sm" variant="ghost" onClick={() => setDetailKey(row.key)}>详情</Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        {totalCount > PAGE_SIZE && (
          <div className="flex items-center justify-between p-3 border-t">
            <div className="text-xs text-muted-foreground">共 {totalCount} 条 · 第 {page + 1} / {Math.ceil(totalCount / PAGE_SIZE)} 页</div>
            <div className="flex gap-2">
              <Button size="sm" variant="outline" disabled={page === 0} onClick={() => setPage((value) => value - 1)}>上一页</Button>
              <Button size="sm" variant="outline" disabled={page + 1 >= Math.ceil(totalCount / PAGE_SIZE)} onClick={() => setPage((value) => value + 1)}>下一页</Button>
            </div>
          </div>
        )}

        <Sheet open={!!detailKey} onOpenChange={(open) => !open && setDetailKey(null)}>
          <SheetContent side="right" className="w-full sm:max-w-4xl overflow-y-auto">
            <SheetHeader>
              <SheetTitle>款式发货明细 · {detailRow?.style_no}</SheetTitle>
              <SheetDescription>
                {detailRow?.product_name || "-"} · 店铺 {detailRow?.shop_name} · 共 {detailItems.length} 条明细 · 合计 {fmtInt(detailRow?.qty)} 件
              </SheetDescription>
            </SheetHeader>
            <div className="mt-4">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>包裹号</TableHead>
                    <TableHead>订单号</TableHead>
                    <TableHead>店铺</TableHead>
                    <TableHead>仓库</TableHead>
                    <TableHead>SKU</TableHead>
                    <TableHead>商品名称</TableHead>
                    <TableHead className="text-right">数量</TableHead>
                    <TableHead>快递公司</TableHead>
                    <TableHead>快递单号</TableHead>
                    <TableHead>发货日期</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {detailItems.map((item) => {
                    const pkg = aggQ.data?.packageMap.get(item.package_id);
                    return (
                      <TableRow key={item.id}>
                        <TableCell className="font-mono text-xs">{pkg?.io_id || item.io_id || "-"}</TableCell>
                        <TableCell className="font-mono text-xs">{pkg?.o_id || "-"}</TableCell>
                        <TableCell className="text-xs">{pkg?.shop_name || "-"}</TableCell>
                        <TableCell className="text-xs">{pkg?.warehouse_name || pkg?.wh_id || "-"}</TableCell>
                        <TableCell className="font-mono text-xs">{item.sku_code || item.sku_id || "-"}</TableCell>
                        <TableCell className="text-xs">{item.product_name || "-"}</TableCell>
                        <TableCell className="text-right">{fmtInt(item.qty)}</TableCell>
                        <TableCell className="text-xs">{pkg?.logistics_company || "-"}</TableCell>
                        <TableCell className="font-mono text-xs">{pkg?.tracking_number || "-"}</TableCell>
                        <TableCell className="text-xs whitespace-nowrap">{formatDateTimeCN(pkg?.send_date, { withSeconds: false })}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          </SheetContent>
        </Sheet>
      </CardContent>
    </Card>
  );
}
