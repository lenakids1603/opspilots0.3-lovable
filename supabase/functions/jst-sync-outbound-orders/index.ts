// Edge Function: JST outbound lightweight sync.
// API: /open/orders/out/simple/query
// Purpose: warehouse shipping package statistics only.
// Writes warehouse_shipping_packages + warehouse_shipping_package_items.
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import {
  admin,
  callOpenweb,
  computeHasNext,
  fmtBJ,
  MAX_PAGE_NO,
  parseJstBeijingDateTime,
  pickItemsArray,
  pickList,
  RATE_DELAY_MS,
  resolveCaller,
  resolveWindow,
  sleep,
} from "../_shared/jst-client.ts";
import { handleJobActions, PageResult, ProcessPageArgs } from "../_shared/jst-sync-job.ts";
import { formatSkipNote, loadSkippedShops, shopIdOf, shouldSkipShop } from "../_shared/shop-filter.ts";

const SYNC_TYPE = "outbound_orders";
const METHOD_PATH = "orders/out/simple/query";
const PAGE_SIZE = 50;
type JstRecord = Record<string, unknown>;
type JstError = Error & {
  code?: unknown;
  apiMsg?: unknown;
  requestBody?: Record<string, unknown>;
  apiPath?: string;
  responseCode?: unknown;
  responseMsg?: unknown;
  durationMs?: number;
};

// The field probe showed the API rejects the full InoutFlds/InoutItemFlds
// candidate set with code=130, so production sync keeps the minimal request and
// stores only the lightweight fields we actually need.
type ParamMode = "with_status" | "minimal";

function buildReqBody(mode: ParamMode, pageIndex: number, pageSize: number, from: Date, to: Date) {
  const size = Math.min(Math.max(Number(pageSize) || PAGE_SIZE, 1), 50);
  const body: Record<string, unknown> = {
    page_index: String(pageIndex),
    page_size: String(size),
    modified_begin: fmtBJ(from),
    modified_end: fmtBJ(to),
  };
  if (mode === "with_status") body.status = "Confirmed";
  return body;
}

function firstText(...values: unknown[]) {
  for (const value of values) {
    if (value == null) continue;
    const text = String(value).trim();
    if (text) return text;
  }
  return null;
}

function numberOrNull(value: unknown) {
  if (value == null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function styleFallback(styleNo: unknown, sku: unknown, name: unknown) {
  const direct = firstText(styleNo);
  if (direct) return direct;
  const skuText = firstText(sku);
  if (skuText) {
    const matched = skuText.match(/^\d{6,12}/);
    if (matched) return matched[0];
    const segment = skuText.split(/[-_/\s]/)[0];
    if (segment) return segment;
  }
  return firstText(name);
}

function resolveShippingDate(row: JstRecord) {
  // Business shipping date priority: send_date -> consign_time -> io_date.
  return parseJstBeijingDateTime(row.send_date ?? row.consign_time ?? row.consigntime ?? row.io_date);
}

function buildItemUniqueKey(ioId: string, item: JstRecord, index: number) {
  const ioiId = firstText(item.ioi_id, item.ioiId);
  if (ioiId) return `${ioId}|${ioiId}`;

  const oiId = firstText(item.oi_id, item.oiId);
  const skuId = firstText(item.sku_id, item.shop_sku_id, item.sku_code);
  if (oiId && skuId) return `${ioId}|${oiId}|${skuId}`;

  return `${ioId}|${skuId ?? "item"}|${index}`;
}

async function upsertShippingPackage(rowFromJst: JstRecord): Promise<{ packageId: string; itemsUpserted: number }> {
  const ioId = firstText(rowFromJst.io_id, rowFromJst.ioId);
  if (!ioId) throw new Error("missing io_id");

  const itemList = pickItemsArray(rowFromJst) as JstRecord[];
  const packageUniqueKey = ioId;
  const syncedAt = new Date().toISOString();
  const packageRow = {
    package_unique_key: packageUniqueKey,
    io_id: ioId,
    so_id: firstText(rowFromJst.so_id, rowFromJst.soId),
    o_id: firstText(rowFromJst.o_id, rowFromJst.oId),
    shop_id: firstText(rowFromJst.shop_id, rowFromJst.shopId),
    shop_name: firstText(rowFromJst.shop_name, rowFromJst.shopName),
    wh_id: firstText(rowFromJst.wh_id, rowFromJst.whId, rowFromJst.wms_co_id, rowFromJst.wmsCoId),
    warehouse_name: firstText(rowFromJst.warehouse_name, rowFromJst.warehouseName, rowFromJst.warehouse),
    send_date: resolveShippingDate(rowFromJst),
    logistics_company: firstText(rowFromJst.logistics_company, rowFromJst.logisticsCompany),
    tracking_number: firstText(
      rowFromJst.tracking_number,
      rowFromJst.waybill_no,
      rowFromJst.express_no,
      rowFromJst.l_id,
      rowFromJst.lId,
    ),
    weight: numberOrNull(rowFromJst.weight ?? rowFromJst.f_weight),
    shipping_method: firstText(rowFromJst.shipping_method, rowFromJst.delivery_type),
    status: firstText(rowFromJst.status),
    modified_at_jst: parseJstBeijingDateTime(rowFromJst.modified),
    synced_at: syncedAt,
  };

  const { data: pkg, error } = await admin
    .from("warehouse_shipping_packages")
    .upsert(packageRow, { onConflict: "package_unique_key" })
    .select("id")
    .maybeSingle();
  if (error) throw error;
  // 条件更新(modified 未变则跳过写入)时 RETURNING 为空:回查已有行 id
  let packageId = pkg?.id as string | undefined;
  if (!packageId) {
    const { data: existing, error: exErr } = await admin
      .from("warehouse_shipping_packages")
      .select("id").eq("package_unique_key", packageUniqueKey).single();
    if (exErr) throw exErr;
    packageId = existing.id as string;
  }

  const itemRows = itemList.map((item, index) => {
    const skuId = firstText(item.sku_id, item.shop_sku_id, item.sku_code);
    const productName = firstText(item.product_name, item.name, item.sku_name);
    return {
      item_unique_key: buildItemUniqueKey(ioId, item, index),
      package_id: packageId,
      package_unique_key: packageUniqueKey,
      io_id: ioId,
      so_id: packageRow.so_id,
      o_id: packageRow.o_id,
      sku_id: skuId,
      sku_code: firstText(item.sku_code, skuId),
      style_no: styleFallback(item.style_no ?? item.i_id ?? item.item_id, skuId, productName),
      product_name: productName,
      qty: Number(item.qty ?? item.sale_qty ?? item.total_qty ?? 0),
      modified_at_jst: packageRow.modified_at_jst,
      synced_at: syncedAt,
    };
  });

  if (!itemRows.length) return { packageId, itemsUpserted: 0 };

  const { error: itemError } = await admin
    .from("warehouse_shipping_package_items")
    .upsert(itemRows, { onConflict: "item_unique_key" });
  if (itemError) throw itemError;

  return { packageId, itemsUpserted: itemRows.length };
}

async function callOutbound(initialMode: ParamMode, pageIndex: number, pageSize: number, from: Date, to: Date) {
  const modes: ParamMode[] = initialMode === "minimal" ? ["minimal"] : ["with_status", "minimal"];
  let lastErr: JstError | null = null;
  for (const mode of modes) {
    const reqBody = buildReqBody(mode, pageIndex, pageSize, from, to);
    const started = Date.now();
    try {
      const data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
      return { data, mode, reqBody, durationMs: Date.now() - started };
    } catch (error) {
      const err = error as JstError;
      lastErr = err;
      const code = String(err?.code ?? "");
      const isParamError = code === "130" || /参数无法转换|参数错误/.test(String(err?.apiMsg ?? err?.message ?? ""));
      if (!(isParamError && mode === "with_status")) {
        err.requestBody = reqBody;
        err.apiPath = METHOD_PATH;
        err.responseCode = err.responseCode ?? (code || null);
        err.responseMsg = err.responseMsg ?? (err?.apiMsg ?? null);
        err.durationMs = err.durationMs ?? (Date.now() - started);
        throw err;
      }
    }
  }
  if (lastErr) {
    lastErr.apiPath = METHOD_PATH;
    throw lastErr;
  }
  throw new Error("callOutbound: unknown error");
}

async function processOutboundPage(args: ProcessPageArgs): Promise<PageResult> {
  const { job, windowFrom, windowTo, pageIndex, pageSize } = args;
  await sleep(RATE_DELAY_MS);
  if (pageIndex > MAX_PAGE_NO) throw new Error(`page index exceeded ${MAX_PAGE_NO}`);

  const meta = (job?.metadata ?? {}) as Record<string, unknown>;
  const initialMode: ParamMode = meta.param_mode === "minimal" ? "minimal" : "with_status";
  const { data, mode, reqBody, durationMs } = await callOutbound(initialMode, pageIndex, pageSize, windowFrom, windowTo);

  if (mode !== initialMode) {
    try {
      await admin.from("jst_sync_jobs").update({
        metadata: { ...meta, param_mode: mode, param_mode_locked_at: new Date().toISOString() },
      }).eq("id", job.id);
    } catch (_error) {
      // Best-effort metadata only.
    }
  }

  const list = pickList(data);
  const hasNext = computeHasNext(data, list.length, Number(reqBody.page_size), pageIndex);
  const skippedShopIds = new Set<string>();
  const skippedShops = await loadSkippedShops();
  let mainUpserted = 0;
  let itemUpserted = 0;
  let failed = 0;
  let skippedDisabled = 0;
  let skippedSyncOff = 0;
  let lastErr = "";

  for (const row of list) {
    const shopId = shopIdOf(row);
    const skip = shouldSkipShop(shopId, skippedShops);
    if (skip === "disabled") {
      skippedDisabled++;
      skippedShopIds.add(shopId);
      continue;
    }
    if (skip === "sync_off") {
      skippedSyncOff++;
      skippedShopIds.add(shopId);
      continue;
    }

    try {
      const result = await upsertShippingPackage(row);
      mainUpserted++;
      itemUpserted += result.itemsUpserted;
    } catch (error) {
      failed++;
      lastErr = String((error as Error).message ?? error);
    }
  }

  const skipNote = formatSkipNote(skippedDisabled, skippedSyncOff, skippedShopIds.size);
  return {
    apiCount: list.length,
    mainUpserted,
    itemUpserted,
    failed,
    hasNext,
    errorDetail: (lastErr || skipNote) ? `${lastErr}${skipNote}` : undefined,
    requestBody: { ...reqBody, _param_mode: mode, _target_tables: ["warehouse_shipping_packages", "warehouse_shipping_package_items"] },
    responseCode: "0",
    responseMsg: "success",
    durationMs,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const caller = await resolveCaller(req);
    const cronSecret = req.headers.get("x-cron-secret") ?? "";
    const internalTick = req.headers.get("x-internal-tick") ?? "";
    const okCron = !!Deno.env.get("JST_SYNC_CRON_SECRET") && cronSecret === Deno.env.get("JST_SYNC_CRON_SECRET");
    const okInternal = !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") && internalTick === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!okCron && !okInternal && !caller.isAdmin) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const action: string = body.action ?? "";
    const jobResp = await handleJobActions({
      action,
      body,
      syncType: SYNC_TYPE,
      callerUid: caller.uid,
      processPage: processOutboundPage,
      startActionName: "start_outbound_job",
      tickActionName: "tick_outbound_job",
      cancelActionName: "cancel_outbound_job",
      functionName: "jst-sync-outbound-orders",
      config: {
        // A 1-day request is split into 1-hour windows to protect the Edge
        // Function runtime and JST API. The UI exposes 2h test and 1d sync only.
        pageSize: PAGE_SIZE,
        maxWindowDays: 1 / 24,
        maxPagesPerRun: 2,
        timeBudgetSeconds: 35,
        proactiveSplitAfterPage: 10,
      },
      resolveWindowFromBody: (b) => resolveWindow(b),
    });
    if (jobResp) {
      const text = await jobResp.text();
      return new Response(text, {
        status: jobResp.status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({
      ok: false,
      error: "Please use start_outbound_job / tick_outbound_job / cancel_outbound_job",
    }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    const err = error as JstError;
    return new Response(JSON.stringify({
      ok: false,
      error: err.message,
      response_code: err?.responseCode ?? err?.code ?? null,
      response_msg: err?.responseMsg ?? err?.apiMsg ?? null,
      request_body: err?.requestBody ?? null,
    }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
