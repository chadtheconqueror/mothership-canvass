-- Mothership Canvass, 11/9/2026 ("Next" items 9-11). Adds columns and one function; changes and deletes no data.
-- The live site keeps working: it never reads or writes these new columns.
-- Applied in the Supabase SQL editor on 11/9/2026.

-- 9) Each door can point at its home on the hail list.
alter table public.doors add column if not exists home_id bigint references public.homes(id) on delete set null;
create index if not exists doors_home_idx on public.doors(home_id);

-- 11) Lead card on a visit: who, how to reach them, when, and which PM.
--     follow_at is the appointment time (Appointment) or the call-back time (Callback).
alter table public.visits add column if not exists homeowner_name text not null default '';
alter table public.visits add column if not exists phone text not null default '';
alter table public.visits add column if not exists email text not null default '';
alter table public.visits add column if not exists follow_at timestamptz;
alter table public.visits add column if not exists lead_pm text not null default '';

-- 9 + 10 + 11) Log a visit in one step: to an existing door (door_id given), or to a new door
--     (optionally linked to a hail-list home). Door and visit are saved together or not at all.
create or replace function public.log_door_visit(p jsonb) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  d_id text := nullif(p->>'door_id', '');
  made boolean := false;
  v record;
begin
  if not public.is_member() then
    raise exception 'Your account is not turned on.' using errcode = '42501';
  end if;
  if d_id is null then
    insert into public.doors(lat, lng, address, home_id)
    values ((p->>'lat')::float8, (p->>'lng')::float8,
            coalesce(nullif(trim(p->>'address'), ''), 'Dropped pin'),
            nullif(p->>'home_id', '')::bigint)
    returning id into d_id;
    made := true;
  end if;
  insert into public.visits(door_id, member_id, status, notes, homeowner_name, phone, email, follow_at, lead_pm)
  values (d_id, auth.uid(), p->>'status', coalesce(p->>'notes', ''),
          coalesce(p->>'homeowner_name', ''), coalesce(p->>'phone', ''), coalesce(p->>'email', ''),
          nullif(p->>'follow_at', '')::timestamptz, coalesce(p->>'lead_pm', ''))
  returning id, visited_at into v;
  -- an existing door logged from the hail list gets linked to that home (only if it had no link yet)
  if not made and nullif(p->>'home_id', '') is not null then
    update public.doors set home_id = (p->>'home_id')::bigint where id = d_id and home_id is null;
  end if;
  return jsonb_build_object('door_id', d_id, 'visit_id', v.id, 'visited_at', v.visited_at, 'new_door', made);
end $$;

revoke execute on function public.log_door_visit(jsonb) from public, anon;
grant execute on function public.log_door_visit(jsonb) to authenticated;
