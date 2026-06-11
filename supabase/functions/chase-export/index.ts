// 催货单导出（xlsx 带图）
// POST { mode?: "supplier" | "closed", supplier_id?: string }
//   mode=supplier（默认）：导出单个供应商的催货单，supplier_id 必填；
//   mode=closed         ：导出「厂家已结单」少交清单（仅内部账号）。
//
// 权限：转发调用方 Authorization 去调 ops_chase_supplier_list /
// ops_chase_closed_short_list，沿用 RPC 自身口径（内部全量、供应商只能导自己），
// 不使用 service role 绕权限。
//
// 款图由服务端 fetch（浏览器抓抖音图床受 CORS 限制）：每款只取一次、
// 并发 5、单图 3 秒超时、失败留空继续，嵌入款组合并单元格。

import { Buffer } from "node:buffer";
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import ExcelJS from "npm:exceljs@4.4.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const NUMERIC_ID = /^\d{12,}$/;
const IMG_CONCURRENCY = 5;
const IMG_TIMEOUT_MS = 3000;
const IMG_PX = 64;

/* ---------- 与 ChaseListVisual.tsx 一致的款合并规则 ---------- */

function shortName(name: string | null | undefined, styleNo: string): string {
  if (!name) return styleNo;
  const m = name.match(/【(.+?)】/);
  let s = (m ? m[1] : name).replace(/Lenakids/gi, "");
  s = s.split(styleNo).join("").trim().replace(/[.·\s]+$/, "");
  return s || styleNo;
}
function skuTail(sku: string, styleNo: string): string {
  return sku.startsWith(styleNo) ? sku.slice(styleNo.length) || sku : sku;
}
function todayCN(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai" }).format(new Date());
}
function md(iso: string): string {
  return `${+iso.slice(5, 7)}/${+iso.slice(8, 10)}`;
}
function fmtBJMinute(input: string | null): string {
  if (!input) return "-";
  const d = new Date(input);
  if (isNaN(d.getTime())) return "-";
  return d.toLocaleString("zh-CN", {
    timeZone: "Asia/Shanghai", hour12: false,
    month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  }).replace(/\//g, "-");
}

/* ---------- RPC 行类型 ---------- */

interface SupplierRow {
  supplier_id: string; supplier_name: string; sku: string; style_no: string;
  total_qty: number; overdue_qty: number; due24_qty: number;
  max_overdue_days: number; product_name: string | null; image_url: string | null;
}
interface ClosedRow {
  sku: string; style_no: string; supplier_name: string;
  short_qty: number; order_count: number; po_count: number;
  oldest_pay_time: string | null;
}
interface StyleImageRow { style_no: string; product_name: string | null; image_url: string | null }

/* ---------- 导出数据结构（每款一组，组内多行 SKU） ---------- */

interface ExportGroup {
  code: string;          // 款号
  name: string;          // 款名
  img: string | null;    // 款图 URL
  merged: string[];      // 竖向合并列的文本（款号、款名、…），不含款图列
  rows: (string | number)[][]; // 每行 SKU 的明细列
}

/* ---------- 款图抓取：每款一次、并发限制、超时留空 ---------- */

async function fetchImage(url: string): Promise<{ buf: Uint8Array; ext: "jpeg" | "png" | "gif" } | null> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), IMG_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: { Accept: "image/jpeg,image/png,image/gif,image/*;q=0.8" },
    });
    if (!res.ok) return null;
    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.length < 8) return null;
    // 以魔数判型，content-type 不可信；exceljs 只支持 jpeg/png/gif
    if (buf[0] === 0xff && buf[1] === 0xd8) return { buf, ext: "jpeg" };
    if (buf[0] === 0x89 && buf[1] === 0x50) return { buf, ext: "png" };
    if (buf[0] === 0x47 && buf[1] === 0x49) return { buf, ext: "gif" };
    return null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchImages(urls: (string | null)[]): Promise<Map<string, { buf: Uint8Array; ext: "jpeg" | "png" | "gif" }>> {
  const uniq = [...new Set(urls.filter((u): u is string => !!u))];
  const out = new Map<string, { buf: Uint8Array; ext: "jpeg" | "png" | "gif" }>();
  let i = 0;
  const worker = async () => {
    while (i < uniq.length) {
      const url = uniq[i++];
      const img = await fetchImage(url);
      if (img) out.set(url, img);
    }
  };
  await Promise.all(Array.from({ length: Math.min(IMG_CONCURRENCY, uniq.length) }, worker));
  return out;
}

/* ---------- 生成工作簿 ---------- */

async function buildWorkbook(opts: {
  title: string;
  mergedHeaders: string[];           // 款图之后、随款合并的表头（款号、款名、…）
  rowHeaders: { header: string; width: number; numeric?: boolean }[];
  groups: ExportGroup[];
}): Promise<Uint8Array> {
  const { title, mergedHeaders, rowHeaders, groups } = opts;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet("催货单", { views: [{ showGridLines: false }] });

  const colCount = 1 + mergedHeaders.length + rowHeaders.length;
  ws.columns = [
    { width: 9.5 },                                        // 款图 ≈64px
    ...mergedHeaders.map((_, i) => ({ width: i === 1 ? 26 : 14 })), // 款名列放宽
    ...rowHeaders.map((c) => ({ width: c.width })),
  ];

  // 首行标题
  ws.mergeCells(1, 1, 1, colCount);
  const titleCell = ws.getCell(1, 1);
  titleCell.value = title;
  titleCell.font = { size: 13, bold: true };
  titleCell.alignment = { vertical: "middle", horizontal: "left" };
  ws.getRow(1).height = 26;

  // 表头
  const headRow = ws.getRow(2);
  ["款图", ...mergedHeaders, ...rowHeaders.map((c) => c.header)].forEach((h, idx) => {
    const cell = headRow.getCell(idx + 1);
    cell.value = h;
    cell.font = { bold: true, size: 10 };
    cell.alignment = { vertical: "middle", horizontal: idx > mergedHeaders.length ? "right" : "left" };
    cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFF3F4F6" } };
  });
  headRow.height = 18;

  const images = await fetchImages(groups.map((g) => g.img));

  let rowIdx = 3;
  for (const g of groups) {
    const start = rowIdx;
    const k = g.rows.length;
    // 行高合计需容纳 64px 图（1pt = 4/3 px）
    const rowHeightPt = Math.max(18, Math.ceil((IMG_PX + 6) * 0.75 / k));
    for (const r of g.rows) {
      const row = ws.getRow(rowIdx);
      row.height = rowHeightPt;
      r.forEach((v, ci) => {
        const cell = row.getCell(2 + mergedHeaders.length + ci);
        cell.value = v;
        cell.alignment = { vertical: "middle", horizontal: rowHeaders[ci].numeric ? "right" : "left" };
        cell.font = { size: 10 };
      });
      rowIdx++;
    }
    const end = rowIdx - 1;
    // 款图 + 合并列：同款多行竖向合并
    if (end > start) {
      for (let c = 1; c <= 1 + mergedHeaders.length; c++) ws.mergeCells(start, c, end, c);
    }
    g.merged.forEach((v, mi) => {
      const cell = ws.getCell(start, 2 + mi);
      cell.value = v;
      cell.alignment = { vertical: "middle", horizontal: "left", wrapText: true };
      cell.font = { size: 10 };
    });
    const img = g.img ? images.get(g.img) : undefined;
    if (img) {
      const imgId = wb.addImage({ buffer: Buffer.from(img.buf) as unknown as ArrayBuffer, extension: img.ext });
      ws.addImage(imgId, {
        tl: { col: 0.05, row: start - 1 + 0.05 },
        ext: { width: IMG_PX, height: IMG_PX },
        editAs: "oneCell",
      });
    }
    // 组间发丝线
    for (let c = 1; c <= colCount; c++) {
      ws.getCell(end, c).border = { bottom: { style: "thin", color: { argb: "FFE3E5E8" } } };
    }
  }

  const out = await wb.xlsx.writeBuffer();
  return out instanceof Uint8Array ? out : new Uint8Array(out as ArrayBuffer);
}

/* ---------- 两种模式的分组 ---------- */

function groupSupplierRows(rows: SupplierRow[]) {
  interface G {
    code: string; name: string; img: string | null;
    total: number; overdue: number; maxOverdue: number;
    skus: { tail: string; qty: number; overdue: number }[];
  }
  const byStyle = new Map<string, G>();
  for (const r of rows) {
    const name = shortName(r.product_name, r.style_no);
    let g = byStyle.get(name);
    if (!g) {
      g = { code: r.style_no, name, img: r.image_url, total: 0, overdue: 0, maxOverdue: 0, skus: [] };
      byStyle.set(name, g);
    }
    if (NUMERIC_ID.test(g.code) && !NUMERIC_ID.test(r.style_no)) g.code = r.style_no;
    if (!g.img && r.image_url) g.img = r.image_url;
    g.total += Number(r.total_qty);
    g.overdue += Number(r.overdue_qty);
    g.maxOverdue = Math.max(g.maxOverdue, r.max_overdue_days);
    const tail = skuTail(r.sku, r.style_no);
    const exist = g.skus.find((k) => k.tail === tail);
    if (exist) { exist.qty += Number(r.total_qty); exist.overdue += Number(r.overdue_qty); }
    else g.skus.push({ tail, qty: Number(r.total_qty), overdue: Number(r.overdue_qty) });
  }
  // 款按已超时件数降序，款内 SKU 按已超时、件数降序
  const styles = [...byStyle.values()].sort((a, b) => b.overdue - a.overdue || b.total - a.total);
  for (const g of styles) g.skus.sort((a, b) => b.overdue - a.overdue || b.qty - a.qty);
  return styles;
}

/* ---------- HTTP 入口 ---------- */

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return json({ error: "Unauthorized" }, 401);
  const supabase = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: auth } },
  });
  const { data: claims, error: authErr } = await supabase.auth.getClaims(auth.slice(7));
  if (authErr || !claims?.claims?.sub) return json({ error: "Unauthorized" }, 401);

  let body: { mode?: string; supplier_id?: string } = {};
  try { body = await req.json(); } catch { /* 空 body 走默认 */ }
  const mode = body.mode === "closed" ? "closed" : "supplier";
  const today = todayCN();

  try {
    if (mode === "supplier") {
      if (!body.supplier_id) return json({ error: "缺少 supplier_id" }, 400);
      const { data, error } = await supabase.rpc("ops_chase_supplier_list");
      if (error) throw error;
      const rows = ((data ?? []) as SupplierRow[]).filter((r) => r.supplier_id === body.supplier_id);
      if (rows.length === 0) return json({ error: "该供应商当前没有待催数据（或无权导出）" }, 404);

      const supplierName = rows[0].supplier_name;
      const styles = groupSupplierRows(rows);
      const total = styles.reduce((s, g) => s + g.total, 0);
      const buf = await buildWorkbook({
        title: `${supplierName} 催货单 ${md(today)} · 合计 ${total} 件`,
        mergedHeaders: ["款号", "款名"],
        rowHeaders: [
          { header: "SKU", width: 16 },
          { header: "急需件数", width: 10, numeric: true },
          { header: "其中已超时", width: 11, numeric: true },
          { header: "最长超期天数", width: 13, numeric: true },
        ],
        groups: styles.map((g) => ({
          code: g.code, name: g.name, img: g.img,
          merged: [g.code, g.name],
          rows: g.skus.map((k) => [k.tail, k.qty, k.overdue, g.maxOverdue]),
        })),
      });
      return xlsx(buf, `催货单_${supplierName}_${today}.xlsx`);
    }

    // mode === "closed"：厂家已结单少交（RPC 内部已限内部账号）
    const { data, error } = await supabase.rpc("ops_chase_closed_short_list");
    if (error) throw error;
    const rows = (data ?? []) as ClosedRow[];
    if (rows.length === 0) return json({ error: "当前没有厂家已结单缺口" }, 404);

    // 款名/款图按款号批量取
    const styleNos = [...new Set(rows.map((r) => r.style_no).filter(Boolean))];
    const imgMap = new Map<string, StyleImageRow>();
    if (styleNos.length > 0) {
      const { data: imgs, error: imgErr } = await supabase.rpc("ops_style_images", { _style_nos: styleNos });
      if (!imgErr) for (const r of (imgs ?? []) as StyleImageRow[]) imgMap.set(r.style_no, r);
    }

    interface G { code: string; name: string; supplier: string; img: string | null; short: number; rows: ClosedRow[] }
    const byStyle = new Map<string, G>();
    for (const r of rows) {
      const meta = imgMap.get(r.style_no);
      const name = shortName(meta?.product_name, r.style_no || r.sku);
      const key = r.style_no || r.sku;
      let g = byStyle.get(key);
      if (!g) {
        g = { code: r.style_no || "-", name, supplier: r.supplier_name || "-", img: meta?.image_url ?? null, short: 0, rows: [] };
        byStyle.set(key, g);
      }
      g.short += Number(r.short_qty);
      g.rows.push(r);
    }
    const groups = [...byStyle.values()].sort((a, b) => b.short - a.short);
    for (const g of groups) g.rows.sort((a, b) => Number(b.short_qty) - Number(a.short_qty));
    const total = groups.reduce((s, g) => s + g.short, 0);

    const buf = await buildWorkbook({
      title: `厂家已结单缺口 ${md(today)} · 合计 ${total} 件`,
      mergedHeaders: ["款号", "款名", "供应商"],
      rowHeaders: [
        { header: "SKU", width: 16 },
        { header: "少交件数", width: 10, numeric: true },
        { header: "影响订单数", width: 11, numeric: true },
        { header: "最早付款", width: 14 },
      ],
      groups: groups.map((g) => ({
        code: g.code, name: g.name, img: g.img,
        merged: [g.code, g.name, g.supplier],
        rows: g.rows.map((r) => [
          skuTail(r.sku, g.code === "-" ? "" : g.code) || r.sku,
          Number(r.short_qty), Number(r.order_count), fmtBJMinute(r.oldest_pay_time),
        ]),
      })),
    });
    return xlsx(buf, `厂家已结单缺口_${today}.xlsx`);
  } catch (err) {
    const e = err as { code?: string; message?: string };
    const forbidden = e?.code === "42501" || /42501|权限|permission/i.test(e?.message ?? "");
    return json({ error: e?.message ?? "导出失败" }, forbidden ? 403 : 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function xlsx(buf: Uint8Array, filename: string) {
  const safe = filename.replace(/[\\/:*?"<>|]/g, "_");
  return new Response(buf, {
    headers: {
      ...corsHeaders,
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(safe)}`,
      "Access-Control-Expose-Headers": "Content-Disposition",
    },
  });
}
