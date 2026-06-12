// Edge Function: 聚水潭商品资料增量同步（断点续跑 job 引擎）
// API: /open/sku/query 普通商品资料查询（按 SKU）。官方文档要点（2026-06-12 实查）：
//   modified_begin/modified_end 必须成对、单次窗口 ≤7 天；page_size 上限 100；
//   返回按时间升序 → processPage 上报 rebaseWindowFrom，页深恒浅；
//   行字段：sku_id=商品编码、i_id=款式编码、sku_code=国标码（勿混用）。
// 写入 ops_products（款）/ ops_skus（SKU）两层主档；缺失供应商按
// 「code = 聚水潭供应商内部编码」约定自动建档 ops_suppliers（不更新已有行）。
// 冲突（同 SKU 不同款号、人工维护供应商与 JST 不一致）写 ops_product_mapping_exceptions，
// 不静默覆盖；manual_fields 中列出的人工维护字段（含 lead_time_days）一律不写；不落 raw JSON。
//
// 鉴权：x-cron-secret = JST_SYNC_CRON_SECRET / x-internal-tick = SERVICE_ROLE / admin JWT。
// Actions:
//   start_products_job / tick_products_job / cancel_products_job  断点任务（minutes/hours/days 窗口）
//   sync_recent {days≤7}                旧版手动入口 → 转 start_products_job
//   sync_range {modified_begin, modified_end}（北京时间字符串）→ 转 start_products_job
//   sync_by_style {style_no} / sync_by_sku {sku_code}  按款号/SKU 一次性补同步
//   sync_images {limit}                 图片转存（沿用旧逻辑，与 JST 增量无关）
//   test_minimal_sku / refresh_token    诊断辅助
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import {
  admin, callOpenweb, fmtBJ, parseJstBeijingDateTime, computeHasNext, pickList,
  resolveCaller, resolveWindow, sleep, RATE_DELAY_MS, MAX_PAGE_NO, forceRefreshAccessToken,
} from "../_shared/jst-client.ts";
import { handleJobActions, PageResult, ProcessPageArgs } from "../_shared/jst-sync-job.ts";

const SYNC_TYPE = "jst_products";
const METHOD_PATH = "sku/query";
const PAGE_SIZE = 100; // /open/sku/query 文档上限 100
const MAX_JOB_RANGE_DAYS = 31; // 严禁全量重型同步：单个任务时间范围硬上限
const EXCEPTION_SOURCE = "jst_sku_query";
const BUCKET = "product-images";

// ---------- 解析 ----------
type ParsedSku = {
  skuId: string;               // 商品编码 → ops_skus.sku_code / jst_sku_id
  iId: string | null;          // 款式编码 → ops_products.code / style_no
  name: string | null;
  propertiesValue: string | null;
  color: string | null;
  size: string | null;
  supplierJstId: string | null; // 供应商内部编码（文本）
  supplierName: string | null;
  costPrice: number | null;
  enabled: number | null;       // 1 启用 / 0 备用 / -1 禁用
  modifiedIso: string | null;
};

// properties_value 通常类似 "颜色:红色;尺码:120"、"红色;120" 或
// "军绿工装【短裤】;130码 (身高125-135cm)"（与 ops-product-master-derive 启发式同源，
// 另支持 "130码"/"M码" 这类带「码」后缀的尺码）
function pickSpec(spec: string | null): { color: string | null; size: string | null } {
  if (!spec) return { color: null, size: null };
  const parts = spec.split(/[;,\s]+/).filter(Boolean);
  const r = { color: null as string | null, size: null as string | null };
  for (const p of parts) {
    const m = p.match(/^(.+?)[:：](.+)$/);
    const v = m ? m[2].trim() : p.trim();
    if (!v) continue;
    // "130码(身高125-135cm)" 这类「码」后直接跟说明、无空格 → 不锚定结尾；纯尺码 token 才锚定
    const sizeMatch = v.match(/^(\d{2,3}|XS|S|M|L|XL|XXL|XXXL|2XL|3XL)[码碼]/i)
      ?? v.match(/^(\d{2,3}[A-Za-z]?|XS|S|M|L|XL|XXL|XXXL|2XL|3XL)$/i);
    if (sizeMatch) {
      if (!r.size) r.size = sizeMatch[1];
    } else if (!r.color) {
      r.color = v;
    }
  }
  return r;
}

function parseRec(raw: any): ParsedSku | null {
  const skuId = String(raw?.sku_id ?? "").trim();
  if (!skuId) return null;
  const iId = String(raw?.i_id ?? "").trim() || null;
  const name = String(raw?.name ?? "").trim() || null;
  const propertiesValue = String(raw?.properties_value ?? "").trim() || null;
  const spec = pickSpec(propertiesValue);
  const color = (String(raw?.color ?? "").trim() || spec.color) ?? null;
  let supplierJstId = String(raw?.supplier_id ?? "").trim();
  if (supplierJstId === "0") supplierJstId = ""; // 文档示例：supplier_id="0" 表示未设供应商
  const supplierName = String(raw?.supplier_name ?? "").trim() || null;
  const cost = raw?.cost_price;
  const costPrice = cost == null || cost === "" || Number.isNaN(Number(cost)) ? null : Number(cost);
  const enabled = raw?.enabled == null ? null : Number(raw.enabled);
  // 文档响应示例的 modified 形如 "2021-06-0916:28:12"（疑似排版丢空格），容错补回
  let modifiedStr = String(raw?.modified ?? "").trim();
  const m = modifiedStr.match(/^(\d{4}-\d{1,2}-\d{1,2})(\d{1,2}:\d{1,2}:\d{1,2})$/);
  if (m) modifiedStr = `${m[1]} ${m[2]}`;
  return {
    skuId, iId, name, propertiesValue, color, size: spec.size,
    supplierJstId: supplierJstId || null, supplierName, costPrice, enabled,
    modifiedIso: parseJstBeijingDateTime(modifiedStr),
  };
}

// ---------- 写库 ----------
type ExceptionRec = { jstSkuId: string; reason: string; data: Record<string, unknown> };

type WriteStats = {
  skusInserted: number; skusUpdated: number; skusUnchanged: number;
  productsInserted: number; productsUpdated: number;
  suppliersCreated: number; relinked: number;
  exceptionsRecorded: number; failed: number; lastError: string;
};

const IN_CHUNK = 200;
async function selectIn(table: string, cols: string, col: string, values: string[]): Promise<any[]> {
  const out: any[] = [];
  for (let i = 0; i < values.length; i += IN_CHUNK) {
    const { data, error } = await admin.from(table).select(cols).in(col, values.slice(i, i + IN_CHUNK));
    if (error) throw new Error(`${table} preload by ${col}: ${error.message}`);
    out.push(...(data ?? []));
  }
  return out;
}

// 供应商解析：jst_supplier_id → code（历史导入约定 code 即聚水潭内部编码）→ 自动建档。
// 已有行一律不更新，保护人工维护的名称/标注。
async function ensureSuppliers(recs: ParsedSku[]): Promise<{ byJstId: Map<string, string>; created: number }> {
  const byJstId = new Map<string, string>();
  let created = 0;
  const wanted = new Map<string, string | null>();
  for (const r of recs) {
    if (r.supplierJstId) wanted.set(r.supplierJstId, r.supplierName ?? wanted.get(r.supplierJstId) ?? null);
  }
  if (wanted.size === 0) return { byJstId, created };
  const ids = Array.from(wanted.keys());
  for (const row of await selectIn("ops_suppliers", "id, jst_supplier_id", "jst_supplier_id", ids)) {
    if (row.jst_supplier_id) byJstId.set(row.jst_supplier_id, row.id);
  }
  const byCodeMiss = ids.filter((i) => !byJstId.has(i));
  for (const row of await selectIn("ops_suppliers", "id, code", "code", byCodeMiss)) {
    if (row.code && !byJstId.has(row.code)) byJstId.set(row.code, row.id);
  }
  for (const jstId of ids.filter((i) => !byJstId.has(i))) {
    const { data, error } = await admin.from("ops_suppliers")
      .insert({
        code: jstId,
        name: wanted.get(jstId) || jstId,
        jst_supplier_id: jstId,
        last_synced_at: new Date().toISOString(),
      })
      .select("id").single();
    if (!error && data) { byJstId.set(jstId, data.id as string); created++; continue; }
    // 并发或历史脏数据撞唯一键：回查
    const { data: again } = await admin.from("ops_suppliers").select("id")
      .or(`jst_supplier_id.eq.${jstId},code.eq.${jstId}`).limit(1).maybeSingle();
    if (again?.id) byJstId.set(jstId, again.id as string);
    else console.error(`[jst-products] 供应商建档失败 jst_supplier_id=${jstId}: ${error?.message}`);
  }
  return { byJstId, created };
}

type ProductCtx = {
  idByCode: Map<string, string>;
  codeById: Map<string, string>;
  inserted: number; updated: number;
  exceptions: ExceptionRec[];
  lastError: string; failed: number;
};

const PRODUCT_COLS = "id, code, name, product_name, style_no, jst_product_id, supplier_id, supplier_name_snapshot, cost_price, manual_fields, jst_modified_at";

// 款级 find-or-create + 增量更新（code = i_id，与 ops-product-master-derive 约定一致）
async function ensureProducts(recs: ParsedSku[], supplierByJst: Map<string, string>): Promise<ProductCtx> {
  const ctx: ProductCtx = { idByCode: new Map(), codeById: new Map(), inserted: 0, updated: 0, exceptions: [], lastError: "", failed: 0 };
  const nowIso = new Date().toISOString();
  // recs 已按 modified 升序去重，rep 取同款最后一条（最新）
  const groups = new Map<string, { rep: ParsedSku; maxModified: string | null }>();
  for (const r of recs) {
    const code = r.iId || r.skuId;
    const g = groups.get(code);
    if (!g) groups.set(code, { rep: r, maxModified: r.modifiedIso });
    else {
      g.rep = r;
      if (r.modifiedIso && (!g.maxModified || r.modifiedIso > g.maxModified)) g.maxModified = r.modifiedIso;
    }
  }
  const codes = Array.from(groups.keys());
  const byCode = new Map<string, any>();
  const byJstPid = new Map<string, any>();
  for (const row of await selectIn("ops_products", PRODUCT_COLS, "code", codes)) byCode.set(row.code, row);
  for (const row of await selectIn("ops_products", PRODUCT_COLS, "jst_product_id", codes)) byJstPid.set(row.jst_product_id, row);

  for (const [code, g] of groups) {
    const rep = g.rep;
    const ex = byJstPid.get(code) ?? byCode.get(code);
    const supplierUuid = rep.supplierJstId ? supplierByJst.get(rep.supplierJstId) ?? null : null;
    if (!ex) {
      const { data, error } = await admin.from("ops_products").insert({
        code,
        name: rep.name ?? code,
        product_name: rep.name,
        style_no: rep.iId,
        jst_product_id: rep.iId,
        supplier_id: supplierUuid,
        supplier_name_snapshot: rep.supplierName,
        cost_price: rep.costPrice,
        is_active: true,
        jst_modified_at: g.maxModified,
        last_synced_at: nowIso,
      }).select("id").single();
      if (!error && data) {
        ctx.inserted++;
        ctx.idByCode.set(code, data.id as string);
        ctx.codeById.set(data.id as string, code);
        continue;
      }
      // 并发撞唯一键：回查，本轮不再补丁（下个窗口/重跑会收敛）
      const { data: again } = await admin.from("ops_products").select("id, code").eq("code", code).maybeSingle();
      if (again?.id) {
        ctx.idByCode.set(code, again.id as string);
        ctx.codeById.set(again.id as string, code);
      } else {
        ctx.failed++;
        ctx.lastError = `款 ${code} 建档失败: ${error?.message}`;
        console.error(`[jst-products] ${ctx.lastError}`);
      }
      continue;
    }

    ctx.idByCode.set(code, ex.id as string);
    ctx.codeById.set(ex.id as string, ex.code as string);
    const manual = new Set<string>((ex.manual_fields as string[]) ?? []);
    const patch: Record<string, unknown> = {};
    if (rep.name && !manual.has("name") && rep.name !== ex.name) patch.name = rep.name;
    if (rep.name && !manual.has("product_name") && rep.name !== ex.product_name) patch.product_name = rep.name;
    if (rep.iId && !manual.has("style_no") && ex.style_no !== rep.iId) patch.style_no = rep.iId;
    if (rep.iId && !ex.jst_product_id) patch.jst_product_id = rep.iId;
    if (supplierUuid) {
      if (manual.has("supplier_id")) {
        if (ex.supplier_id !== supplierUuid) {
          ctx.exceptions.push({
            jstSkuId: rep.skuId,
            reason: `款 ${code} 供应商为人工维护，与聚水潭不一致（JST=${rep.supplierName ?? rep.supplierJstId}），未覆盖`,
            data: { level: "product", product_code: code, ops_supplier_id: ex.supplier_id, jst_supplier_id: rep.supplierJstId, jst_supplier_name: rep.supplierName },
          });
        }
      } else if (ex.supplier_id !== supplierUuid) {
        patch.supplier_id = supplierUuid;
        if (!manual.has("supplier_name_snapshot")) patch.supplier_name_snapshot = rep.supplierName;
      } else if (rep.supplierName && !manual.has("supplier_name_snapshot") && ex.supplier_name_snapshot !== rep.supplierName) {
        patch.supplier_name_snapshot = rep.supplierName;
      }
    }
    if (rep.costPrice != null && !manual.has("cost_price") && Number(ex.cost_price ?? NaN) !== rep.costPrice) {
      patch.cost_price = rep.costPrice;
    }
    if (g.maxModified && (!ex.jst_modified_at || Date.parse(g.maxModified) > Date.parse(ex.jst_modified_at))) {
      patch.jst_modified_at = g.maxModified;
    }
    if (Object.keys(patch).length === 0) continue;
    patch.last_synced_at = nowIso;
    const { error } = await admin.from("ops_products").update(patch).eq("id", ex.id);
    if (error) {
      ctx.failed++;
      ctx.lastError = `款 ${code} 更新失败: ${error.message}`;
      console.error(`[jst-products] ${ctx.lastError}`);
    } else ctx.updated++;
  }
  return ctx;
}

const SKU_COLS = "id, sku_code, jst_sku_id, product_id, sku_name, product_name, style_no, color, size, spec, spec_name, supplier_id, cost_price, is_active, manual_fields, jst_modified_at, source";

async function writeRecs(recsIn: ParsedSku[]): Promise<WriteStats> {
  const stats: WriteStats = {
    skusInserted: 0, skusUpdated: 0, skusUnchanged: 0,
    productsInserted: 0, productsUpdated: 0,
    suppliersCreated: 0, relinked: 0,
    exceptionsRecorded: 0, failed: 0, lastError: "",
  };
  // 同页同 SKU 去重（结果按时间升序，后者为最新）
  const dedup = new Map<string, ParsedSku>();
  for (const r of recsIn) dedup.set(r.skuId, r);
  const recs = Array.from(dedup.values());
  if (recs.length === 0) return stats;
  const nowIso = new Date().toISOString();

  const sup = await ensureSuppliers(recs);
  stats.suppliersCreated = sup.created;
  const prod = await ensureProducts(recs, sup.byJstId);
  stats.productsInserted = prod.inserted;
  stats.productsUpdated = prod.updated;
  stats.failed += prod.failed;
  if (prod.lastError) stats.lastError = prod.lastError;
  const exceptions: ExceptionRec[] = [...prod.exceptions];

  const skuIds = recs.map((r) => r.skuId);
  const existingBySku = new Map<string, any>();
  const existingByJst = new Map<string, any>();
  for (const row of await selectIn("ops_skus", SKU_COLS, "sku_code", skuIds)) existingBySku.set(row.sku_code, row);
  for (const row of await selectIn("ops_skus", SKU_COLS, "jst_sku_id", skuIds)) existingByJst.set(row.jst_sku_id, row);
  // 已存在 SKU 所挂款的 code（用于款号冲突判定）
  const missingPids = Array.from(new Set(
    [...existingBySku.values(), ...existingByJst.values()]
      .map((r) => r.product_id as string)
      .filter((pid) => pid && !prod.codeById.has(pid)),
  ));
  for (const row of await selectIn("ops_products", "id, code", "id", missingPids)) {
    prod.codeById.set(row.id, row.code);
  }

  for (const r of recs) {
    const targetCode = r.iId || r.skuId;
    const targetPid = prod.idByCode.get(targetCode) ?? null;
    const supplierUuid = r.supplierJstId ? sup.byJstId.get(r.supplierJstId) ?? null : null;
    const ex = existingBySku.get(r.skuId) ?? existingByJst.get(r.skuId);

    if (!ex) {
      if (!targetPid) { stats.failed++; stats.lastError = `SKU ${r.skuId} 跳过：款 ${targetCode} 建档失败`; continue; }
      const { error } = await admin.from("ops_skus").insert({
        product_id: targetPid,
        sku_code: r.skuId,
        jst_sku_id: r.skuId,
        sku_name: r.name,
        product_name: r.name,
        style_no: r.iId,
        color: r.color,
        size: r.size,
        spec: r.propertiesValue,
        spec_name: r.propertiesValue,
        supplier_id: supplierUuid,
        cost_price: r.costPrice,
        is_active: r.enabled == null ? true : r.enabled !== -1,
        source: "jst",
        jst_modified_at: r.modifiedIso,
        last_synced_at: nowIso,
      });
      if (error) {
        stats.failed++;
        stats.lastError = `SKU ${r.skuId} 插入失败: ${error.message}`;
        console.error(`[jst-products] ${stats.lastError}`);
      } else stats.skusInserted++;
      continue;
    }

    // modified 未前移则整行跳过（幂等重跑零写入）
    if (ex.jst_modified_at && r.modifiedIso && Date.parse(ex.jst_modified_at) >= Date.parse(r.modifiedIso)) {
      stats.skusUnchanged++;
      continue;
    }
    const manual = new Set<string>((ex.manual_fields as string[]) ?? []);
    const patch: Record<string, unknown> = {};

    // 款号归属：现有款 code 与聚水潭 i_id 不一致 → 仅当现有款是「per-SKU 占位款」
    // （code == sku_code，derive 兜底产物）时才改挂，否则记异常、不改动
    const exPid = ex.product_id as string | null;
    const exCode = exPid ? prod.codeById.get(exPid) ?? null : null;
    if (targetPid && exPid !== targetPid) {
      if (manual.has("product_id")) {
        if (exCode !== targetCode) {
          exceptions.push({
            jstSkuId: r.skuId,
            reason: `SKU 款号归属为人工维护，与聚水潭不一致（主档款号=${exCode ?? "-"}，聚水潭款号=${targetCode}），未覆盖`,
            data: { level: "sku", ops_product_code: exCode, jst_i_id: targetCode, modified: r.modifiedIso },
          });
        }
      } else if (!exCode || exCode === ex.sku_code) {
        patch.product_id = targetPid;
        stats.relinked++;
      } else if (exCode !== targetCode) {
        exceptions.push({
          jstSkuId: r.skuId,
          reason: `同一SKU款号冲突：主档款号=${exCode}，聚水潭款号=${targetCode}，未改动归属`,
          data: { level: "sku", ops_product_code: exCode, jst_i_id: targetCode, modified: r.modifiedIso },
        });
      }
      // exCode === targetCode 而 id 不同：code 与 jst_product_id 指向了两行，数据歧义，留待人工
    }

    const setIf = (field: string, val: unknown) => {
      if (val != null && !manual.has(field) && val !== ex[field]) patch[field] = val;
    };
    setIf("sku_name", r.name);
    setIf("product_name", r.name);
    setIf("style_no", r.iId);
    setIf("color", r.color);
    setIf("size", r.size);
    setIf("spec", r.propertiesValue);
    setIf("spec_name", r.propertiesValue);
    if (!ex.jst_sku_id) patch.jst_sku_id = r.skuId;
    // derive 兜底产生的 JST-xxx 占位编码：拿到真实商品编码后回填（与 derive 同一约定）
    if (ex.sku_code !== r.skuId && (!ex.sku_code || /^JST-/.test(ex.sku_code)) && !manual.has("sku_code")) {
      patch.sku_code = r.skuId;
    }
    if (r.costPrice != null && !manual.has("cost_price") && Number(ex.cost_price ?? NaN) !== r.costPrice) {
      patch.cost_price = r.costPrice;
    }
    if (r.enabled != null && !manual.has("is_active")) {
      const active = r.enabled !== -1; // 0 备用视为在用，仅 -1 禁用置否
      if (ex.is_active !== active) patch.is_active = active;
    }
    if (supplierUuid) {
      if (manual.has("supplier_id")) {
        if (ex.supplier_id !== supplierUuid) {
          exceptions.push({
            jstSkuId: r.skuId,
            reason: `SKU 供应商为人工维护，与聚水潭不一致（JST=${r.supplierName ?? r.supplierJstId}），未覆盖`,
            data: { level: "sku", ops_supplier_id: ex.supplier_id, jst_supplier_id: r.supplierJstId, jst_supplier_name: r.supplierName },
          });
        }
      } else if (ex.supplier_id !== supplierUuid) {
        patch.supplier_id = supplierUuid;
      }
    }
    const srcSet = new Set(String(ex.source ?? "").split(",").map((s: string) => s.trim()).filter(Boolean));
    if (!srcSet.has("jst")) { srcSet.add("jst"); patch.source = Array.from(srcSet).join(","); }
    if (r.modifiedIso && (!ex.jst_modified_at || Date.parse(r.modifiedIso) > Date.parse(ex.jst_modified_at))) {
      patch.jst_modified_at = r.modifiedIso;
    }
    if (Object.keys(patch).length === 0) { stats.skusUnchanged++; continue; }
    patch.last_synced_at = nowIso;
    const { error } = await admin.from("ops_skus").update(patch).eq("id", ex.id);
    if (error) {
      stats.failed++;
      stats.lastError = `SKU ${r.skuId} 更新失败: ${error.message}`;
      console.error(`[jst-products] ${stats.lastError}`);
    } else stats.skusUpdated++;
  }

  stats.exceptionsRecorded = await recordExceptions(exceptions);
  return stats;
}

// 异常落表：pending 期内同一 jst_sku_id 只留一条（与部分唯一索引口径一致），重复同步不翻倍
async function recordExceptions(list: ExceptionRec[]): Promise<number> {
  let recorded = 0;
  for (const e of list) {
    const { data: dup } = await admin.from("ops_product_mapping_exceptions")
      .select("id")
      .eq("jst_sku_id", e.jstSkuId).eq("status", "pending").eq("source_table", EXCEPTION_SOURCE)
      .limit(1).maybeSingle();
    if (dup?.id) continue;
    const { error } = await admin.from("ops_product_mapping_exceptions").insert({
      platform: "jst",
      jst_sku_id: e.jstSkuId,
      source_table: EXCEPTION_SOURCE,
      reason: e.reason,
      status: "pending",
      raw_data: e.data,
    });
    if (!error) recorded++;
    else if (!/duplicate key/i.test(error.message)) {
      console.error(`[jst-products] 异常落表失败 sku=${e.jstSkuId}: ${error.message}`);
    }
  }
  return recorded;
}

// ---------- job processPage ----------
async function processProductsPage(args: ProcessPageArgs): Promise<PageResult> {
  const { windowFrom, windowTo, pageIndex, pageSize } = args;
  if (pageIndex > MAX_PAGE_NO) throw new Error(`分页超过上限 ${MAX_PAGE_NO}`);
  await sleep(RATE_DELAY_MS);
  const reqBody = {
    page_index: String(pageIndex),
    page_size: String(Math.min(Number(pageSize) || PAGE_SIZE, PAGE_SIZE)),
    modified_begin: fmtBJ(windowFrom),
    modified_end: fmtBJ(windowTo),
  };
  const t0 = Date.now();
  let data: any;
  try {
    data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
  } catch (e: any) {
    e.requestBody = reqBody;
    e.apiPath = METHOD_PATH;
    e.durationMs = Date.now() - t0;
    e.responseCode = e.responseCode ?? (e.code != null ? String(e.code) : null);
    e.responseMsg = e.responseMsg ?? e.apiMsg ?? null;
    throw e;
  }
  const list = pickList(data, ["datas"]);
  const hasNext = computeHasNext(data, list.length, pageSize, pageIndex);
  const recs = list.map(parseRec).filter((x): x is ParsedSku => x !== null);
  const stats = await writeRecs(recs);
  let maxModified: string | null = null;
  for (const r of recs) {
    if (r.modifiedIso && (!maxModified || r.modifiedIso > maxModified)) maxModified = r.modifiedIso;
  }
  return {
    apiCount: list.length,
    mainUpserted: stats.skusInserted + stats.skusUpdated,
    itemUpserted: stats.productsInserted + stats.productsUpdated,
    failed: stats.failed,
    hasNext,
    errorDetail: stats.lastError || undefined,
    requestBody: reqBody,
    durationMs: Date.now() - t0,
    responseMsg: `unchanged=${stats.skusUnchanged} relinked=${stats.relinked} suppliers_created=${stats.suppliersCreated} exceptions=${stats.exceptionsRecorded}`,
    // 文档：结果按时间升序 → 上报本页最大 modified，引擎把窗口余段重定位、页码归 1
    rebaseWindowFrom: hasNext ? maxModified : null,
  };
}

// ---------- 一次性补同步（按款号 / 按 SKU，量小不走 job） ----------
async function runScopedSync(bizExtra: Record<string, unknown>, label: string, logId: string) {
  let page = 1, skus = 0, products = 0, unchanged = 0, failed = 0;
  try {
    while (page <= 10) {
      await sleep(RATE_DELAY_MS);
      const reqBody = { page_index: String(page), page_size: String(PAGE_SIZE), ...bizExtra };
      const data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
      const list = pickList(data, ["datas"]);
      const recs = list.map(parseRec).filter((x): x is ParsedSku => x !== null);
      const stats = await writeRecs(recs);
      skus += stats.skusInserted + stats.skusUpdated;
      products += stats.productsInserted + stats.productsUpdated;
      unchanged += stats.skusUnchanged;
      failed += stats.failed;
      await admin.from("jst_sync_logs").update({
        fetched_orders_count: skus, fetched_items_count: skus,
        heartbeat_at: new Date().toISOString(),
        message: `${label} 第 ${page} 页：SKU 写入 ${skus}（款 ${products}，未变更 ${unchanged}，失败 ${failed}）`,
      }).eq("id", logId);
      if (!computeHasNext(data, list.length, PAGE_SIZE, page) || list.length === 0) break;
      page++;
    }
    await admin.from("jst_sync_logs").update({
      status: failed === 0 ? "success" : (skus > 0 ? "partial_failed" : "failed"),
      ended_at: new Date().toISOString(),
      fetched_orders_count: skus, fetched_items_count: skus,
      message: `${label} 完成：SKU 写入 ${skus}，款 ${products}，未变更 ${unchanged}，失败 ${failed}`,
    }).eq("id", logId);
  } catch (e: any) {
    await admin.from("jst_sync_logs").update({
      status: "failed", ended_at: new Date().toISOString(),
      message: `${label} 失败`,
      error_detail: String(e?.message ?? e).slice(0, 1500),
    }).eq("id", logId);
  }
}

async function startScopedLog(label: string): Promise<string> {
  const { data, error } = await admin.from("jst_sync_logs").insert({
    sync_type: SYNC_TYPE, status: "running", message: label,
  }).select("id").single();
  if (error) throw error;
  return data!.id as string;
}

// ---------- 图片转存（沿用旧逻辑，与 JST 增量同步无关） ----------
async function transferOneImage(externalUrl: string, storagePath: string): Promise<string | null> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 10_000);
    const resp = await fetch(externalUrl, {
      signal: ctrl.signal,
      headers: { "User-Agent": "Mozilla/5.0", "Referer": "https://www.jushuitan.com/" },
    });
    clearTimeout(timer);
    if (!resp.ok) return null;
    const contentType = resp.headers.get("content-type") ?? "image/jpeg";
    const buf = new Uint8Array(await resp.arrayBuffer());
    const { error } = await admin.storage.from(BUCKET).upload(storagePath, buf, { contentType, upsert: true });
    if (error) {
      console.error("[jst-products] storage upload error", error.message);
      return null;
    }
    const { data } = admin.storage.from(BUCKET).getPublicUrl(storagePath);
    return data.publicUrl ?? null;
  } catch (e) {
    console.error("[jst-products] image fetch failed", externalUrl, (e as Error).message);
    return null;
  }
}

function safeSegment(s: string) {
  return (s || "unknown").replace(/[^\w.\-]+/g, "_").slice(0, 80);
}

async function syncImages(limit: number, logId: string) {
  let success = 0, failed = 0;
  const { data: skus } = await admin
    .from("ops_skus")
    .select("id, sku_code, external_image_url, sku_image_url, product_id")
    .not("external_image_url", "is", null)
    .is("sku_image_url", null)
    .limit(limit);
  for (const s of (skus ?? []) as any[]) {
    const { data: p } = await admin.from("ops_products").select("style_no, code").eq("id", s.product_id).maybeSingle();
    const styleSeg = safeSegment(p?.style_no || p?.code || "_");
    const path = `${styleSeg}/${safeSegment(s.sku_code)}.jpg`;
    const publicUrl = await transferOneImage(s.external_image_url, path);
    if (publicUrl) {
      await admin.from("ops_skus").update({ sku_image_url: publicUrl, image_storage_path: path }).eq("id", s.id);
      success++;
    } else failed++;
    await sleep(50);
  }
  const { data: products } = await admin
    .from("ops_products")
    .select("id, code, style_no, external_image_url, main_image_url")
    .not("external_image_url", "is", null)
    .is("main_image_url", null)
    .limit(limit);
  for (const p of (products ?? []) as any[]) {
    const styleSeg = safeSegment(p.style_no || p.code || "_");
    const path = `${styleSeg}/main.jpg`;
    const publicUrl = await transferOneImage(p.external_image_url, path);
    if (publicUrl) {
      await admin.from("ops_products").update({ main_image_url: publicUrl, image_storage_path: path }).eq("id", p.id);
      success++;
    } else failed++;
    await sleep(50);
  }
  await admin.from("jst_sync_logs").update({
    status: failed === 0 ? "success" : (success > 0 ? "partial_failed" : "failed"),
    ended_at: new Date().toISOString(),
    fetched_items_count: success,
    message: `图片转存成功=${success}, 失败=${failed}`,
  }).eq("id", logId);
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
    if (!okCron && !okInternal && !caller.isAdmin) {
      return json({ error: "Unauthorized" }, 401);
    }
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const action: string = body.action ?? "sync_recent";

    if (action === "test_minimal_sku") {
      const reqBody = {
        page_index: "1", page_size: "1",
        modified_begin: fmtBJ(new Date(Date.now() - 86400_000)),
        modified_end: fmtBJ(new Date()),
      };
      try {
        const data = await callOpenweb(METHOD_PATH, reqBody, { timeoutMs: 30_000 });
        const list = pickList(data, ["datas"]);
        await admin.from("jst_sync_logs").insert({
          sync_type: SYNC_TYPE, status: "success", ended_at: new Date().toISOString(),
          message: `[test_minimal_sku] /open/${METHOD_PATH} data_count=${list.length} keys=${list[0] ? Object.keys(list[0]).slice(0, 30).join(",") : "-"}`,
        });
        return json({ ok: true, data_count: list.length, path: `/open/${METHOD_PATH}` });
      } catch (e: any) {
        await admin.from("jst_sync_logs").insert({
          sync_type: SYNC_TYPE, status: "failed", ended_at: new Date().toISOString(),
          message: `[test_minimal_sku] 失败 code=${e?.code ?? ""}`,
          error_detail: String(e?.message ?? e).slice(0, 1000),
        });
        return json({ ok: false, code: e?.code ?? null, error: String(e?.message ?? e).slice(0, 500) });
      }
    }

    if (action === "refresh_token") {
      await forceRefreshAccessToken();
      await admin.from("jst_sync_logs").insert({
        sync_type: SYNC_TYPE, status: "success", ended_at: new Date().toISOString(),
        message: "[refresh_token] access_token 已刷新",
      });
      return json({ ok: true });
    }

    if (action === "sync_images") {
      const limit = Math.min(200, Math.max(1, Number(body.limit ?? 50)));
      const logId = await startScopedLog(`[图片转存] limit=${limit}`);
      // @ts-ignore EdgeRuntime available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(syncImages(limit, logId));
      return json({ ok: true, background: true, log_id: logId });
    }

    if (action === "sync_by_style" || action === "sync_by_sku") {
      let bizExtra: Record<string, unknown>;
      let label: string;
      if (action === "sync_by_style") {
        const styleNo = String(body.style_no ?? "").trim();
        if (!styleNo) throw new Error("缺少 style_no");
        bizExtra = { i_ids: [styleNo] };
        label = `[按款号补同步] ${styleNo}`;
      } else {
        const skuCodes = String(body.sku_code ?? "").split(/[,，\s]+/).map((s) => s.trim()).filter(Boolean);
        if (skuCodes.length === 0) throw new Error("缺少 sku_code");
        if (skuCodes.length > 20) throw new Error("sku_ids 单次最多 20 个");
        bizExtra = { sku_ids: skuCodes.join(",") };
        label = `[按SKU补同步] ${skuCodes.join(",")}`;
      }
      const logId = await startScopedLog(label);
      // @ts-ignore EdgeRuntime available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runScopedSync(bizExtra, label, logId));
      return json({ ok: true, background: true, log_id: logId, action });
    }

    // 旧入口 → 断点任务
    let jobAction = action;
    let jobBody: any = body;
    if (action === "sync_recent") {
      jobAction = "start_products_job";
      jobBody = { ...body, days: Math.min(7, Math.max(1, Number(body.days ?? 1))) };
    } else if (action === "sync_range") {
      const fromIso = parseJstBeijingDateTime(body.modified_begin);
      const toIso = parseJstBeijingDateTime(body.modified_end);
      if (!fromIso || !toIso) throw new Error("缺少/非法 modified_begin / modified_end");
      jobAction = "start_products_job";
      jobBody = { ...body, start_time: fromIso, end_time: toIso };
    }

    const jobResp = await handleJobActions({
      action: jobAction, body: jobBody, syncType: SYNC_TYPE, callerUid: caller.uid,
      processPage: processProductsPage,
      startActionName: "start_products_job",
      tickActionName: "tick_products_job",
      cancelActionName: "cancel_products_job",
      functionName: "jst-sync-products",
      config: { pageSize: PAGE_SIZE, maxWindowDays: 1, maxPagesPerRun: 3, timeBudgetSeconds: 40 },
      resolveWindowFromBody: (b) => {
        const { from, to } = resolveWindow(b);
        if (to.getTime() - from.getTime() > MAX_JOB_RANGE_DAYS * 86400_000) {
          throw new Error(`商品同步窗口最大 ${MAX_JOB_RANGE_DAYS} 天，严禁全量重型同步；请缩小时间范围`);
        }
        return { from, to };
      },
    });
    if (jobResp) {
      const text = await jobResp.text();
      return new Response(text, { status: jobResp.status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    throw new Error(`未知 action: ${action}（全量同步已禁用，请用 start_products_job 按时间窗口增量同步）`);
  } catch (err) {
    return json({ ok: false, error: (err as Error).message }, 500);
  }
});
