-- service_role 角色级 statement_timeout 提高到 300s。
-- 背景：service_role 此前无角色级超时，继承全局默认 2min；JST 同步（edge function 经
-- PostgREST 以 service_role 执行）的汇总刷新 RPC 在数据库 I/O 紧张时超过 2min 被取消，
-- 导致销售订单自动同步连续失败（2026-06-11 北京时间 09:45 起）。
-- 前端用户走 anon(3s)/authenticated(8s) 角色超时，不受影响。

ALTER ROLE service_role SET statement_timeout = '300s';

-- 让 PostgREST 重新加载角色配置（新设置对其后的连接生效）
NOTIFY pgrst, 'reload config';
