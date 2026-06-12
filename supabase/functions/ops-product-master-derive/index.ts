// Edge Function: 从已有业务数据(订单/出库/退款/销退仓)自动沉淀商品主档
// 不调用聚水潭外部 API；只读项目内已同步的 JST 数据表，upsert 到 ops_skus 主档。
// 同步线上商品映射到 ops_sku_aliases；遇到无法匹配的线上 SKU 写 ops_product_mapping_exceptions。
//
// POST body:
//   { source?: 'sales'|'outbound'|'refund'|'aftersale'|'all',  // 默认 all
//     days?: number,                                            // 仅取最近 N 天，默认 30
//     limit?: number }                                          // 每来源最多扫描 N 行，默认 20000

import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";
import { resolveCaller } from "../_shared/jst-client.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

type DeriveRow = {
  sku_code: string | null;
  jst_sku_id: string | null;
  style_no: string | null;
  product_name: string | null;
  sku_name: string | null;
  color: string | null;
  size: string | null;
  pic: string | null;
  cost_price: number | null;
  supplier_id: string | null;
  supplier_name: string | null;
  shop_id: string | null;
  online_sku_code: string | null;
  online_product_id: string | null;
  ts: string | null;
  source: string;
};

function pickSpec(spec: string | null): { color: string | null; size: string | null } {
  if (!spec) return { color: null, size: null };
  // properties_value 通常类似 "颜色:红色;尺码:120" 或 "红色;120"
  const parts = spec.split(/[;,\s]+/).filter(Boolean);
  const r = { color: null as string | null, size: null as string | null };
  for (const p of parts) {
    const m = p.match(/^(.+?)[:：](.+)$/);
    const v = m ? m[2].trim() : p.trim();
    if (!v) continue;
    if (/^\d{2,3}[A-Za-z]?$/.test(v) || /^(XS|S|M|L|XL|XXL|XXXL)$/i.test(v)) {
      if (!r.size) r.size = v;
    } else if (!r.color) {
      r.color = v;
    }
  }
  return r;
}

function deriveStyleNo(skuCode: string | null): string | null {
  if (!skuCode) return null;
  // 内部约定：款号通常是 sku_code 去掉颜色/尺码后缀；取首个 '-' 或 '_' 前段
  const idx = skuCode.search(/[-_]/);
  if (idx > 0) return skuCode.slice(0, idx);
  return skuCode;
}

// PostgREST 服务端 max-rows=1000:单次 .limit(N>1000) 只会返回 1000 行,
// 必须用 .range() 分页循环才能真正扫满 limit。order by id 保证分页窗口稳定。
const PAGE_SIZE = 1000;
async function fetchPaged(
  label: string,
  limit: number,
  query: (from: number, to: number) => PromiseLike<{ data: any[] | null; error: { message: string } | null }>,
): Promise<any[]> {
  const out: any[] = [];
  while (out.length < limit) {
    const from = out.length;
    const to = Math.min(from + PAGE_SIZE, limit) - 1;
    const { data, error } = await query(from, to);
    if (error) throw new Error(`${label}: ${error.message}`);
    const batch = data ?? [];
    out.push(...batch);
    if (batch.length < to - from + 1) break;
  }
  return out;
}

async function loadRows(source: string, days: number, limit: number): Promise<DeriveRow[]> {
  const since = new Date(Date.now() - days * 86400_000).toISOString();
  const out: DeriveRow[] = [];

  if (source === "sales" || source === "all") {
    const data = await fetchPaged("sales", limit, (from, to) => admin
      .from("jst_sales_order_items")
      .select("sku_code, sku_id, shop_sku_id, product_name, sku_name, pic, supplier_id, supplier_name, shop_id, jst_item_id, synced_at")
      .gte("synced_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data) {
      out.push({
        sku_code: r.sku_code ?? null,
        jst_sku_id: r.sku_id ?? null,
        product_name: r.product_name ?? null,
        sku_name: r.sku_name ?? null,
        color: null, size: null,
        pic: r.pic ?? null,
        supplier_id: r.supplier_id ?? null,
        supplier_name: r.supplier_name ?? null,
        shop_id: r.shop_id != null ? String(r.shop_id) : null,
        online_sku_code: r.shop_sku_id ?? null,
        online_product_id: r.jst_item_id ?? null,
        ts: r.synced_at ?? null,
        style_no: null,
        cost_price: null,
        source: "sales",
      });
    }
  }

  if (source === "outbound" || source === "all") {
    const data = await fetchPaged("outbound", limit, (from, to) => admin
      .from("jst_outbound_order_items")
      .select("sku_id, i_id, name, properties_value, color, size, pic, synced_at")
      .gte("synced_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data) {
      const spec = pickSpec(r.properties_value);
      out.push({
        sku_code: null,
        jst_sku_id: r.sku_id ?? null,
        product_name: r.name ?? null,
        sku_name: null,
        color: r.color ?? spec.color,
        size: r.size ?? spec.size,
        pic: r.pic ?? null,
        supplier_id: null, supplier_name: null,
        shop_id: null,
        online_sku_code: null,
        online_product_id: r.i_id ?? null,
        ts: r.synced_at ?? null,
        style_no: null,
        cost_price: null,
        source: "outbound",
      });
    }
  }

  if (source === "refund" || source === "all") {
    const data = await fetchPaged("refund", limit, (from, to) => admin
      .from("jst_refund_order_items")
      .select("sku_id, name, properties_value, pic, supplier_id, supplier_name, synced_at")
      .gte("synced_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data) {
      const spec = pickSpec(r.properties_value);
      out.push({
        sku_code: null,
        jst_sku_id: r.sku_id ?? null,
        product_name: r.name ?? null,
        sku_name: null,
        color: spec.color, size: spec.size,
        pic: r.pic ?? null,
        supplier_id: r.supplier_id ?? null,
        supplier_name: r.supplier_name ?? null,
        shop_id: null, online_sku_code: null, online_product_id: null,
        ts: r.synced_at ?? null,
        style_no: null,
        cost_price: null,
        source: "refund",
      });
    }
  }

  if (source === "aftersale" || source === "all") {
    const data = await fetchPaged("aftersale", limit, (from, to) => admin
      .from("jst_aftersale_received_items")
      .select("sku_id, name, properties_value, pic, supplier_id, supplier_name, synced_at")
      .gte("synced_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data) {
      const spec = pickSpec(r.properties_value);
      out.push({
        sku_code: null,
        jst_sku_id: r.sku_id ?? null,
        product_name: r.name ?? null,
        sku_name: null,
        color: spec.color, size: spec.size,
        pic: r.pic ?? null,
        supplier_id: r.supplier_id ?? null,
        supplier_name: r.supplier_name ?? null,
        shop_id: null, online_sku_code: null, online_product_id: null,
        ts: r.synced_at ?? null,
        style_no: null,
        cost_price: null,
        source: "aftersale",
      });
    }
  }

  if (source === "purchase" || source === "all") {
    const data = await fetchPaged("purchase", limit, (from, to) => admin
      .from("purchase_order_items")
      .select("sku_no, sku_id, style_no, product_name, color, size, properties_value, product_image_url, unit_price, updated_at, purchase_order:purchase_orders!inner(supplier_id, supplier_name, po_date)")
      .gte("updated_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data as any[]) {
      const spec = pickSpec(r.properties_value);
      const po = r.purchase_order ?? {};
      out.push({
        sku_code: r.sku_no ?? null,
        // purchase_order_items.sku_id 是内部 ops_skus 的 uuid(relink 回填),不是 JST 编号
        jst_sku_id: null,
        style_no: r.style_no ?? null,
        product_name: r.product_name ?? null,
        sku_name: null,
        color: r.color ?? spec.color,
        size: r.size ?? spec.size,
        pic: r.product_image_url ?? null,
        cost_price: r.unit_price ?? null,
        supplier_id: po.supplier_id ?? null,
        supplier_name: po.supplier_name ?? null,
        shop_id: null, online_sku_code: null, online_product_id: null,
        ts: po.po_date ?? r.updated_at ?? null,
        source: "purchase",
      });
    }
  }

  if (source === "receipt" || source === "all") {
    const data = await fetchPaged("receipt", limit, (from, to) => admin
      .from("purchase_receipt_items")
      .select("sku_no, sku_id, product_name, cost_price, updated_at, receipt:purchase_receipts!inner(supplier_name, io_date)")
      .gte("updated_at", since)
      .order("id", { ascending: true })
      .range(from, to));
    for (const r of data as any[]) {
      const rc = r.receipt ?? {};
      out.push({
        sku_code: r.sku_no ?? null,
        // purchase_receipt_items.sku_id 同为内部 uuid,不是 JST 编号
        jst_sku_id: null,
        style_no: null,
        product_name: r.product_name ?? null,
        sku_name: null,
        color: null, size: null,
        pic: null,
        cost_price: r.cost_price ?? null,
        supplier_id: null,
        supplier_name: rc.supplier_name ?? null,
        shop_id: null, online_sku_code: null, online_product_id: null,
        ts: rc.io_date ?? r.updated_at ?? null,
        source: "receipt",
      });
    }
  }

  return out;
}

type Agg = {
  sku_code: string | null;
  jst_sku_id: string | null;
  product_name: string | null;
  color: string | null;
  size: string | null;
  pic: string | null;
  cost_price: number | null;
  supplier_id: string | null;
  supplier_name: string | null;
  style_no: string | null;
  sources: Set<string>;
  first: string | null;
  last: string | null;
  aliases: Map<string, { shop_id: string; online_sku_code: string | null; online_product_id: string | null; product_name: string | null; ts: string | null }>;
};

function aggregate(rows: DeriveRow[]): { masters: Agg[]; orphanAliases: DeriveRow[] } {
  const byKey = new Map<string, Agg>();
  const orphans: DeriveRow[] = [];

  // 第一步：建立 sku_code <-> jst_sku_id 映射，避免同一 SKU 因不同来源生成两条主档
  const skuToJst = new Map<string, string>();
  const jstToSku = new Map<string, string>();
  for (const r of rows) {
    if (r.sku_code && r.jst_sku_id) {
      if (!skuToJst.has(r.sku_code)) skuToJst.set(r.sku_code, r.jst_sku_id);
      if (!jstToSku.has(r.jst_sku_id)) jstToSku.set(r.jst_sku_id, r.sku_code);
    }
  }

  const keyOf = (r: DeriveRow): string | null => {
    // 优先按 sku_code 聚合；sku_code 为空时按 jst_sku_id 聚合
    // 若 jst_sku_id 已知对应某个 sku_code，则归并到该 sku_code
    if (r.sku_code) return `sku:${r.sku_code}`;
    if (r.jst_sku_id) {
      const mapped = jstToSku.get(r.jst_sku_id);
      if (mapped) return `sku:${mapped}`;
      return `jst:${r.jst_sku_id}`;
    }
    return null;
  };

  for (const r of rows) {
    const key = keyOf(r);
    if (!key) {
      if (r.shop_id && r.online_sku_code) orphans.push(r);
      continue;
    }
    let a = byKey.get(key);
    if (!a) {
      const sc = r.sku_code ?? (r.jst_sku_id ? jstToSku.get(r.jst_sku_id) ?? null : null);
      const js = r.jst_sku_id ?? (r.sku_code ? skuToJst.get(r.sku_code) ?? null : null);
      a = {
        sku_code: sc, jst_sku_id: js,
        product_name: null, color: null, size: null, pic: null,
        cost_price: null,
        supplier_id: null, supplier_name: null,
        style_no: r.style_no ?? deriveStyleNo(sc),
        sources: new Set(), first: null, last: null,
        aliases: new Map(),
      };
      byKey.set(key, a);
    }
    a.sku_code = a.sku_code ?? r.sku_code;
    a.jst_sku_id = a.jst_sku_id ?? r.jst_sku_id;
    a.product_name = a.product_name ?? r.product_name ?? r.sku_name;
    a.color = a.color ?? r.color;
    a.size = a.size ?? r.size;
    a.pic = a.pic ?? r.pic;
    // 成本优先取入库单的实际成本；其次采购单价；销售/吊牌价不参与
    if (r.cost_price != null && (r.source === "receipt" || r.source === "purchase")) {
      if (a.cost_price == null || r.source === "receipt") a.cost_price = r.cost_price;
    }
    a.supplier_id = a.supplier_id ?? r.supplier_id;
    a.supplier_name = a.supplier_name ?? r.supplier_name;
    // style_no：采购来源优先
    if (r.style_no && (a.style_no == null || r.source === "purchase")) a.style_no = r.style_no;
    if (a.style_no == null) a.style_no = deriveStyleNo(a.sku_code);
    a.sources.add(r.source);
    if (r.ts) {
      if (!a.first || r.ts < a.first) a.first = r.ts;
      if (!a.last || r.ts > a.last) a.last = r.ts;
    }
    if (r.shop_id && (r.online_sku_code || r.online_product_id)) {
      const ak = `${r.shop_id}|${r.online_sku_code ?? ""}|${r.online_product_id ?? ""}`;
      a.aliases.set(ak, {
        shop_id: r.shop_id,
        online_sku_code: r.online_sku_code,
        online_product_id: r.online_product_id,
        product_name: r.product_name,
        ts: r.ts,
      });
    }
  }

  return { masters: Array.from(byKey.values()), orphanAliases: orphans };
}


async function upsertMasters(masters: Agg[]) {
  let inserted = 0, updated = 0, unchanged = 0, failed = 0;
  const skuCodes = Array.from(new Set(masters.map(m => m.sku_code).filter(Boolean))) as string[];
  const jstIds = Array.from(new Set(masters.map(m => m.jst_sku_id).filter(Boolean))) as string[];

  const existingById = new Map<string, any>(); // id -> row
  const idBySku = new Map<string, string>();
  const idByJst = new Map<string, string>();

  // 预加载已有主档:.in() 列表分块(避免 URL 过长 + 单次响应被 max-rows=1000 截断);
  // 预加载失败必须抛出 —— 漏查会把已有行误判为新行,后续 insert 撞唯一键被当成 0 更新。
  const EXIST_CHUNK = 500;
  const SELECT_COLS = "id, sku_code, jst_sku_id, product_name, sku_name, style_no, color, size, sku_image_url, external_image_url, supplier_id, cost_price, first_seen_at, last_seen_at, source";
  const indexRows = (data: any[] | null) => {
    (data ?? []).forEach((r: any) => {
      existingById.set(r.id, r);
      if (r.sku_code) idBySku.set(r.sku_code, r.id);
      if (r.jst_sku_id) idByJst.set(r.jst_sku_id, r.id);
    });
  };
  for (let i = 0; i < skuCodes.length; i += EXIST_CHUNK) {
    const { data, error } = await admin.from("ops_skus").select(SELECT_COLS).in("sku_code", skuCodes.slice(i, i + EXIST_CHUNK));
    if (error) throw new Error(`ops_skus preload by sku_code: ${error.message}`);
    indexRows(data);
  }
  for (let i = 0; i < jstIds.length; i += EXIST_CHUNK) {
    const { data, error } = await admin.from("ops_skus").select(SELECT_COLS).in("jst_sku_id", jstIds.slice(i, i + EXIST_CHUNK));
    if (error) throw new Error(`ops_skus preload by jst_sku_id: ${error.message}`);
    indexRows(data);
  }

  const masterIdMap = new Map<string, string>(); // agg key -> ops_skus.id

  // sales/refund/aftersale 来源的 supplier_id 是 JST 文本编号,
  // 而 ops_skus/ops_products.supplier_id 是 uuid —— 仅格式合法时写入
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const supplierUuid = (v: string | null) => (v && UUID_RE.test(v) ? v : null);

  // ops_skus.product_id NOT NULL:insert 新主档前必须 find-or-create ops_products
  // (按 code = 款号,与 jst-sync-products 的归属约定一致)
  const productIdByCode = new Map<string, string>();
  const resolveProductId = async (m: Agg, skuCode: string): Promise<string | null> => {
    const code = m.style_no || skuCode;
    const cached = productIdByCode.get(code);
    if (cached) return cached;
    const { data: found, error: findErr } = await admin.from("ops_products").select("id").eq("code", code).maybeSingle();
    if (findErr) {
      console.error(`[derive] ops_products lookup failed code=${code}: ${findErr.message}`);
      return null;
    }
    let pid = found?.id as string | undefined;
    if (!pid) {
      const { data: created, error: insErr } = await admin.from("ops_products").insert({
        code,
        name: m.product_name ?? code,
        product_name: m.product_name,
        style_no: m.style_no,
        supplier_id: supplierUuid(m.supplier_id),
        supplier_name_snapshot: m.supplier_name,
        external_image_url: m.pic,
        cost_price: m.cost_price,
        is_active: true,
        last_synced_at: new Date().toISOString(),
      }).select("id").single();
      if (insErr || !created) {
        console.error(`[derive] ops_products insert failed code=${code}: ${insErr?.message ?? "no row returned"}`);
        return null;
      }
      pid = created.id as string;
    }
    productIdByCode.set(code, pid);
    return pid;
  };

  for (const m of masters) {
    const keyPrimary = m.sku_code ? `sku:${m.sku_code}` : `jst:${m.jst_sku_id}`;
    // 命中策略：优先按 sku_code，再按 jst_sku_id
    const id = (m.sku_code && idBySku.get(m.sku_code)) || (m.jst_sku_id && idByJst.get(m.jst_sku_id)) || null;

    const payload = {
      sku_code: m.sku_code ?? `JST-${m.jst_sku_id}`,
      jst_sku_id: m.jst_sku_id,
      sku_name: m.product_name,
      product_name: m.product_name,
      style_no: m.style_no,
      color: m.color,
      size: m.size,
      sku_image_url: m.pic,
      external_image_url: m.pic,
      supplier_id: supplierUuid(m.supplier_id),
      cost_price: m.cost_price,
      last_seen_at: m.last,
      first_seen_at: m.first,
      source: Array.from(m.sources).join(","),
      last_synced_at: new Date().toISOString(),
    };

    if (id) {
      const ex = existingById.get(id) ?? {};
      const patch: Record<string, any> = {};
      for (const k of ["jst_sku_id","sku_name","product_name","style_no","color","size","sku_image_url","external_image_url","supplier_id","first_seen_at"]) {
        if (!ex[k] && (payload as any)[k]) patch[k] = (payload as any)[k];
      }
      // 若原 sku_code 是 JST-xxx 占位且本次拿到了真实 sku_code，则覆盖
      if (m.sku_code && (!ex.sku_code || /^JST-/.test(ex.sku_code)) && ex.sku_code !== m.sku_code) patch.sku_code = m.sku_code;
      // 来源累计合并
      const prevSources = new Set((ex.source ?? "").split(",").map((s: string) => s.trim()).filter(Boolean));
      Array.from(m.sources).forEach(s => prevSources.add(s));
      const mergedSource = Array.from(prevSources).join(",");
      if (mergedSource !== (ex.source ?? "")) patch.source = mergedSource;
      // cost_price：入库来源覆盖；否则仅在原值为空时补
      if (m.cost_price != null && Number(m.cost_price) !== Number(ex.cost_price)) {
        if (m.sources.has("receipt") || ex.cost_price == null) patch.cost_price = m.cost_price;
      }
      // last_seen_at 仅在前移时更新
      const tsNum = (v: unknown) => { const n = Date.parse(String(v ?? "")); return Number.isNaN(n) ? null : n; };
      const newSeen = tsNum(payload.last_seen_at), oldSeen = tsNum(ex.last_seen_at);
      if (payload.last_seen_at && (oldSeen == null || (newSeen != null && newSeen > oldSeen))) patch.last_seen_at = payload.last_seen_at;

      // 无实质变化则跳过写库:复跑可断点续推,避免一行不差地全量 UPDATE 撞墙钟
      if (Object.keys(patch).length === 0) {
        unchanged++;
        masterIdMap.set(keyPrimary, id);
        if (m.sku_code) idBySku.set(m.sku_code, id);
        if (m.jst_sku_id) idByJst.set(m.jst_sku_id, id);
        continue;
      }
      patch.last_synced_at = payload.last_synced_at;
      const { error } = await admin.from("ops_skus").update(patch).eq("id", id);
      if (error) {
        failed++;
        console.error(`[derive] ops_skus update failed id=${id} sku_code=${payload.sku_code}: ${error.message}`);
      } else { updated++; masterIdMap.set(keyPrimary, id);
        // 同步更新内存索引，防止后续重复插入
        if (m.sku_code) idBySku.set(m.sku_code, id);
        if (m.jst_sku_id) idByJst.set(m.jst_sku_id, id);
      }
    } else {
      const productId = await resolveProductId(m, payload.sku_code);
      if (!productId) { failed++; continue; }
      const { data, error } = await admin.from("ops_skus").insert({ ...payload, product_id: productId }).select("id").single();
      if (error || !data) {
        failed++;
        console.error(`[derive] ops_skus insert failed sku_code=${payload.sku_code}: ${error?.message ?? "no row returned"}`);
      } else {
        inserted++;
        masterIdMap.set(keyPrimary, data.id);
        if (m.sku_code) idBySku.set(m.sku_code, data.id);
        if (m.jst_sku_id) idByJst.set(m.jst_sku_id, data.id);
      }
    }
  }

  return { inserted, updated, unchanged, failed, masterIdMap };
}

async function upsertAliases(masters: Agg[], masterIdMap: Map<string, string>) {
  let aliasUpserts = 0, failed = 0;
  for (const m of masters) {
    const keyPrimary = m.sku_code ? `sku:${m.sku_code}` : `jst:${m.jst_sku_id}`;
    const skuId = masterIdMap.get(keyPrimary);
    if (!skuId) continue;
    for (const a of m.aliases.values()) {
      const row = {
        sku_id: skuId,
        platform: "jst",
        shop_id: a.shop_id,
        external_product_id: a.online_product_id,
        external_sku_code: a.online_sku_code,
        jst_sku_id: m.jst_sku_id,
        online_product_name: a.product_name,
        online_status: "active",
        modified_at: a.ts,
        alias_type: "shop_sku",
      };
      // upsert by (shop_id, external_sku_code) — manual since unique index may not exist
      const { data: existing, error: selError } = await admin.from("ops_sku_aliases")
        .select("id")
        .eq("shop_id", a.shop_id)
        .eq("external_sku_code", a.online_sku_code ?? "")
        .maybeSingle();
      if (selError) {
        failed++;
        console.error(`[derive] ops_sku_aliases lookup failed shop=${a.shop_id} sku=${a.online_sku_code}: ${selError.message}`);
        continue;
      }
      if (existing?.id) {
        const { error } = await admin.from("ops_sku_aliases").update(row).eq("id", existing.id);
        if (error) {
          failed++;
          console.error(`[derive] ops_sku_aliases update failed id=${existing.id}: ${error.message}`);
          continue;
        }
      } else {
        const { error } = await admin.from("ops_sku_aliases").insert(row);
        if (error) {
          failed++;
          console.error(`[derive] ops_sku_aliases insert failed shop=${a.shop_id} sku=${a.online_sku_code}: ${error.message}`);
          continue;
        }
      }
      aliasUpserts++;
    }
  }
  return { aliasUpserts, failed };
}

async function recordExceptions(orphans: DeriveRow[]) {
  let count = 0;
  for (const o of orphans) {
    const { data: dup } = await admin.from("ops_product_mapping_exceptions")
      .select("id")
      .eq("shop_id", o.shop_id ?? "")
      .eq("online_sku_code", o.online_sku_code ?? "")
      .eq("status", "pending")
      .maybeSingle();
    if (dup?.id) continue;
    await admin.from("ops_product_mapping_exceptions").insert({
      platform: "jst",
      shop_id: o.shop_id,
      online_sku_code: o.online_sku_code,
      online_item_code: o.online_product_id,
      source_table: o.source,
      reason: "线上 SKU 未匹配到内部 SKU 主档",
      status: "pending",
      raw_data: { product_name: o.product_name, pic: o.pic },
    });
    count++;
  }
  return count;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const startedAt = new Date().toISOString();
  try {
    // 鉴权：cron secret / internal tick / admin JWT 三选一（与 jst-sync-* 一致）
    const caller = await resolveCaller(req);
    const cronSecret = req.headers.get("x-cron-secret") ?? "";
    const okCron = !!Deno.env.get("JST_SYNC_CRON_SECRET") && cronSecret === Deno.env.get("JST_SYNC_CRON_SECRET");
    const internalTick = req.headers.get("x-internal-tick") ?? "";
    const okInternal = !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") && internalTick === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!okCron && !okInternal && !caller.isAdmin) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const source = String(body.source ?? "all");
    const days = Number(body.days ?? 30);
    const limit = Number(body.limit ?? 20000);

    const { data: logIns } = await admin.from("jst_sync_logs").insert({
      sync_type: "ops_product_master_derive",
      status: "running",
      started_at: startedAt,
      message: `source=${source} days=${days} limit=${limit}`,
    }).select("id").single();
    const logId = logIns?.id;

    const rows = await loadRows(source, days, limit);
    const { masters, orphanAliases } = aggregate(rows);
    const { inserted, updated, unchanged, failed: mastersFailed, masterIdMap } = await upsertMasters(masters);
    const { aliasUpserts: aliases, failed: aliasesFailed } = await upsertAliases(masters, masterIdMap);
    const exceptions = await recordExceptions(orphanAliases);

    // 常态沉淀:商品档案(ops_products)supplier 为空时,取该款最近一张
    // 有效采购单的供应商回填(全表 set-based,与 days/limit 窗口无关)
    let supplierBackfilled: number | null = null;
    let supplierBackfillError: string | null = null;
    {
      const { data, error } = await admin.rpc("ops_products_backfill_supplier_from_po");
      if (error) supplierBackfillError = error.message;
      else supplierBackfilled = Number((data as any)?.products_supplier_backfilled ?? 0);
    }

    const summary = {
      scanned_rows: rows.length,
      masters_inserted: inserted,
      masters_updated: updated,
      masters_unchanged: unchanged,
      masters_failed: mastersFailed,
      aliases_upserted: aliases,
      aliases_failed: aliasesFailed,
      exceptions_recorded: exceptions,
      products_supplier_backfilled: supplierBackfilled,
      ...(supplierBackfillError ? { supplier_backfill_error: supplierBackfillError } : {}),
    };

    if (logId) {
      await admin.from("jst_sync_logs").update({
        status: "success",
        ended_at: new Date().toISOString(),
        fetched_items_count: inserted + updated,
        message: JSON.stringify(summary),
      }).eq("id", logId);
    }

    return new Response(JSON.stringify({ ok: true, ...summary }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ ok: false, error: e?.message || String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
