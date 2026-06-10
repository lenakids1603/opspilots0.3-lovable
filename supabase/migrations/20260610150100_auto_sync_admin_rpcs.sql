-- 自动同步管理 RPC（前端「自动同步总览」页面用）
--  1. get_auto_sync_overview()              — 每个 cron 同步任务的调度状态 + 最近一次运行 + 24h 成败计数
--  2. set_auto_sync_active(jobname, active) — 启停指定 cron 任务，写 audit_logs 审计
--  权限：均为 SECURITY DEFINER，仅 ops_role='admin'（public.has_ops_role）可调用。
--  说明：
--   - cron.job 在 cron schema 下，前端（authenticated 角色）无法直接查询，故经由这两个 RPC 代理。
--   - 最近一次运行从 jst_sync_jobs 取该 sync_type 最新一条 trigger_type='cron' 的记录。
--     退款 / 售后收货目前走 legacy 一次性路径（只写 jst_sync_logs，不写 jst_sync_jobs），
--     dispatch 基础档案有独立日志表，三者的 last_run_* 为 NULL、计数为 0，属预期；
--     将来切到 job 协议后无需改本函数。
--   - 24h 计数：success 计成功；failed / stalled 计失败；running / partial / cancelled 不计。
--   - 新增 cron 同步任务时，需在 get_auto_sync_overview 的 mapping 里补一行 jobname → sync_type。

create or replace function public.get_auto_sync_overview()
returns table (
  jobname text,
  sync_type text,
  schedule text,
  active boolean,
  last_run_status text,
  last_run_started_at timestamptz,
  last_run_ended_at timestamptz,
  last_run_message text,
  success_count_24h bigint,
  failed_count_24h bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not public.has_ops_role(auth.uid(), 'admin'::public.ops_role_code) then
    raise exception '仅限管理员调用 get_auto_sync_overview' using errcode = '42501';
  end if;

  return query
  with mapping(m_jobname, m_sync_type) as (
    values
      ('jst_sales_orders_15min',          'sales_orders'),
      ('jst_outbound_orders_15min',       'outbound_orders'),
      ('jst_refund_orders_hourly',        'refund_orders'),
      ('jst_aftersale_received_hourly',   'aftersale_received'),
      ('jst_dispatch_base_archive_daily', 'dispatch_base_archive'),
      ('jst_purchase_orders_hourly',      'purchase_orders'),
      ('jst_purchase_inbound_hourly',     'purchase_inbound_orders')
  )
  select
    j.jobname::text,
    m.m_sync_type,
    j.schedule::text,
    j.active,
    lr.status,
    lr.started_at,
    lr.ended_at,
    lr.message,
    coalesce(c.succ, 0),
    coalesce(c.fail, 0)
  from cron.job j
  join mapping m on m.m_jobname = j.jobname::text
  left join lateral (
    select k.status::text, k.started_at, k.ended_at, k.message
    from public.jst_sync_jobs k
    where k.sync_type = m.m_sync_type
      and k.trigger_type = 'cron'
    order by k.started_at desc
    limit 1
  ) lr on true
  left join lateral (
    select
      count(*) filter (where k.status = 'success') as succ,
      count(*) filter (where k.status in ('failed', 'stalled')) as fail
    from public.jst_sync_jobs k
    where k.sync_type = m.m_sync_type
      and k.trigger_type = 'cron'
      and k.started_at >= now() - interval '24 hours'
  ) c on true
  order by j.jobname::text;
end
$fn$;

revoke all on function public.get_auto_sync_overview() from public;
revoke all on function public.get_auto_sync_overview() from anon;
grant execute on function public.get_auto_sync_overview() to authenticated;
grant execute on function public.get_auto_sync_overview() to service_role;

create or replace function public.set_auto_sync_active(p_jobname text, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_prev boolean;
  v_jobid bigint;
begin
  if not public.has_ops_role(v_uid, 'admin'::public.ops_role_code) then
    raise exception '仅限管理员调用 set_auto_sync_active' using errcode = '42501';
  end if;
  if p_active is null then
    raise exception 'p_active 不能为空';
  end if;
  -- 只允许操作 jst_ 前缀的同步任务，避免误停其它系统级 cron 任务
  if p_jobname is null or p_jobname !~ '^jst_' then
    raise exception '仅允许操作 jst_ 前缀的同步任务: %', coalesce(p_jobname, '(null)');
  end if;

  select cj.jobid, cj.active into v_jobid, v_prev
  from cron.job cj where cj.jobname::text = p_jobname;
  if not found then
    raise exception '定时任务不存在: %', p_jobname;
  end if;

  -- Supabase 上 cron.job 表归 supabase_admin 所有，postgres 无直接 UPDATE 权限，
  -- 须经 cron.alter_job 修改（其内部校验调用者 = 任务属主，本库任务均属 postgres）
  perform cron.alter_job(job_id := v_jobid, active := p_active);

  insert into public.audit_logs (user_id, action, details)
  values (
    v_uid,
    'auto_sync_toggle',
    jsonb_build_object(
      'jobname', p_jobname,
      'active', p_active,
      'previous_active', v_prev
    )
  );

  return jsonb_build_object(
    'ok', true,
    'jobname', p_jobname,
    'active', p_active,
    'previous_active', v_prev
  );
end
$fn$;

revoke all on function public.set_auto_sync_active(text, boolean) from public;
revoke all on function public.set_auto_sync_active(text, boolean) from anon;
grant execute on function public.set_auto_sync_active(text, boolean) to authenticated;
grant execute on function public.set_auto_sync_active(text, boolean) to service_role;
