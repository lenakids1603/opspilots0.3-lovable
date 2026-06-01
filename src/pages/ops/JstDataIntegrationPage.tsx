import { useState } from "react";
import { PageHeader } from "@/components/ops/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Table, TableHeader, TableBody, TableHead, TableRow, TableCell,
} from "@/components/ui/table";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import {
  Collapsible, CollapsibleContent, CollapsibleTrigger,
} from "@/components/ui/collapsible";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel,
  DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import {
  AlertTriangle, RefreshCw, ChevronDown, FileText, Boxes, Package,
  Warehouse, LineChart, Truck, Wrench, Search, Clock, Info,
} from "lucide-react";

// ============================================================
// 数据口径说明
// 经营指标 = 今日 00:00 - 当前累计，聚水潭经营口径，非本次同步新增金额
// ============================================================

type ModuleStatus = "ok" | "warn" | "error";

const STATUS_META: Record<ModuleStatus, { label: string; cls: string }> = {
  ok:    { label: "正常", cls: "bg-emerald-100 text-emerald-700 hover:bg-emerald-100" },
  warn:  { label: "需维护", cls: "bg-amber-100 text-amber-700 hover:bg-amber-100" },
  error: { label: "异常", cls: "bg-rose-100 text-rose-700 hover:bg-rose-100" },
};

function StatusBadge({ value }: { value: ModuleStatus }) {
  const m = STATUS_META[value];
  return <Badge variant="secondary" className={m.cls}>{m.label}</Badge>;
}

// ============================================================
// MOCK 数据 — 与界面文案对应
// ============================================================

const GLOBAL = {
  status: "部分异常",
  auto: "已开启",
  lastSync: "10:15",
  nextSync: "10:25",
  todayBatches: 42,
  todayRecords: 1242,
  successRecords: 1240,
  failedRecords: 2,
  running: 0,
};

const ABNORMAL_MODULES = ["基础库存（超时）", "发货物流（同步失败）"];

const SCHEDULE: Array<{
  module: string; content: string; freq: string;
  last: string; next: string; status: ModuleStatus; statusNote?: string;
}> = [
  { module: "基础档案",    content: "店铺、供应商、仓库",       freq: "每天凌晨 02:00 全量", last: "今日 02:00", next: "明日 02:00", status: "ok" },
  { module: "商品与 SKU",  content: "商品资料、SKU 资料、商品图片", freq: "每 30 分钟 增量",   last: "10:00",     next: "10:30",     status: "ok" },
  { module: "采购与入库",  content: "采购单、采购入库单",       freq: "每 10 分钟 增量",   last: "10:10",     next: "10:20",     status: "ok" },
  { module: "库存",        content: "基础库存、可用库存、锁定库存", freq: "每 10 分钟 全量",   last: "10:05（超时）", next: "自动重试中", status: "error", statusNote: "自动重试中" },
  { module: "销售与退款",  content: "GMV、GSV、退款金额、订单数、退款率", freq: "每 10 分钟 增量", last: "10:15",     next: "10:25",     status: "ok" },
];

const SALES = {
  range: "今日 00:00 - 当前",
  lastSync: "10:15",
  caliber: "聚水潭经营口径",
  todayGmv: 12000,
  todayGsv: 11000,
  todayRefund: 1000,
  todayOrders: 128,
  refundRate: 8.3,
  activeShops: 12,
  syncDeltaOrders: 15,
  syncDeltaGmv: 320,
};

const MODULES_PHASE1: Array<{
  name: string; content: string; freq: string;
  last: string; next: string; status: ModuleStatus; recent: string;
}> = [
  { name: "店铺资料 (Shop)",       content: "店铺基本信息", freq: "每天 02:00",  last: "今日 02:00", next: "明日 02:00", status: "ok",    recent: "新增 0 条，更新 2 条" },
  { name: "商品资料 (Product)",    content: "款式档案、分类", freq: "每 30 分钟", last: "10:00",     next: "10:30",     status: "ok",    recent: "新增 15 条，更新 3 条" },
  { name: "SKU 资料 (SKU)",        content: "条码、规格",   freq: "每 30 分钟", last: "10:00",     next: "10:30",     status: "warn",  recent: "4 条失败，原因：API Rate Limit" },
  { name: "基础库存 (Inventory)",  content: "可用库存",     freq: "每 10 分钟", last: "10:05（超时）", next: "自动重试中", status: "error", recent: "已自动重试 1 次，等待第 2 次重试" },
];

const LOGS: Array<{
  time: string; trigger: string; group: string; module: string;
  status: ModuleStatus; added: string; updated: string; failed: string;
  cumulative: string; cost: string; error: string;
}> = [
  { time: "10:15:22", trigger: "自动同步", group: "销售经营", module: "店铺销售汇总", status: "ok",
    added: "15 单 / ¥320 GMV", updated: "3 单", failed: "0", cumulative: "今日 GMV ¥12,000", cost: "1.2s", error: "-" },
  { time: "10:14:05", trigger: "失败重试", group: "基础档案", module: "SKU 资料", status: "error",
    added: "0", updated: "0", failed: "4 条", cumulative: "SKU 总数 679", cost: "0.8s", error: "API Rate Limit Exceeded" },
  { time: "10:10:00", trigger: "自动同步", group: "采购与入库", module: "采购单", status: "ok",
    added: "2 单", updated: "0", failed: "0", cumulative: "今日采购单 36", cost: "0.5s", error: "-" },
  { time: "10:05:00", trigger: "自动同步", group: "库存", module: "基础库存", status: "error",
    added: "0", updated: "0", failed: "0", cumulative: "库存 SKU 679", cost: "30s", error: "Connection Timeout" },
];

const fmtMoney = (n: number) => "¥" + n.toLocaleString("zh-CN");

// ============================================================
// 子组件
// ============================================================

function SectionCard({
  icon, title, status, children, footer,
}: {
  icon: React.ReactNode; title: string; status?: ModuleStatus;
  children: React.ReactNode; footer?: React.ReactNode;
}) {
  return (
    <Card>
      <CardContent className="p-4 space-y-2">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2 text-sm font-medium">
            {icon}{title}
          </div>
          {status && <StatusBadge value={status} />}
        </div>
        {children}
        {footer && (
          <div className="pt-2 mt-2 border-t border-border text-xs text-muted-foreground space-y-0.5">
            {footer}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function MetricRow({ label, value, tone }: { label: string; value: React.ReactNode; tone?: "destructive" | "default" }) {
  return (
    <div className="flex items-baseline justify-between text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className={`tabular-nums font-medium ${tone === "destructive" ? "text-destructive" : ""}`}>{value}</span>
    </div>
  );
}

// ============================================================
// 主组件
// ============================================================

export default function JstDataIntegrationPage() {
  const [keyword, setKeyword] = useState("");
  const [triggerFilter, setTriggerFilter] = useState("all");
  const [groupFilter, setGroupFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");

  const filteredLogs = LOGS.filter(l => {
    if (triggerFilter !== "all" && l.trigger !== triggerFilter) return false;
    if (groupFilter !== "all" && l.group !== groupFilter) return false;
    if (statusFilter !== "all" && l.status !== statusFilter) return false;
    if (keyword && !`${l.module} ${l.group} ${l.error}`.toLowerCase().includes(keyword.toLowerCase())) return false;
    return true;
  });

  return (
    <div className="space-y-6">
      <PageHeader
        breadcrumb={["系统设置", "聚水潭数据接入详情"]}
        title="聚水潭数据接入详情"
        description="用于管理聚水潭的数据接入状态。日常以自动同步为主，下面所有经营指标均为指定时间范围内的累计值，不是本次同步新增金额。"
        actions={
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button>
                <RefreshCw className="w-4 h-4 mr-1.5" /> 同步操作
                <ChevronDown className="w-4 h-4 ml-1" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-56">
              <DropdownMenuLabel className="text-xs text-muted-foreground">
                人工补救入口（非日常）
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuItem>重试异常模块</DropdownMenuItem>
              <DropdownMenuItem>同步指定模块</DropdownMenuItem>
              <DropdownMenuItem>按款号补同步</DropdownMenuItem>
              <DropdownMenuItem>按 SKU 补同步</DropdownMenuItem>
              <DropdownMenuItem>按店铺补同步</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem>同步最近 7 天</DropdownMenuItem>
              <DropdownMenuItem>同步最近 30 天</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        }
      />

      {/* 一、异常提示 */}
      <Card className="border-amber-300 bg-amber-50/60">
        <CardContent className="p-4 flex items-start gap-3">
          <AlertTriangle className="w-5 h-5 text-amber-600 mt-0.5 shrink-0" />
          <div className="flex-1 space-y-1">
            <div className="text-sm font-medium text-amber-900">
              {ABNORMAL_MODULES.length} 个模块同步异常（自动重试中）
            </div>
            <div className="text-xs text-amber-800">
              {ABNORMAL_MODULES.join("、")}。系统正在进行指数级重试，建议观察。
            </div>
          </div>
          <Button variant="outline" size="sm">查看异常</Button>
          <Button size="sm">手动重试</Button>
        </CardContent>
      </Card>

      {/* 二、全局同步状态 — 重构数字含义 */}
      <Card>
        <CardContent className="p-5">
          <div className="flex flex-wrap items-start justify-between gap-6">
            <div className="space-y-2">
              <div className="flex items-center gap-2">
                <RefreshCw className="w-5 h-5 text-primary" />
                <h3 className="text-base font-semibold">全局同步状态</h3>
              </div>
              <div className="flex items-center gap-2 text-xs">
                <Badge variant="secondary" className="bg-amber-100 text-amber-700">{GLOBAL.status}</Badge>
                <Badge variant="secondary" className="bg-emerald-100 text-emerald-700">自动同步：{GLOBAL.auto}</Badge>
              </div>
              <div className="text-xs text-muted-foreground flex items-center gap-3">
                <span>最近同步：{GLOBAL.lastSync}</span>
                <span>下次自动同步：{GLOBAL.nextSync}</span>
              </div>
            </div>

            <div className="grid grid-cols-2 md:grid-cols-5 gap-x-8 gap-y-3 text-sm">
              <div>
                <div className="text-xs text-muted-foreground">今日同步批次</div>
                <div className="text-xl font-semibold tabular-nums">{GLOBAL.todayBatches}</div>
                <div className="text-[11px] text-muted-foreground">任务运行次数</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground">今日同步记录</div>
                <div className="text-xl font-semibold tabular-nums">{GLOBAL.todayRecords.toLocaleString()}</div>
                <div className="text-[11px] text-muted-foreground">处理数据条数</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground">成功记录</div>
                <div className="text-xl font-semibold tabular-nums text-emerald-600">{GLOBAL.successRecords.toLocaleString()}</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground">失败记录</div>
                <div className="text-xl font-semibold tabular-nums text-rose-600">{GLOBAL.failedRecords}</div>
              </div>
              <div>
                <div className="text-xs text-muted-foreground">运行中任务</div>
                <div className="text-xl font-semibold tabular-nums">{GLOBAL.running}</div>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* 三、自动同步计划 — 补上次/下次执行 */}
      <Card>
        <CardContent className="p-0">
          <div className="px-5 py-4 flex items-center gap-2 border-b border-border">
            <Clock className="w-4 h-4 text-muted-foreground" />
            <h3 className="text-sm font-semibold">自动同步计划</h3>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>业务模块</TableHead>
                <TableHead>同步内容</TableHead>
                <TableHead>同步频率</TableHead>
                <TableHead>上次执行</TableHead>
                <TableHead>下次执行</TableHead>
                <TableHead>当前状态</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {SCHEDULE.map(row => (
                <TableRow key={row.module}>
                  <TableCell className="font-medium">{row.module}</TableCell>
                  <TableCell className="text-muted-foreground">{row.content}</TableCell>
                  <TableCell className="text-muted-foreground">{row.freq}</TableCell>
                  <TableCell className={row.status === "error" ? "text-rose-600" : ""}>{row.last}</TableCell>
                  <TableCell className={row.status === "error" ? "text-rose-600" : ""}>{row.next}</TableCell>
                  <TableCell><StatusBadge value={row.status} /></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* 四、核心数据概览 — 每张卡都标明最近同步时间 */}
      <div>
        <h3 className="text-sm font-semibold mb-3">核心数据概览</h3>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">

          <SectionCard
            icon={<FileText className="w-4 h-4 text-muted-foreground" />}
            title="基础档案"
            status="warn"
            footer={<div>最近同步：今日 02:00（每日全量）</div>}
          >
            <MetricRow label="店铺" value={36} />
            <MetricRow label="供应商" value={6} />
            <MetricRow label="仓库" value={2} />
          </SectionCard>

          <SectionCard
            icon={<Package className="w-4 h-4 text-muted-foreground" />}
            title="商品与 SKU"
            status="ok"
            footer={<div>最近同步：10:15（每 30 分钟）</div>}
          >
            <MetricRow label="商品" value={680} />
            <MetricRow label="SKU" value={679} />
            <MetricRow label="图片缓存" value="100%" />
          </SectionCard>

          <SectionCard
            icon={<Boxes className="w-4 h-4 text-muted-foreground" />}
            title="采购与入库"
            status="ok"
            footer={<div>最近同步：10:10（每 10 分钟）</div>}
          >
            <MetricRow label="今日采购单" value={36} />
            <MetricRow label="今日入库单" value={22} />
            <MetricRow label="入库异常" value={0} />
          </SectionCard>

          <SectionCard
            icon={<Warehouse className="w-4 h-4 text-muted-foreground" />}
            title="库存情况"
            status="error"
            footer={
              <>
                <div>最近同步：10:05（超时）</div>
                <div className="text-amber-700">当前状态：自动重试中</div>
              </>
            }
          >
            <MetricRow label="库存 SKU" value={679} />
            <MetricRow label="异常记录" value={1} tone="destructive" />
          </SectionCard>

          <SectionCard
            icon={<LineChart className="w-4 h-4 text-muted-foreground" />}
            title="销售与退款"
            status="ok"
            footer={
              <>
                <div>统计范围：{SALES.range}｜最近同步：{SALES.lastSync}</div>
                <div>口径：{SALES.caliber}</div>
                <div className="text-muted-foreground/80">
                  本次同步新增：{SALES.syncDeltaOrders} 单 / {fmtMoney(SALES.syncDeltaGmv)} GMV
                </div>
              </>
            }
          >
            <MetricRow label="今日 GMV" value={fmtMoney(SALES.todayGmv)} />
            <MetricRow label="今日 GSV" value={fmtMoney(SALES.todayGsv)} />
            <MetricRow label="今日退款金额" value={fmtMoney(SALES.todayRefund)} />
            <MetricRow label="今日退款率" value={`${SALES.refundRate}%`} />
          </SectionCard>

          <SectionCard
            icon={<Truck className="w-4 h-4 text-muted-foreground" />}
            title="履约与售后"
            status="ok"
            footer={<div>最近同步：10:10（每 10 分钟）</div>}
          >
            <MetricRow label="待发货" value={116} />
            <MetricRow label="超时未发货" value={8} tone="destructive" />
            <MetricRow label="今日售后单" value={12} />
          </SectionCard>
        </div>
      </div>

      {/* 五、同步模块管理 */}
      <div>
        <h3 className="text-sm font-semibold mb-3">同步模块管理</h3>
        <Card>
          <CardContent className="p-0">
            <Tabs defaultValue="phase1">
              <div className="px-4 pt-3">
                <TabsList>
                  <TabsTrigger value="phase1">第一阶段核心同步</TabsTrigger>
                  <TabsTrigger value="sales">销售经营同步</TabsTrigger>
                  <TabsTrigger value="future">后续预留模块</TabsTrigger>
                </TabsList>
              </div>

              <TabsContent value="phase1" className="m-0">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>模块名称</TableHead>
                      <TableHead>同步内容</TableHead>
                      <TableHead>自动同步频率</TableHead>
                      <TableHead>上次同步</TableHead>
                      <TableHead>下次同步</TableHead>
                      <TableHead>状态</TableHead>
                      <TableHead>最近结果 / 异常处理</TableHead>
                      <TableHead className="text-right">操作</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {MODULES_PHASE1.map(m => (
                      <TableRow key={m.name}>
                        <TableCell className="font-medium">{m.name}</TableCell>
                        <TableCell className="text-muted-foreground">{m.content}</TableCell>
                        <TableCell className="text-muted-foreground">{m.freq}</TableCell>
                        <TableCell className={m.status === "error" ? "text-rose-600" : ""}>{m.last}</TableCell>
                        <TableCell className={m.status === "error" ? "text-rose-600" : ""}>{m.next}</TableCell>
                        <TableCell><StatusBadge value={m.status} /></TableCell>
                        <TableCell className="text-xs text-muted-foreground max-w-[260px]">{m.recent}</TableCell>
                        <TableCell className="text-right space-x-2">
                          {m.status === "error"
                            ? <Button variant="ghost" size="sm">重试</Button>
                            : <Button variant="ghost" size="sm">配置</Button>}
                          <Button variant="ghost" size="sm">日志</Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </TabsContent>

              <TabsContent value="sales" className="m-0 p-5 space-y-4">
                <div className="rounded-md border border-border bg-muted/30 p-3 text-xs text-muted-foreground leading-relaxed">
                  当前销售与退款数据采用<strong className="text-foreground">聚水潭经营口径</strong>，用于日常经营监控，
                  解决多店铺每天手动拉表问题。这里展示的是<strong className="text-foreground">今日累计数据</strong>，
                  不是本次同步新增数据。月底财务核账时，可结合平台导入表格进行复核。
                </div>

                <div className="rounded-md border border-border p-4 space-y-3">
                  <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
                    <div>统计范围：{SALES.range}</div>
                    <div>最近同步：{SALES.lastSync}</div>
                  </div>
                  <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
                    <div>
                      <div className="text-xs text-muted-foreground">今日 GMV</div>
                      <div className="text-xl font-semibold tabular-nums">{fmtMoney(SALES.todayGmv)}</div>
                    </div>
                    <div>
                      <div className="text-xs text-muted-foreground">今日 GSV</div>
                      <div className="text-xl font-semibold tabular-nums">{fmtMoney(SALES.todayGsv)}</div>
                    </div>
                    <div>
                      <div className="text-xs text-muted-foreground">今日退款金额</div>
                      <div className="text-xl font-semibold tabular-nums">{fmtMoney(SALES.todayRefund)}</div>
                    </div>
                    <div>
                      <div className="text-xs text-muted-foreground">今日订单数</div>
                      <div className="text-xl font-semibold tabular-nums">{SALES.todayOrders}</div>
                    </div>
                    <div>
                      <div className="text-xs text-muted-foreground">今日退款率</div>
                      <div className="text-xl font-semibold tabular-nums">{SALES.refundRate}%</div>
                    </div>
                    <div>
                      <div className="text-xs text-muted-foreground">活跃店铺</div>
                      <div className="text-xl font-semibold tabular-nums">{SALES.activeShops} 家</div>
                    </div>
                  </div>
                  <div className="text-xs text-muted-foreground pt-2 border-t border-border">
                    {SALES.caliber}｜本次同步新增：{SALES.syncDeltaOrders} 单 / {fmtMoney(SALES.syncDeltaGmv)} GMV
                  </div>
                </div>
              </TabsContent>

              <TabsContent value="future" className="m-0 p-8 text-center text-sm text-muted-foreground">
                后续模块（直播、达人、短视频、广告投放等）规划中。
              </TabsContent>
            </Tabs>
          </CardContent>
        </Card>
      </div>

      {/* 六、补数据工具 — 折叠 + 提示 */}
      <Collapsible>
        <Card>
          <CollapsibleTrigger asChild>
            <button className="w-full px-5 py-4 flex items-center justify-between hover:bg-muted/30 transition-colors">
              <div className="flex items-center gap-2 text-left">
                <Wrench className="w-4 h-4 text-muted-foreground" />
                <div>
                  <div className="text-sm font-semibold">补数据工具</div>
                  <div className="text-xs text-muted-foreground mt-0.5">
                    日常不需要操作，仅用于异常修复和历史数据补同步。
                  </div>
                </div>
              </div>
              <ChevronDown className="w-4 h-4 text-muted-foreground" />
            </button>
          </CollapsibleTrigger>
          <CollapsibleContent>
            <CardContent className="pt-0 pb-5 px-5 space-y-3 border-t border-border">
              <div className="flex flex-wrap gap-2 pt-4">
                <Button variant="outline" size="sm">按时间窗补同步</Button>
                <Button variant="outline" size="sm">按款号补同步</Button>
                <Button variant="outline" size="sm">按 SKU 补同步</Button>
                <Button variant="outline" size="sm">按店铺补同步</Button>

                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <Button variant="destructive" size="sm">
                      <AlertTriangle className="w-3.5 h-3.5 mr-1" />
                      全量同步全部数据
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>确认全量同步？</AlertDialogTitle>
                      <AlertDialogDescription>
                        全量同步会重新拉取聚水潭所有数据，耗时较长且占用 API 配额，
                        仅在系统迁移或数据严重错乱时使用。请确认继续。
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>取消</AlertDialogCancel>
                      <AlertDialogAction>确认执行</AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              </div>
              <p className="text-xs text-muted-foreground">
                提示：所有补数据操作都会在同步日志中留痕，触发方式标记为「手动补数据」。
              </p>
            </CardContent>
          </CollapsibleContent>
        </Card>
      </Collapsible>

      {/* 七、同步日志 — 区分「本次新增」和「当前累计」 */}
      <Card>
        <CardContent className="p-0">
          <div className="px-5 py-4 flex flex-wrap items-center justify-between gap-3 border-b border-border">
            <h3 className="text-sm font-semibold">同步日志</h3>
            <div className="flex flex-wrap items-center gap-2">
              <Select value={triggerFilter} onValueChange={setTriggerFilter}>
                <SelectTrigger className="w-[130px] h-9"><SelectValue placeholder="触发方式" /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">全部触发方式</SelectItem>
                  <SelectItem value="自动同步">自动同步</SelectItem>
                  <SelectItem value="失败重试">失败重试</SelectItem>
                  <SelectItem value="手动补数据">手动补数据</SelectItem>
                </SelectContent>
              </Select>
              <Select value={groupFilter} onValueChange={setGroupFilter}>
                <SelectTrigger className="w-[140px] h-9"><SelectValue placeholder="模块分类" /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">全部模块分类</SelectItem>
                  <SelectItem value="基础档案">基础档案</SelectItem>
                  <SelectItem value="采购与入库">采购与入库</SelectItem>
                  <SelectItem value="库存">库存</SelectItem>
                  <SelectItem value="销售经营">销售经营</SelectItem>
                </SelectContent>
              </Select>
              <Select value={statusFilter} onValueChange={setStatusFilter}>
                <SelectTrigger className="w-[120px] h-9"><SelectValue placeholder="状态" /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">全部状态</SelectItem>
                  <SelectItem value="ok">成功</SelectItem>
                  <SelectItem value="warn">部分失败</SelectItem>
                  <SelectItem value="error">失败</SelectItem>
                </SelectContent>
              </Select>
              <div className="relative">
                <Search className="w-3.5 h-3.5 absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
                <Input
                  value={keyword}
                  onChange={e => setKeyword(e.target.value)}
                  placeholder="搜索关键词"
                  className="h-9 pl-7 w-[180px]"
                />
              </div>
            </div>
          </div>

          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>时间</TableHead>
                  <TableHead>触发方式</TableHead>
                  <TableHead>模块分类</TableHead>
                  <TableHead>同步模块</TableHead>
                  <TableHead>状态</TableHead>
                  <TableHead>本次新增</TableHead>
                  <TableHead>本次更新</TableHead>
                  <TableHead>本次失败</TableHead>
                  <TableHead>当前累计</TableHead>
                  <TableHead>耗时</TableHead>
                  <TableHead>错误原因</TableHead>
                  <TableHead className="text-right">操作</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filteredLogs.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={12} className="text-center text-muted-foreground py-10">
                      没有匹配的日志
                    </TableCell>
                  </TableRow>
                ) : filteredLogs.map((l, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-xs whitespace-nowrap">{l.time}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className="font-normal">{l.trigger}</Badge>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{l.group}</TableCell>
                    <TableCell>{l.module}</TableCell>
                    <TableCell><StatusBadge value={l.status} /></TableCell>
                    <TableCell className="text-xs">{l.added}</TableCell>
                    <TableCell className="text-xs">{l.updated}</TableCell>
                    <TableCell className={`text-xs ${l.failed !== "0" ? "text-rose-600" : ""}`}>{l.failed}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{l.cumulative}</TableCell>
                    <TableCell className="text-xs">{l.cost}</TableCell>
                    <TableCell className="text-xs text-rose-600 max-w-[200px] truncate" title={l.error}>{l.error}</TableCell>
                    <TableCell className="text-right">
                      <Button variant="ghost" size="sm">{l.status === "error" ? "重试" : "详情"}</Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          <div className="px-5 py-3 text-[11px] text-muted-foreground border-t border-border">
            <span className="font-medium">本次新增</span> = 这次同步真正写入的数据；
            <span className="font-medium ml-2">当前累计</span> = 该模块在系统里的累计值。两者不可混淆。
          </div>
        </CardContent>
      </Card>

      {/* 十、全局说明 */}
      <div className="flex items-start gap-2 rounded-md border border-border bg-muted/30 px-4 py-3 text-xs text-muted-foreground leading-relaxed">
        <Info className="w-4 h-4 mt-0.5 shrink-0" />
        <div>
          系统以<strong className="text-foreground">自动同步</strong>为主，人工同步仅用于异常重试和补数据。
          页面中的 GMV、GSV、退款金额等经营指标均为<strong className="text-foreground">指定时间范围内的累计值</strong>，
          <strong className="text-foreground">不代表本次同步新增金额</strong>。
        </div>
      </div>
    </div>
  );
}
