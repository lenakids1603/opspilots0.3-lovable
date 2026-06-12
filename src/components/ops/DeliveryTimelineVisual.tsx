// DeliveryTimelineVisual.tsx
// 货期交付看板（运营端）与供应商门户工作台共用的货期时间轴：
// 商品缩略图 + 浅底深字彩带 + 日期多选（再点取消）。
//
// 设计与 ChaseListVisual.tsx 保持一致（请勿“美化”改动）：
//   1) 40px 缩略图、右下角件数角标、无彩色描边，1px 发丝边；
//   2) 彩带浅底深字，全页只允许红橙两个警示色且只用于文字；
//   3) 缩略图与彩带在同一个 grid 内，天然对齐；
//   4) 未选中的天整列灰显 opacity 0.35。

import { useMemo } from "react";
import type { StyleImageInfo } from "@/hooks/useProductImages";

export interface DeliveryTimelineEntry {
  ymd: string;                  // 计划交付日（北京时间 YYYY-MM-DD）
  style_no: string;
  product_name: string | null;
  qty: number;                  // 待入库件数
}

const SUB = "#6E7480";
const FAINT = "#9AA1AA";
const HAIRLINE = "rgba(17,24,32,0.08)";
const RED = "#A82F2F";

const TONES = {
  red: { bg: "#FBEDEC", deep: "#7A2222" },
  orange: { bg: "#FAE8D9", deep: "#8A4310" },
  purple: { bg: "#EEEDFA", deep: "#2A2566" },
  amber: { bg: "#FAF0DC", deep: "#6A4106" },
  teal: { bg: "#E4F4EE", deep: "#0A4A3A" },
} as const;
type ToneKey = keyof typeof TONES;

const CHEVRON =
  "polygon(0 0, calc(100% - 10px) 0, 100% 50%, calc(100% - 10px) 100%, 0 100%, 10px 50%)";

function addDaysYmd(ymd: string, n: number): string {
  const d = new Date(ymd + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
function md(ymd: string): string {
  return `${+ymd.slice(5, 7)}/${+ymd.slice(8, 10)}`;
}

interface DayStyle { style_no: string; name: string | null; qty: number }
export interface DeliveryDay {
  ymd: string;
  label: string;
  tone: ToneKey;
  qty: number;          // 当天待入库件数合计
  styles: DayStyle[];   // 按件数降序，最多 3 个
  restCount: number;
  isToday: boolean;
}

/** 把待交付明细按天分桶（前 dayBefore 天 ~ 后 dayAfter 天，逐天一列） */
export function buildDeliveryDays(
  entries: DeliveryTimelineEntry[],
  todayYmd: string,
  dayBefore = 5,
  dayAfter = 14,
): DeliveryDay[] {
  const byDay = new Map<string, Map<string, DayStyle>>();
  for (const e of entries) {
    if (!e.ymd || !(e.qty > 0)) continue;
    let m = byDay.get(e.ymd);
    if (!m) { m = new Map(); byDay.set(e.ymd, m); }
    const cur = m.get(e.style_no);
    if (cur) {
      cur.qty += e.qty;
      if (!cur.name && e.product_name) cur.name = e.product_name;
    } else {
      m.set(e.style_no, { style_no: e.style_no, name: e.product_name, qty: e.qty });
    }
  }
  const out: DeliveryDay[] = [];
  for (let i = -dayBefore; i <= dayAfter; i++) {
    const ymd = addDaysYmd(todayYmd, i);
    const styles = [...(byDay.get(ymd)?.values() ?? [])].sort((a, b) => b.qty - a.qty);
    out.push({
      ymd,
      label: i === 0 ? `今天 ${md(ymd)}` : md(ymd),
      tone: i < 0 ? "red" : i === 0 ? "purple" : i <= 3 ? "amber" : "teal",
      qty: styles.reduce((s, x) => s + x.qty, 0),
      styles: styles.slice(0, 3),
      restCount: Math.max(0, styles.length - 3),
      isToday: i === 0,
    });
  }
  return out;
}

/* ---------- 紧急度五档（供应商工作台，2026-06-12 与催货页同构） ----------
 * 协议到货日为日粒度：已逾期(<今天) / 24小时内(今天) / 48小时内(明天) /
 * 72小时内(后天) / 7天内(3~7天)。红>橙>黄突出前三档，后两档常规色。
 * 仅含【已逾期～未来7天】的待交付；DeliveryDay.ymd 复用为档位 key。 */
export type DeliveryTierKey = "overdue" | "due24" | "due48" | "due72" | "due7";

const TIER_DEFS: { key: DeliveryTierKey; label: string; tone: ToneKey }[] = [
  { key: "overdue", label: "已逾期", tone: "red" },
  { key: "due24", label: "24小时内", tone: "orange" },
  { key: "due48", label: "48小时内", tone: "amber" },
  { key: "due72", label: "72小时内", tone: "teal" },
  { key: "due7", label: "7天内", tone: "teal" },
];

/** 把交付日（北京 YYYY-MM-DD）映射到档位；超出 7 天返回 null（不进工作台视图） */
export function deliveryTierKeyForYmd(ymd: string, todayYmd: string): DeliveryTierKey | null {
  if (!ymd) return null;
  if (ymd < todayYmd) return "overdue";
  if (ymd === todayYmd) return "due24";
  if (ymd === addDaysYmd(todayYmd, 1)) return "due48";
  if (ymd === addDaysYmd(todayYmd, 2)) return "due72";
  if (ymd <= addDaysYmd(todayYmd, 7)) return "due7";
  return null;
}

/** 把待交付明细按紧急度分为固定五档（已逾期～未来 7 天） */
export function buildDeliveryTiers(
  entries: DeliveryTimelineEntry[],
  todayYmd: string,
): DeliveryDay[] {
  const byTier = new Map<DeliveryTierKey, Map<string, DayStyle>>();
  for (const e of entries) {
    if (!e.ymd || !(e.qty > 0)) continue;
    const tier = deliveryTierKeyForYmd(e.ymd, todayYmd);
    if (!tier) continue;
    let m = byTier.get(tier);
    if (!m) { m = new Map(); byTier.set(tier, m); }
    const cur = m.get(e.style_no);
    if (cur) {
      cur.qty += e.qty;
      if (!cur.name && e.product_name) cur.name = e.product_name;
    } else {
      m.set(e.style_no, { style_no: e.style_no, name: e.product_name, qty: e.qty });
    }
  }
  return TIER_DEFS.map((def) => {
    const styles = [...(byTier.get(def.key)?.values() ?? [])].sort((a, b) => b.qty - a.qty);
    return {
      ymd: def.key,
      label: def.label,
      tone: def.tone,
      qty: styles.reduce((s, x) => s + x.qty, 0),
      styles: styles.slice(0, 3),
      restCount: Math.max(0, styles.length - 3),
      isToday: def.key === "due24",
    };
  });
}

/** 时间轴标题旁的选中横幅 / 操作提示 */
export function TimelineSelectionBanner({
  days, selected, onClear, hint,
}: {
  days: DeliveryDay[];
  selected: Set<string>;
  onClear: () => void;
  hint?: string;
}) {
  const sel = days.filter((d) => selected.has(d.ymd));
  if (sel.length === 0) {
    return <span style={{ fontSize: 11, color: FAINT }}>{hint ?? "点选一天或多天，叠加筛选下方明细"}</span>;
  }
  const qty = sel.reduce((s, d) => s + d.qty, 0);
  return (
    <button
      type="button"
      onClick={onClear}
      style={{
        display: "inline-flex", alignItems: "center", gap: 4, border: "none", background: "none",
        color: RED, fontSize: 12.5, fontWeight: 500, cursor: "pointer", padding: "4px 6px",
      }}
    >
      已选 {sel.map((d) => d.label).join(" + ")} · 合计 {qty.toLocaleString("zh-CN")} 件 · 点击清除
    </button>
  );
}

function Thumb({ img, qty, dim, title }: {
  img: string | null; qty: number; dim: boolean; title: string;
}) {
  return (
    <div
      title={title}
      style={{
        position: "relative", width: 40, height: 40, borderRadius: 6, background: "#F3F4F6",
        border: `1px solid ${HAIRLINE}`, overflow: "hidden", flexShrink: 0, opacity: dim ? 0.35 : 1,
      }}
    >
      {img && (
        <img src={img} referrerPolicy="no-referrer" loading="lazy" alt=""
          style={{ width: "100%", height: "100%", objectFit: "cover" }}
          onError={(e) => { e.currentTarget.style.display = "none"; }} />
      )}
      <span style={{ position: "absolute", right: 0, bottom: 0, background: "rgba(15,18,22,0.62)", color: "#FFF", fontSize: 10, lineHeight: "14px", padding: "0 4px", borderTopLeftRadius: 5 }}>
        {qty}
      </span>
    </div>
  );
}

/** 时间轴主体：每天一列（缩略图竖排 + 彩带同列对齐），点彩带/缩略图切换该天选中 */
export function DeliveryTimelineGrid({
  days, styleImages, selected, onToggle,
}: {
  days: DeliveryDay[];
  styleImages?: Record<string, StyleImageInfo>;
  selected: Set<string>;
  onToggle: (ymd: string) => void;
}) {
  // 缩略图区按本期最高的一列预留高度，保证彩带横向对齐
  const maxBlocks = useMemo(
    () => Math.max(1, ...days.map((d) => d.styles.length + (d.restCount > 0 ? 1 : 0))),
    [days],
  );
  const thumbAreaH = maxBlocks * 40 + (maxBlocks - 1) * 4;

  return (
    <div style={{ overflowX: "auto" }}>
      <div style={{ display: "grid", gridTemplateColumns: `repeat(${days.length}, minmax(0,1fr))`, gap: 4, minWidth: days.length * 72 }}>
        {days.map((d) => {
          const dim = selected.size > 0 && !selected.has(d.ymd);
          const tone = TONES[d.tone];
          return (
            <div
              key={d.ymd}
              style={{ display: "flex", flexDirection: "column", cursor: d.qty ? "pointer" : "default" }}
              onClick={() => { if (d.qty) onToggle(d.ymd); }}
            >
              <div style={{ height: thumbAreaH, display: "flex", flexDirection: "column", justifyContent: "flex-end", alignItems: "center", gap: 4, marginBottom: 8 }}>
                {d.styles.map((s) => {
                  const info = styleImages?.[s.style_no];
                  const name = info?.product_name || s.name || "";
                  return (
                    <Thumb key={s.style_no} img={info?.image_url ?? null} qty={s.qty} dim={dim}
                      title={name ? `${s.style_no} ${name}` : s.style_no} />
                  );
                })}
                {d.restCount > 0 && (
                  <div style={{ width: 40, height: 40, borderRadius: 6, background: "#F3F4F6", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 12, color: SUB, flexShrink: 0, opacity: dim ? 0.35 : 1 }}>
                    +{d.restCount}
                  </div>
                )}
              </div>
              <div style={{ height: 42, clipPath: CHEVRON, background: tone.bg, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", opacity: dim ? 0.35 : 1 }}>
                <span style={{ fontSize: 12.5, fontWeight: 500, color: tone.deep, whiteSpace: "nowrap" }}>{d.label}</span>
                <span style={{ fontSize: 11, color: tone.deep, opacity: 0.75 }}>{d.qty ? `${d.qty.toLocaleString("zh-CN")} 件` : "—"}</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
