import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import {
  admin,
  callOpenweb,
  fmtBJ,
  parseHasNext,
  resolveCaller,
} from "../_shared/jst-client.ts";

const METHOD_PATH = "orders/out/simple/query";
const SYNC_TYPE = "outbound_orders_field_probe";
const MAX_WINDOW_HOURS = 2;
const MAX_SAMPLE_ROWS = 10;

const HEADER_CANDIDATES = [
  "io_id",
  "so_id",
  "o_id",
  "shop_id",
  "shop_name",
  "wh_id",
  "wms_co_id",
  "warehouse",
  "warehouse_name",
  "send_date",
  "consign_time",
  "consigntime",
  "io_date",
  "logistics_company",
  "l_id",
  "tracking_number",
  "waybill_no",
  "express_no",
  "weight",
  "f_weight",
  "shipping_method",
  "delivery_type",
  "status",
  "modified",
];

const ITEM_ARRAY_CANDIDATES = [
  "items",
  "skus",
  "items_list",
  "order_items",
  "details",
  "item_list",
  "orderitems",
];

const ITEM_CANDIDATES = [
  "ioi_id",
  "oi_id",
  "sku_id",
  "sku_code",
  "shop_sku_id",
  "i_id",
  "style_no",
  "product_name",
  "name",
  "sku_name",
  "qty",
  "sale_qty",
  "total_qty",
];
type JsonRecord = Record<string, unknown>;
type ProbeError = Error & { code?: unknown; apiMsg?: unknown };

const CASES = [
  { code: "default_fields", fields: {} },
  {
    code: "targeted_light_fields",
    fields: {
      InoutFlds: HEADER_CANDIDATES.join(","),
      InoutItemFlds: ITEM_CANDIDATES.join(","),
    },
  },
];

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function parseWindow(body: Record<string, unknown>) {
  const to = body.end_time ? new Date(String(body.end_time)) : new Date();
  const requestedHours = Number(body.hours ?? MAX_WINDOW_HOURS);
  const hours = Math.min(Math.max(Number.isFinite(requestedHours) ? requestedHours : MAX_WINDOW_HOURS, 0.01), MAX_WINDOW_HOURS);
  let from = body.start_time ? new Date(String(body.start_time)) : new Date(to.getTime() - hours * 3600_000);

  if (!Number.isFinite(to.getTime())) throw new Error("Invalid end_time");
  if (!Number.isFinite(from.getTime())) throw new Error("Invalid start_time");
  if (to.getTime() - from.getTime() > MAX_WINDOW_HOURS * 3600_000) {
    from = new Date(to.getTime() - MAX_WINDOW_HOURS * 3600_000);
  }
  if (from.getTime() >= to.getTime()) throw new Error("start_time must be before end_time");
  return { from, to };
}

function asRecord(value: unknown): JsonRecord | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonRecord : null;
}

function pickRows(data: unknown): JsonRecord[] {
  if (Array.isArray(data)) return data.filter((row): row is JsonRecord => !!asRecord(row));
  const record = asRecord(data);
  for (const key of ["datas", "list", "orders", "rows", "data"]) {
    const value = record?.[key];
    if (Array.isArray(value)) return value.filter((row): row is JsonRecord => !!asRecord(row));
  }
  const inner = asRecord(record?.data);
  if (inner) {
    for (const key of ["datas", "list", "orders", "rows"]) {
      const value = inner[key];
      if (Array.isArray(value)) return value.filter((row): row is JsonRecord => !!asRecord(row));
    }
  }
  return [];
}

function pickItems(row: unknown): { field: string | null; items: JsonRecord[] } {
  const record = asRecord(row);
  if (!record) return { field: null, items: [] };
  for (const field of ITEM_ARRAY_CANDIDATES) {
    const value = record[field];
    if (Array.isArray(value)) return { field, items: value.filter((item): item is JsonRecord => !!asRecord(item)) };
  }
  return { field: null, items: [] };
}

function keysOf(value: unknown): string[] {
  return value && typeof value === "object" && !Array.isArray(value) ? Object.keys(value as Record<string, unknown>).sort() : [];
}

function selectedFields(row: unknown, candidates: string[]) {
  const record = asRecord(row);
  const out: Record<string, unknown> = {};
  for (const key of candidates) {
    if (record?.[key] !== undefined) out[key] = record[key];
  }
  return out;
}

function countPresence(rows: JsonRecord[], candidates: string[]) {
  return Object.fromEntries(
    candidates.map((field) => [
      field,
      rows.filter((row) => row?.[field] !== undefined && row?.[field] !== null && row?.[field] !== "").length,
    ]),
  );
}

function summarizeRows(rows: JsonRecord[]) {
  const samples = rows.slice(0, MAX_SAMPLE_ROWS);
  const itemRows = samples.flatMap((row) => pickItems(row).items.slice(0, MAX_SAMPLE_ROWS));
  const firstRow = samples[0] ?? null;
  const firstItems = pickItems(firstRow);
  const itemArrayFields = [...new Set(samples.map((row) => pickItems(row).field).filter(Boolean))];

  return {
    sample_count: samples.length,
    header_keys: [...new Set(samples.flatMap((row) => keysOf(row)))].sort(),
    item_array_fields: itemArrayFields,
    first_item_array_field: firstItems.field,
    first_item_count: firstItems.items.length,
    item_keys: [...new Set(itemRows.flatMap((item) => keysOf(item)))].sort(),
    header_candidate_presence: countPresence(samples, HEADER_CANDIDATES),
    item_candidate_presence: countPresence(itemRows, ITEM_CANDIDATES),
    samples: samples.map((row, index) => {
      const itemInfo = pickItems(row);
      return {
        sample_no: index + 1,
        header: selectedFields(row, HEADER_CANDIDATES),
        item_array_field: itemInfo.field,
        item_count: itemInfo.items.length,
        first_item: selectedFields(itemInfo.items[0] ?? {}, ITEM_CANDIDATES),
      };
    }),
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
      return jsonResponse({ ok: false, error: "Unauthorized" }, 401);
    }

    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const { from, to } = parseWindow(body);
    const pageSize = Math.min(Math.max(Number(body.page_size ?? MAX_SAMPLE_ROWS) || MAX_SAMPLE_ROWS, 1), MAX_SAMPLE_ROWS);
    const persistDebug = body.persist_debug === true;

    const results = [];
    for (const testCase of CASES) {
      const requestBody = {
        page_index: "1",
        page_size: String(pageSize),
        modified_begin: fmtBJ(from),
        modified_end: fmtBJ(to),
        ...testCase.fields,
      };

      try {
        const data = await callOpenweb(METHOD_PATH, requestBody, { timeoutMs: 45_000 });
        const dataRecord = asRecord(data);
        const rows = pickRows(data).slice(0, MAX_SAMPLE_ROWS);
        results.push({
          case: testCase.code,
          ok: true,
          request_body_preview: requestBody,
          data_count: dataRecord?.data_count ?? dataRecord?.dataCount ?? rows.length,
          list_count: rows.length,
          has_next: parseHasNext(dataRecord?.has_next ?? dataRecord?.hasNext, rows.length === pageSize),
          ...summarizeRows(rows),
        });
      } catch (error) {
        const err = error as ProbeError;
        results.push({
          case: testCase.code,
          ok: false,
          request_body_preview: requestBody,
          response_code: err?.code ?? null,
          response_msg: err?.apiMsg ?? null,
          error_message: String(err?.message ?? error).slice(0, 800),
        });
      }
    }

    const payload = {
      ok: results.some((r) => r.ok),
      debug_only: true,
      persisted_debug: persistDebug,
      endpoint: `/open/${METHOD_PATH}`,
      window: {
        from: from.toISOString(),
        to: to.toISOString(),
        modified_begin: fmtBJ(from),
        modified_end: fmtBJ(to),
      },
      page_size: pageSize,
      note: "No business tables are written by this probe.",
      candidates: {
        header: HEADER_CANDIDATES,
        item_array_fields: ITEM_ARRAY_CANDIDATES,
        item: ITEM_CANDIDATES,
      },
      results,
    };

    if (persistDebug) {
      await admin.from("jst_api_debug_payloads").insert({
        sync_type: SYNC_TYPE,
        endpoint: `/open/${METHOD_PATH}`,
        request_body: {
          debug_only: true,
          window: payload.window,
          page_size: pageSize,
          cases: CASES.map((testCase) => ({ code: testCase.code, fields: testCase.fields })),
        },
        response_sample: {
          debug_only: true,
          results: results.map((result) => ({
            case: result.case,
            ok: result.ok,
            data_count: result.data_count,
            list_count: result.list_count,
            header_keys: result.header_keys,
            item_array_fields: result.item_array_fields,
            item_keys: result.item_keys,
            header_candidate_presence: result.header_candidate_presence,
            item_candidate_presence: result.item_candidate_presence,
            samples: result.samples,
          })),
        },
        expires_at: new Date(Date.now() + 86400_000).toISOString(),
      });
    }

    return jsonResponse(payload);
  } catch (error) {
    return jsonResponse({ ok: false, error: (error as Error).message }, 500);
  }
});
