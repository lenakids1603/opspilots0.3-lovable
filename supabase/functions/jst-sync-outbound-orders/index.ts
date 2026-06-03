// Edge Function: 聚水潭销售出库单同步（只读）
// API: /open/orders/out/simple/query  → method path orders/out/simple/query
// 写入 jst_outbound_orders + jst_outbound_order_items
// 日志写入 jst_sync_logs, sync_type='outbound_orders'
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import {
  admin, callOpenweb, fmtBJ, parseJstBeijingDateTime, parseHasNext,
  resolveCaller, resolveWindow, sleep, RATE_DELAY_MS, MAX_PAGE_NO,
} from "../_shared/jst-client.ts";

const SYNC_TYPE = "outbound_orders";
const METHOD_PATH = "orders/out/simple/query";
const PAGE_SIZE = 50;

function splitProps(v: string | null): { color: string | null; size: string | null } {
  if (!v) return { color: null, size: null };
  const parts = String(v).split(/[,;|，；]/).map((s) => s.trim()).filter(Boolean);
  return { color: parts[0] ?? null, size: parts[1] ?? null };
}

async function runSync(fromIso: string, toIso: string, logId: string) {
  const winFrom = new Date(fromIso);
  const winTo = new Date(toIso);
  let page = 1, apiCount = 0, orders = 0, items = 0, failed = 0;
  const errors: string[] = [];

  try {
    while (true) {
      if (page > MAX_PAGE_NO) throw new Error(`分页超过上限 ${MAX_PAGE_NO}`);
      await sleep(RATE_DELAY_MS);
      const data = await callOpenweb(METHOD_PATH, {
        page_index: page, page_size: PAGE_SIZE,
        modified_begin: fmtBJ(winFrom), modified_end: fmtBJ(winTo),
      });
      apiCount++;
      const list: any[] = data.datas ?? data.list ?? data.orders ?? [];
      const hasNext = parseHasNext(data.has_next ?? data.hasNext, list.length === PAGE_SIZE);

      for (const r of list) {
        const ioId = String(r.io_id ?? r.ioId ?? "");
        if (!ioId) continue;
        try {
          const row = {
            io_id: ioId,
            o_id: r.o_id ?? null,
            so_id: r.so_id ?? null,
            shop_id: r.shop_id != null ? String(r.shop_id) : null,
            shop_name: r.shop_name ?? null,
            warehouse: r.warehouse ?? null,
            wms_co_id: r.wms_co_id != null ? String(r.wms_co_id) : null,
            status: r.status ?? null,
            logistics_company: r.logistics_company ?? null,
            l_id: r.l_id ?? null,
            lc_id: r.lc_id != null ? String(r.lc_id) : null,
            io_date: parseJstBeijingDateTime(r.io_date),
            consign_time: parseJstBeijingDateTime(r.consign_time ?? r.consigntime),
            modified_at_jst: parseJstBeijingDateTime(r.modified),
            qty: Number(r.qty ?? 0),
            raw_data: r,
            synced_at: new Date().toISOString(),
          };
          const { data: up, error } = await admin
            .from("jst_outbound_orders")
            .upsert(row, { onConflict: "io_id" })
            .select("id")
            .single();
          if (error) throw error;
          orders++;
          const outboundOrderId = up.id as string;

          const itemList: any[] = r.items ?? [];
          for (const it of itemList) {
            const skuId = it.sku_id != null ? String(it.sku_id) : null;
            const props = splitProps(it.properties_value ?? null);
            const itemRow = {
              outbound_order_id: outboundOrderId,
              io_id: ioId,
              oi_id: it.oi_id != null ? String(it.oi_id) : null,
              ioi_id: it.ioi_id != null ? String(it.ioi_id) : null,
              sku_id: skuId,
              i_id: it.i_id != null ? String(it.i_id) : null,
              name: it.name ?? null,
              properties_value: it.properties_value ?? null,
              color: props.color,
              size: props.size,
              qty: Number(it.qty ?? 0),
              amount: Number(it.amount ?? 0),
              pic: it.pic ?? null,
              raw_data: it,
              synced_at: new Date().toISOString(),
            };
            const { error: itErr } = await admin
              .from("jst_outbound_order_items")
              .upsert(itemRow, { onConflict: "io_id,ioi_id,sku_id,oi_id" });
            if (itErr) throw itErr;
            items++;
          }
        } catch (we) {
          failed++;
          errors.push(`io_id=${ioId}: ${(we as Error).message}`);
        }
      }

      await admin.from("jst_sync_logs").update({
        fetched_orders_count: orders,
        fetched_items_count: items,
        message: `第 ${page} 页 已同步 ${orders} 出库单 / ${items} 明细 · has_next=${hasNext}`,
        heartbeat_at: new Date().toISOString(),
      }).eq("id", logId);

      if (!hasNext || list.length === 0) break;
      page++;
    }

    await admin.from("jst_sync_logs").update({
      status: errors.length && orders === 0 ? "failed" : (errors.length ? "partial_failed" : "success"),
      ended_at: new Date().toISOString(),
      fetched_orders_count: orders,
      fetched_items_count: items,
      message: `销售出库同步完成 · API ${apiCount} 次 · ${orders} 单 / ${items} 明细 · 失败 ${failed}`,
      error_detail: errors.length ? errors.slice(0, 10).join(" | ").slice(0, 1500) : null,
    }).eq("id", logId);
  } catch (e: any) {
    const err = e as any;
    const isAbort = err?.aborted || err?.name === "AbortError" || /abort/i.test(String(err?.message ?? ""));
    const isNoPerm = String(err?.code) === "190" || /无API权限|无api权限|无权限/i.test(String(err?.apiMsg ?? err?.message ?? ""));
    const friendly = isNoPerm
      ? "聚水潭无API权限，请在开放平台为当前应用申请：销售出库查询 /open/orders/out/simple/query"
      : isAbort
        ? "销售出库同步请求超时或被中断，请缩小时间范围。"
        : `销售出库同步失败 page=${page}`;
    const detail = [
      `final_api_path=${METHOD_PATH}`,
      err?.url ? `request_url=${err.url}` : null,
      `page_index=${page}`,
      `page_size=${PAGE_SIZE}`,
      `start_time=${fmtBJ(winFrom)}`,
      `end_time=${fmtBJ(winTo)}`,
      err?.code != null ? `response_code=${err.code}` : null,
      err?.apiMsg ? `response_msg=${err.apiMsg}` : null,
      err?.requestId ? `request_id=${err.requestId}` : null,
      `error_name=${err?.name ?? "Error"}`,
      `error_message=${String(err?.message ?? err).slice(0, 600)}`,
    ].filter(Boolean).join(" | ");
    await admin.from("jst_sync_logs").update({
      status: "failed",
      ended_at: new Date().toISOString(),
      fetched_orders_count: orders,
      fetched_items_count: items,
      message: friendly,
      error_detail: detail.slice(0, 1500),
    }).eq("id", logId);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const caller = await resolveCaller(req);
    const cronSecret = req.headers.get("x-cron-secret") ?? "";
    const okCron = !!Deno.env.get("JST_SYNC_CRON_SECRET") && cronSecret === Deno.env.get("JST_SYNC_CRON_SECRET");
    if (!okCron && !caller.isAdmin) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const { from, to } = resolveWindow(body);

    const { data: log, error: logErr } = await admin.from("jst_sync_logs").insert({
      sync_type: SYNC_TYPE,
      status: "running",
      cursor_from: from.toISOString(),
      cursor_to: to.toISOString(),
      message: `开始同步销售出库 ${fmtBJ(from)} → ${fmtBJ(to)}`,
    }).select("id").single();
    if (logErr) throw logErr;

    // @ts-ignore EdgeRuntime
    EdgeRuntime.waitUntil(runSync(from.toISOString(), to.toISOString(), log.id));

    return new Response(JSON.stringify({
      ok: true, background: true, log_id: log.id,
      cursor_from: from.toISOString(), cursor_to: to.toISOString(),
      message: "同步已在后台启动",
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
