// Edge Function: 聚水潭库存快照增量同步（断点续跑 job 引擎）
// API: /open/inventory/query 库存查询。探活实测（2026-06-14）：
//   modified_begin/end 必填且成对（裸拉报 code=170）、窗口≤7 天；page_size≤100；
//   查具体仓回传 wms_co_id，查全仓（不传）则无；allocate_qty/virtual_qty/in_qty 恒 0；
//   pick_lock ⊆ order_lock（可用=qty−order_lock，勿再减 pick_lock）；可用可为负（预售/缺口）。
//   现仅主仓 10843291 有货（卓强 11799039 / 云仓 12525996 = 0），但增量仍覆盖 3 仓留未来。
//
// 写入 ops_sku_inventory（SKU×仓库快照，upsert 覆盖）。只落 ops_skus 命中的 SKU；
// 命中不到记 ops_product_mapping_exceptions（去重、限量），不为库存凭空建 SKU；不落 raw JSON。
// 幂等：按 (sku_code, wms_co_id) upsert + skip_stale（jst_modified_at 未前移则跳过）。
//
// 鉴权：x-cron-secret = JST_SYNC_CRON_SECRET / x-internal-tick = SERVICE_ROLE / admin JWT。
// Actions:
//   start_inventory_job / tick_inventory_job / cancel_inventory_job  断点任务（minutes/hours/days 窗口）
//   sync_recent {days≤7} / sync_range {modified_begin, modified_end}  旧版入口 → 转 start_inventory_job
//   seed_by_skus {limit?, offset?, batch?}   按 ops_skus.sku_code 批量 sku_ids 种子（绕 170，覆盖慢动销）
//   refresh_token                            诊断辅助
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import {
  admin, callOpenweb, fmtBJ, parseJstBeijingDateTime, computeHasNext, pickList,
  resolveCaller, resolveWindow, sleep, RATE_DELAY_MS, MAX_PAGE_NO, forceRefreshAccessToken,
} from "../_shared/jst-client.ts";
import { handleJobActions, PageResult, ProcessPageArgs } from "../_shared/jst-sync-job.ts";

const SYNC_TYPE = "jst_inventory";
const METHOD_PATH = "inventory/query";
const PAGE_SIZE = 100; // /open/inventory/query 上限 100
const MAX_JOB_RANGE_DAYS = 7; // modified 窗口硬上限（接口 ≤7 天）
const EXCEPTION_SOURCE = "jst_inventory_query";

// 现有 3 仓（增量逐仓查；种子聚焦主仓）。主仓承载全部库存。
const WAREHOUSES: Array<{ wms: string; name: string }> = [
  { wms: "10843291", name: "杭州赫得(主仓)" },
  { wms: "11799039", name: "莉娜卓强仓" },
  { wms: "12525996", name: "莉娜-YG云仓" },
];
const MAIN_WMS = "10843291";
const WMS_LIST = WAREHOUSES.map((w) => w.wms);

// ---------- 解析 ----------
type ParsedInv = {
  skuCode: string;
  wmsCoId: string;
  qty: number;
  orderLock: number;
  pickLock: number;
  purchaseQty: number;
  returnQty: number;
  defectiveQty: number;
  modifiedIso: string | null;
};

function n(v: unknown): number {
  if (v == null || v === "") return 0;
  const x = Number(v);
  return Number.isFinite(x) ? x : 0;
}

function parseRow(raw: any, wmsFallback: string): ParsedInv | null {
  const skuCode = String(raw?.sku_id ?? "").trim();
  if (!skuCode) return null;
  const wmsCoId = String(raw?.wms_co_id ?? "").trim() || wmsFallback;
  // modified 容错："2026-06-09 16:28:12" 或丢空格的 "2026-06-0916:28:12"
  let modifiedStr = String(raw?.modified ?? "").trim();
  const m = modifiedStr.match(/^(\d{4}-\d{1,2}-\d{1,2})(\d{1,2}:\d{1,2}:\d{1,2})$/);
  if (m) modifiedStr = `${m[1]} ${m[2]}`;
  return {
    skuCode,
    wmsCoId,
    qty: n(raw?.qty),
    orderLock: n(raw?.order_lock),
    pickLock: n(raw?.pick_lock),
    purchaseQty: n(raw?.purchase_qty),
    returnQty: n(raw?.return_qty),
    defectiveQty: n(raw?.defective_qty),
    modifiedIso: parseJstBeijingDateTime(modifiedStr),
  };
}

// ---------- 仓库名缓存（3 行，取一次） ----------
let _whNames: Map<string, string> | null = null;
async function warehouseNames(): Promise<Map<string, string>> {
  if (_whNames) return _whNames;
  const map = new Map<string, string>();
  for (const w of WAREHOUSES) map.set(w.wms, w.name); // 兜底用内置名
  const { data } = await admin.from("jst_warehouses").select("jst_wms_co_id, name");
  for (const row of (data ?? []) as any[]) {
    if (row.jst_wms_co_id && row.name) map.set(String(row.jst_wms_co_id), String(row.name));
  }
  _whNames = map;
  return map;
}

// ---------- 写库 ----------
const IN_CHUNK = 200;
async function selectColIn(table: string, selCol: string, whereCol: string, values: string[]): Promise<any[]> {
  const out: any[] = [];
  for (let i = 0; i < values.length; i += IN_CHUNK) {
    const { data, error } = await admin.from(table).select(selCol).in(whereCol, values.slice(i, i + IN_CHUNK));
    if (error) throw new Error(`${table}.${whereCol} preload: ${error.message}`);
    out.push(...(data ?? []));
  }
  return out;
}

type WriteStats = { upserted: number; unchanged: number; unmatched: number; exceptions: number; failed: number; lastError: string };

async function writeRows(rowsIn: ParsedInv[]): Promise<WriteStats> {
  const stats: WriteStats = { upserted: 0, unchanged: 0, unmatched: 0, exceptions: 0, failed: 0, lastError: "" };
  if (rowsIn.length === 0) return stats;

  // 同批次同 (sku,wms) 去重，留最新 modified
  const byKey = new Map<string, ParsedInv>();
  for (const r of rowsIn) {
    const k = `${r.skuCode}|${r.wmsCoId}`;
    const ex = byKey.get(k);
    if (!ex || (r.modifiedIso && (!ex.modifiedIso || r.modifiedIso > ex.modifiedIso))) byKey.set(k, r);
  }
  const rows = Array.from(byKey.values());

  // 命中主档 ops_skus
  const skuCodes = Array.from(new Set(rows.map((r) => r.skuCode)));
  const masterSet = new Set<string>(
    (await selectColIn("ops_skus", "sku_code", "sku_code", skuCodes)).map((x: any) => x.sku_code),
  );
  const matched = rows.filter((r) => masterSet.has(r.skuCode));
  const unmatched = Array.from(new Set(rows.filter((r) => !masterSet.has(r.skuCode)).map((r) => r.skuCode)));
  stats.unmatched = unmatched.length;

  // skip_stale：预载现有 (sku,wms) → jst_modified_at
  const matchedCodes = Array.from(new Set(matched.map((r) => r.skuCode)));
  const existing = new Map<string, string | null>();
  for (let i = 0; i < matchedCodes.length; i += IN_CHUNK) {
    const { data, error } = await admin
      .from("ops_sku_inventory")
      .select("sku_code, wms_co_id, jst_modified_at")
      .in("sku_code", matchedCodes.slice(i, i + IN_CHUNK))
      .in("wms_co_id", WMS_LIST);
    if (error) throw new Error(`ops_sku_inventory preload: ${error.message}`);
    for (const row of (data ?? []) as any[]) existing.set(`${row.sku_code}|${row.wms_co_id}`, row.jst_modified_at);
  }

  const whNames = await warehouseNames();
  const nowIso = new Date().toISOString();
  const payload: any[] = [];
  for (const r of matched) {
    const k = `${r.skuCode}|${r.wmsCoId}`;
    const exMod = existing.get(k);
    if (exMod && r.modifiedIso && Date.parse(exMod) >= Date.parse(r.modifiedIso)) {
      stats.unchanged++;
      continue;
    }
    payload.push({
      sku_code: r.skuCode,
      jst_sku_id: r.skuCode,
      wms_co_id: r.wmsCoId,
      warehouse_name: whNames.get(r.wmsCoId) ?? null,
      qty: r.qty,
      order_lock: r.orderLock,
      pick_lock: r.pickLock,
      purchase_qty: r.purchaseQty,
      return_qty: r.returnQty,
      defective_qty: r.defectiveQty,
      jst_modified_at: r.modifiedIso,
      last_synced_at: nowIso,
    });
  }

  if (payload.length > 0) {
    const { error } = await admin.from("ops_sku_inventory").upsert(payload, { onConflict: "sku_code,wms_co_id" });
    if (error) {
      stats.failed += payload.length;
      stats.lastError = `upsert 失败: ${error.message}`;
      console.error(`[jst-inventory] ${stats.lastError}`);
    } else {
      stats.upserted = payload.length;
    }
  }

  stats.exceptions = await recordExceptions(unmatched);
  return stats;
}

// 异常落表：去重（pending 期内同 jst_sku_id+source 只一条）、限量（每次 ≤200）
async function recordExceptions(codes: string[]): Promise<number> {
  if (codes.length === 0) return 0;
  const capped = codes.slice(0, 200);
  const already = new Set<string>();
  for (let i = 0; i < capped.length; i += IN_CHUNK) {
    const { data } = await admin
      .from("ops_product_mapping_exceptions")
      .select("jst_sku_id")
      .eq("status", "pending")
      .eq("source_table", EXCEPTION_SOURCE)
      .in("jst_sku_id", capped.slice(i, i + IN_CHUNK));
    for (const row of (data ?? []) as any[]) already.add(row.jst_sku_id);
  }
  const toInsert = capped.filter((c) => !already.has(c)).map((c) => ({
    platform: "jst",
    jst_sku_id: c,
    source_table: EXCEPTION_SOURCE,
    reason: "库存接口返回的 SKU 在主档 ops_skus 中不存在，未落库存",
    status: "pending",
    raw_data: {},
  }));
  if (toInsert.length === 0) return 0;
  const { error, count } = await admin
    .from("ops_product_mapping_exceptions")
    .insert(toInsert, { count: "exact" });
  if (error && !/duplicate key/i.test(error.message)) {
    console.error(`[jst-inventory] 异常落表失败: ${error.message}`);
    return 0;
  }
  return count ?? toInsert.length;
}

// ---------- job processPage：同一 (window,page) 逐仓查 ----------
async function processInventoryPage(args: ProcessPageArgs): Promise<PageResult> {
  const { windowFrom, windowTo, pageIndex, pageSize } = args;
  if (pageIndex > MAX_PAGE_NO) throw new Error(`分页超过上限 ${MAX_PAGE_NO}`);
  const t0 = Date.now();
  const ps = Math.min(Number(pageSize) || PAGE_SIZE, PAGE_SIZE);
  const allRows: ParsedInv[] = [];
  const perWh: Record<string, number> = {};
  let anyHasNext = false;
  let lastReqBody: any = null;

  for (const wms of WMS_LIST) {
    await sleep(RATE_DELAY_MS);
    const reqBody = {
      page_index: String(pageIndex),
      page_size: String(ps),
      modified_begin: fmtBJ(windowFrom),
      modified_end: fmtBJ(windowTo),
      wms_co_id: wms,
    };
    lastReqBody = reqBody;
    let data: any;
    try {
      data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
    } catch (e: any) {
      e.requestBody = reqBody;
      e.apiPath = METHOD_PATH;
      e.durationMs = Date.now() - t0;
      throw e;
    }
    const list = pickList(data, ["inventorys", "datas"]);
    perWh[wms] = list.length;
    if (computeHasNext(data, list.length, ps, pageIndex)) anyHasNext = true;
    for (const raw of list) {
      const r = parseRow(raw, wms);
      if (r) allRows.push(r);
    }
  }

  const stats = await writeRows(allRows);
  return {
    apiCount: allRows.length,
    mainUpserted: stats.upserted,
    itemUpserted: 0,
    failed: stats.failed,
    hasNext: anyHasNext,
    errorDetail: stats.lastError || undefined,
    requestBody: lastReqBody,
    durationMs: Date.now() - t0,
    responseMsg: `wh=${JSON.stringify(perWh)} unchanged=${stats.unchanged} unmatched=${stats.unmatched} exceptions=${stats.exceptions}`,
  };
}

// ---------- seed_by_skus：按主档 sku_code 批量 sku_ids 种子（绕 170） ----------
async function startScopedLog(label: string): Promise<string> {
  const { data, error } = await admin.from("jst_sync_logs").insert({
    sync_type: SYNC_TYPE, status: "running", message: label,
  }).select("id").single();
  if (error) throw error;
  return data!.id as string;
}

async function seedBySkus(opts: { limit: number; offset: number; batch: number; wms: string }, logId: string) {
  let processed = 0, upserted = 0, unchanged = 0, unmatched = 0, failed = 0;
  let lastError = "";
  try {
    // 取主档 sku_code（按 sku_code 排序稳定分页）
    const { data: skuRows, error: skErr } = await admin
      .from("ops_skus")
      .select("sku_code")
      .not("sku_code", "is", null)
      .order("sku_code", { ascending: true })
      .range(opts.offset, opts.offset + opts.limit - 1);
    if (skErr) throw new Error(`读取 ops_skus 失败: ${skErr.message}`);
    const codes = (skuRows ?? []).map((r: any) => r.sku_code).filter(Boolean);

    for (let i = 0; i < codes.length; i += opts.batch) {
      const slice = codes.slice(i, i + opts.batch);
      await sleep(RATE_DELAY_MS);
      const reqBody: Record<string, unknown> = {
        page_index: "1",
        page_size: String(PAGE_SIZE),
        sku_ids: slice.join(","),
        wms_co_id: opts.wms, // 主仓；若接口忽略/报错可去掉走全仓汇总（≈主仓）
      };
      let data: any;
      try {
        data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
      } catch (e: any) {
        // sku_ids 与 wms_co_id 不兼容时退回全仓汇总（响应无 wms_co_id → parseRow 用 fallback=主仓）
        const msg = String(e?.message ?? e);
        if (/wms_co_id|分仓|参数/i.test(msg)) {
          delete reqBody.wms_co_id;
          data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
        } else {
          throw e;
        }
      }
      const list = pickList(data, ["inventorys", "datas"]);
      const parsed = list.map((raw: any) => parseRow(raw, opts.wms)).filter((x): x is ParsedInv => x !== null);
      const stats = await writeRows(parsed);
      processed += slice.length;
      upserted += stats.upserted;
      unchanged += stats.unchanged;
      unmatched += stats.unmatched;
      failed += stats.failed;
      if (stats.lastError) lastError = stats.lastError;
      await admin.from("jst_sync_logs").update({
        fetched_orders_count: upserted, fetched_items_count: upserted,
        heartbeat_at: new Date().toISOString(),
        message: `[库存种子] 已处理 ${processed}/${codes.length} SKU · upsert ${upserted} · 未变更 ${unchanged} · 未命中主档 ${unmatched} · 失败 ${failed}`,
      }).eq("id", logId);
    }

    await admin.from("jst_sync_logs").update({
      status: failed === 0 ? "success" : (upserted > 0 ? "partial_failed" : "failed"),
      ended_at: new Date().toISOString(),
      fetched_orders_count: upserted, fetched_items_count: upserted,
      message: `[库存种子] 完成 · SKU ${processed} · upsert ${upserted} · 未变更 ${unchanged} · 未命中主档 ${unmatched} · 失败 ${failed}${lastError ? ` · 末次错误: ${lastError}` : ""}`,
      error_detail: lastError,
    }).eq("id", logId);
  } catch (e: any) {
    await admin.from("jst_sync_logs").update({
      status: "failed", ended_at: new Date().toISOString(),
      message: `[库存种子] 失败 · 已处理 ${processed}`,
      error_detail: String(e?.message ?? e).slice(0, 1500),
    }).eq("id", logId);
  }
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  try {
    const caller = await resolveCaller(req);
    const cronSecret = req.headers.get("x-cron-secret") ?? "";
    const okCron = !!Deno.env.get("JST_SYNC_CRON_SECRET") && cronSecret === Deno.env.get("JST_SYNC_CRON_SECRET");
    const internalTick = req.headers.get("x-internal-tick") ?? "";
    const okInternal = !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") && internalTick === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!okCron && !okInternal && !caller.isAdmin) return json({ error: "Unauthorized" }, 401);

    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const action: string = body.action ?? "sync_recent";

    if (action === "refresh_token") {
      await forceRefreshAccessToken();
      await admin.from("jst_sync_logs").insert({
        sync_type: SYNC_TYPE, status: "success", ended_at: new Date().toISOString(),
        message: "[refresh_token] access_token 已刷新",
      });
      return json({ ok: true });
    }

    if (action === "seed_by_skus") {
      const limit = Math.min(20000, Math.max(1, Number(body.limit ?? 20000)));
      const offset = Math.max(0, Number(body.offset ?? 0));
      const batch = Math.min(100, Math.max(1, Number(body.batch ?? 100)));
      const wms = String(body.wms_co_id ?? MAIN_WMS);
      const logId = await startScopedLog(`[库存种子] limit=${limit} offset=${offset} batch=${batch} wms=${wms}`);
      // @ts-ignore EdgeRuntime available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(seedBySkus({ limit, offset, batch, wms }, logId));
      return json({ ok: true, background: true, log_id: logId, action });
    }

    // 旧入口 → 断点任务
    let jobAction = action;
    let jobBody: any = body;
    if (action === "sync_recent") {
      jobAction = "start_inventory_job";
      jobBody = { ...body, days: Math.min(7, Math.max(1, Number(body.days ?? 1))) };
    } else if (action === "sync_range") {
      const fromIso = parseJstBeijingDateTime(body.modified_begin);
      const toIso = parseJstBeijingDateTime(body.modified_end);
      if (!fromIso || !toIso) throw new Error("缺少/非法 modified_begin / modified_end");
      jobAction = "start_inventory_job";
      jobBody = { ...body, start_time: fromIso, end_time: toIso };
    }

    const jobResp = await handleJobActions({
      action: jobAction, body: jobBody, syncType: SYNC_TYPE, callerUid: caller.uid,
      processPage: processInventoryPage,
      startActionName: "start_inventory_job",
      tickActionName: "tick_inventory_job",
      cancelActionName: "cancel_inventory_job",
      functionName: "jst-sync-inventory",
      config: { pageSize: PAGE_SIZE, maxWindowDays: 1, maxPagesPerRun: 3, timeBudgetSeconds: 40 },
      resolveWindowFromBody: (b) => {
        const { from, to } = resolveWindow(b);
        if (to.getTime() - from.getTime() > MAX_JOB_RANGE_DAYS * 86400_000) {
          throw new Error(`库存同步窗口最大 ${MAX_JOB_RANGE_DAYS} 天（接口限制）；请缩小时间范围`);
        }
        return { from, to };
      },
    });
    if (jobResp) {
      const text = await jobResp.text();
      return new Response(text, { status: jobResp.status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    throw new Error(`未知 action: ${action}`);
  } catch (err) {
    return json({ ok: false, error: (err as Error).message }, 500);
  }
});
