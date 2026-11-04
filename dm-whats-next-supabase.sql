-- [DRAFT — needs human review]
-- DM What's Next? analytics: table, RLS, and reporting views.
-- Run in Supabase SQL editor. Views live in a non-exposed schema so anon can never read them.

create extension if not exists pgcrypto;

-- 1. Events table
create table if not exists public.events (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  session_id       text,
  member_ref       text,          -- HubSpot contact_id only, never PII
  src              text,          -- email | sms | direct
  event            text not null,
  target           text,
  value            numeric,
  device           text,
  viewport_w       int,
  is_return_visit  boolean,
  constraint events_event_len  check (char_length(event) <= 40),
  constraint events_target_len check (target is null or char_length(target) <= 120),
  constraint events_ref_len    check (member_ref is null or char_length(member_ref) <= 64)
);

create index if not exists events_event_idx   on public.events (event);
create index if not exists events_session_idx on public.events (session_id);
create index if not exists events_member_idx  on public.events (member_ref);
create index if not exists events_created_idx on public.events (created_at);

-- 2. RLS: anon can INSERT only
alter table public.events enable row level security;
alter table public.events force row level security;

revoke all on public.events from anon, authenticated;
grant insert on public.events to anon;

drop policy if exists events_anon_insert on public.events;
create policy events_anon_insert on public.events
  for insert to anon
  with check (true);
-- No SELECT / UPDATE / DELETE policies for anon: those operations are denied.

-- 3. Reporting schema (not exposed through the API)
create schema if not exists analytics;
revoke all on schema analytics from anon, authenticated, public;

-- Opens per member_ref
create or replace view analytics.opens_by_member as
select member_ref,
       count(*)                                  as opens,
       count(distinct session_id)                as sessions,
       count(*) filter (where is_return_visit)   as return_opens,
       min(created_at)                           as first_open,
       max(created_at)                           as last_open
from public.events
where event = 'page_open'
group by member_ref;

-- Opens per src
create or replace view analytics.opens_by_src as
select coalesce(src, 'direct')        as src,
       count(*)                       as opens,
       count(distinct session_id)     as sessions,
       count(distinct member_ref)     as members
from public.events
where event = 'page_open'
group by 1;

-- CTR per button: unique sessions clicking target / unique sessions with page_open
create or replace view analytics.button_ctr as
with opens as (
  select count(distinct session_id)::numeric as n from public.events where event = 'page_open'
), clicks as (
  select target, count(distinct session_id) as sessions
  from public.events
  where event = 'click' and target is not null
  group by target
)
select c.target,
       c.sessions                                      as clicking_sessions,
       o.n                                             as open_sessions,
       round(100 * c.sessions / nullif(o.n, 0), 1)     as ctr_pct
from clicks c cross join opens o
order by ctr_pct desc nulls last;

-- Scroll funnel: share of sessions reaching 25/50/75/100
create or replace view analytics.scroll_funnel as
with opens as (
  select count(distinct session_id)::numeric as n from public.events where event = 'page_open'
)
select d.depth,
       count(distinct e.session_id)                                as sessions,
       round(100 * count(distinct e.session_id) / nullif(o.n, 0), 1) as pct_of_opens
from (values (25), (50), (75), (100)) as d(depth)
cross join opens o
left join public.events e
  on e.event = 'scroll_depth' and e.value = d.depth
group by d.depth, o.n
order by d.depth;

-- Answer split (last answer per session) for os_booked and circle_access
create or replace view analytics.answer_split as
with last_answer as (
  select distinct on (session_id, target) session_id, target, value
  from public.events
  where event = 'answer' and target in ('os_booked', 'circle_access')
  order by session_id, target, created_at desc
)
select target,
       count(*) filter (where value = 1)                               as yes,
       count(*) filter (where value = 0)                               as no,
       round(100.0 * count(*) filter (where value = 1) / nullif(count(*), 0), 1) as yes_pct
from last_answer
group by target;

-- Step 0 choice split (last choice per session)
create or replace view analytics.step0_choice_split as
with last_choice as (
  select distinct on (session_id) session_id, target
  from public.events
  where event = 'step0_choice'
  order by session_id, created_at desc
)
select target as choice,
       count(*) as sessions,
       round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1) as pct
from last_choice
group by target;

-- Outbound return rate: returns / outbound clicks (outbound ids start with "out-")
create or replace view analytics.outbound_return_rate as
with clicks as (
  select target, count(*) as clicks
  from public.events
  where event = 'click' and target like 'out-%'
  group by target
), returns as (
  select target, count(*) as returns, round(avg(value), 0) as avg_seconds_away
  from public.events
  where event = 'outbound_return'
  group by target
)
select c.target,
       c.clicks,
       coalesce(r.returns, 0)                                   as returns,
       round(100.0 * coalesce(r.returns, 0) / nullif(c.clicks, 0), 1) as return_rate_pct,
       r.avg_seconds_away
from clicks c left join returns r using (target)
order by c.clicks desc;

revoke all on all tables in schema analytics from anon, authenticated, public;

-- =====================================================================
-- 4. Admin console (logo tapped 5 times on the page)
-- Re-run this whole section after updates: admin_dashboard is create or replace.
-- The passcode lives ONLY here, hashed with bcrypt. It is never in the page source.
-- The page calls admin_dashboard(passcode) with the anon key; the function checks the hash server side.
-- =====================================================================

create table if not exists public.admin_secrets (
  id             int primary key default 1 check (id = 1),
  passcode_hash  text not null,
  updated_at     timestamptz not null default now()
);
alter table public.admin_secrets enable row level security;
alter table public.admin_secrets force row level security;
revoke all on public.admin_secrets from anon, authenticated, public;
-- No policies: nothing can read this table through the API.

-- Set or change the passcode. Run this yourself in the SQL editor (do not save it in shared files):
--   insert into public.admin_secrets (id, passcode_hash)
--   values (1, extensions.crypt('[YOUR_PASSCODE]', extensions.gen_salt('bf', 10)))
--   on conflict (id) do update set passcode_hash = excluded.passcode_hash, updated_at = now();

create or replace function public.admin_dashboard(p_passcode text, p_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  h      text;
  since  timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
  result jsonb;
begin
  select passcode_hash into h from public.admin_secrets where id = 1;
  if h is null or p_passcode is null or crypt(p_passcode, h) <> h then
    perform pg_sleep(1);                         -- slow down guessing
    raise exception 'invalid passcode' using errcode = '28P01';
  end if;

  with e as (
    select * from public.events where created_at >= since
  ),
  opens as (select * from e where event = 'page_open')
  select jsonb_build_object(
    'generated_at', now(),
    'days', p_days,
    'totals', (
      select jsonb_build_object(
        'opens',        (select count(*) from opens),
        'sessions',     (select count(distinct session_id) from opens),
        'members',      (select count(distinct member_ref) from opens where member_ref is not null and member_ref <> 'anon'),
        'return_opens', (select count(*) from opens where is_return_visit),
        'avg_time_s',   (select round(avg(value)) from e where event = 'time_on_page')
      )
    ),
    'by_src', coalesce((
      select jsonb_agg(jsonb_build_object('src', src, 'sessions', n) order by n desc)
      from (select coalesce(src, 'direct') as src, count(distinct session_id) as n from opens group by 1) x
    ), '[]'::jsonb),
    'by_device', coalesce((
      select jsonb_agg(jsonb_build_object('device', device, 'sessions', n) order by n desc)
      from (select coalesce(device, 'unknown') as device, count(distinct session_id) as n from opens group by 1) x
    ), '[]'::jsonb),
    'chat', (
      select jsonb_build_object(
        'opened', count(*) filter (where event = 'chat_open'),
        'asked',  count(*) filter (where event = 'chat_message'),
        'ai',     count(*) filter (where event = 'chat_message' and target in ('api', 'sample')),
        'faq',    count(*) filter (where event = 'chat_message' and target = 'faq'),
        'menu',   count(*) filter (where event = 'menu_open'))
      from e
    ),
    'save', (
      select jsonb_build_object(
        'opened', count(*) filter (where event = 'save_action' and target like 'open_%'),
        'share',  count(*) filter (where event = 'save_action' and target = 'share'),
        'copy',   count(*) filter (where event = 'save_action' and target = 'copy'),
        'email',  count(*) filter (where event = 'save_action' and target like 'email%'))
      from e
    ),
    'device_pop', (
      select jsonb_build_object(
        'shown',  count(*) filter (where event = 'device_banner_shown'),
        'manual', count(*) filter (where event = 'device_banner_dismissed' and target = 'manual'),
        'auto',   count(*) filter (where event = 'device_banner_dismissed' and target = 'auto'),
        'copied', count(*) filter (where event = 'device_link_copied'))
      from e
    ),
    'funnel', (
      select jsonb_agg(jsonb_build_object('depth', d,
               'sessions', (select count(distinct session_id) from e where event = 'scroll_depth' and value = d)) order by d)
      from unnest(array[25, 50, 75, 100]) as d
    ),
    'answers', jsonb_build_object(
      'os_booked',     (select jsonb_build_object('yes', count(*) filter (where value = 1), 'no', count(*) filter (where value = 0))
                        from (select distinct on (session_id) value from e where event = 'answer' and target = 'os_booked' order by session_id, created_at desc) a),
      'circle_access', (select jsonb_build_object('yes', count(*) filter (where value = 1), 'no', count(*) filter (where value = 0))
                        from (select distinct on (session_id) value from e where event = 'answer' and target = 'circle_access' order by session_id, created_at desc) a)
    ),
    'step0', coalesce((
      select jsonb_object_agg(target, n)
      from (select target, count(*) as n
            from (select distinct on (session_id) target from e where event = 'step0_choice' order by session_id, created_at desc) lc
            group by target) s
    ), '{}'::jsonb),
    'ctr', coalesce((
      select jsonb_agg(jsonb_build_object('target', target, 'sessions', n) order by n desc)
      from (select target, count(distinct session_id) as n from e where event = 'click' and target is not null group by target) c
    ), '[]'::jsonb),
    'outbound', coalesce((
      select jsonb_agg(jsonb_build_object('target', c.target, 'clicks', c.n, 'returns', coalesce(r.n, 0), 'avg_seconds_away', r.s) order by c.n desc)
      from (select target, count(*) as n from e where event = 'click' and target like 'out-%' group by target) c
      left join (select target, count(*) as n, round(avg(value)) as s from e where event = 'outbound_return' group by target) r using (target)
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.last_open desc nulls last)
      from (
        select member_ref,
               count(*) filter (where event = 'page_open')                                                         as opens,
               max(created_at) filter (where event = 'page_open')                                                  as last_open,
               max(value) filter (where event = 'scroll_depth')                                                    as max_scroll,
               (array_agg(src    order by created_at desc) filter (where event = 'page_open'))[1]                  as src,
               (array_agg(device order by created_at desc) filter (where event = 'page_open'))[1]                  as device,
               (array_agg(value  order by created_at desc) filter (where event = 'answer' and target = 'os_booked'))[1]     as os_booked,
               (array_agg(value  order by created_at desc) filter (where event = 'answer' and target = 'circle_access'))[1] as circle_access,
               (array_agg(target order by created_at desc) filter (where event = 'step0_choice'))[1]               as step0
        from e
        where member_ref is not null and member_ref <> 'anon'
        group by member_ref
        order by max(created_at) desc
        limit 300
      ) m
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.admin_dashboard(text, int) from public;
grant execute on function public.admin_dashboard(text, int) to anon;
