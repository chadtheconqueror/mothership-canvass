-- Mothership Canvass, 11/9/2026 ("Now" items 2 and 3). Applying this migration adds functions and an index;
-- it changes and deletes no data.
-- The live site does not call these yet, so it keeps working exactly as before.

-- 1) Save a new door and its first visit together: both are saved or neither is.
--    Runs as the signed-in person, so the existing access rules still apply.
create or replace function public.log_new_door(
  p_lat double precision,
  p_lng double precision,
  p_address text,
  p_status text,
  p_notes text default ''
) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  d_id text;
  v record;
begin
  if not public.is_member() then
    raise exception 'Your account is not turned on.' using errcode = '42501';
  end if;
  insert into public.doors(lat, lng, address)
  values (p_lat, p_lng, coalesce(nullif(trim(p_address), ''), 'Dropped pin'))
  returning id into d_id;
  insert into public.visits(door_id, member_id, status, notes)
  values (d_id, auth.uid(), p_status, coalesce(p_notes, ''))
  returning id, visited_at into v;
  return jsonb_build_object('door_id', d_id, 'visit_id', v.id, 'visited_at', v.visited_at);
end $$;

revoke execute on function public.log_new_door(double precision, double precision, text, text, text) from public, anon;
grant execute on function public.log_new_door(double precision, double precision, text, text, text) to authenticated;

-- 2) Re-importing a hail list updates homes in place instead of deleting and re-adding them,
--    so each home's map location (lat, lng, geo_status) survives. One area per call, all or nothing.
--    A home is the same home when its street and address match.
create unique index if not exists homes_street_address_uidx on public.homes(street_id, address);

create or replace function public.hail_rows(p_rows jsonb, p_street_ids bigint[])
returns table(street_id bigint, address text, storm_dates text, hail numeric, built text, roof_sq int, owner text)
language sql immutable set search_path = public as $$
  select p_street_ids[(r->>0)::int + 1], r->>1, coalesce(r->>2, ''), (r->>3)::numeric,
         coalesce(r->>4, ''), (r->>5)::int, coalesce(r->>6, '')
  from jsonb_array_elements(p_rows) as t(r)
$$;

create or replace function public.import_hail_area(p_area jsonb) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  nb_id text := p_area->>'id';
  street_ids bigint[];
  n_new int := 0;
  n_updated int := 0;
  n_removed int := 0;
begin
  if not public.is_manager() then
    raise exception 'Only an admin or dispatcher can import hail lists.' using errcode = '42501';
  end if;
  if nb_id is null or jsonb_typeof(p_area->'streets') <> 'array' or jsonb_typeof(p_area->'homeRows') <> 'array' then
    raise exception 'That is not a hail list area.';
  end if;

  insert into public.neighborhoods(id, name, homes, storms, max_hail, center, lat, lng, cities, imported_at)
  values (nb_id, p_area->>'name', coalesce((p_area->>'homes')::int, 0), coalesce(p_area->'storms', '[]'::jsonb),
          (p_area->>'max')::numeric, p_area->>'center', (p_area->>'lat')::float8, (p_area->>'lng')::float8,
          coalesce(array(select jsonb_array_elements_text(p_area->'cities')), '{}'), now())
  on conflict (id) do update set name = excluded.name, homes = excluded.homes, storms = excluded.storms,
    max_hail = excluded.max_hail, center = excluded.center, lat = excluded.lat, lng = excluded.lng,
    cities = excluded.cities, imported_at = excluded.imported_at;

  -- streets in file order; street_ids[i] is the id for the file's street i (0-based in the file)
  with s as (
    select ord, e->>0 as name, coalesce(e->>1, '') as city, coalesce(e->>2, '') as zip,
           coalesce((e->>3)::int, 0) as homes, (e->>4)::numeric as max_hail
    from jsonb_array_elements(p_area->'streets') with ordinality as t(e, ord)
  ), up as (
    insert into public.streets(neighborhood_id, name, city, zip, homes, max_hail)
    select nb_id, name, city, zip, homes, max_hail from s
    on conflict (neighborhood_id, name, city, zip) do update set homes = excluded.homes, max_hail = excluded.max_hail
    returning id, name, city, zip
  )
  select array_agg(up.id order by s.ord) into street_ids
  from s join up on up.name = s.name and up.city = s.city and up.zip = s.zip;

  -- the file's homes as rows: (street_id, address, ...)
  update public.homes h
     set storm_dates = r.storm_dates, hail = r.hail, built = r.built, roof_sq = r.roof_sq,
         owner = r.owner, neighborhood_id = nb_id
    from public.hail_rows(p_area->'homeRows', street_ids) r
   where h.street_id = r.street_id and h.address = r.address;
  get diagnostics n_updated = row_count;

  insert into public.homes(street_id, neighborhood_id, address, storm_dates, hail, built, roof_sq, owner)
  select r.street_id, nb_id, r.address, r.storm_dates, r.hail, r.built, r.roof_sq, r.owner
    from public.hail_rows(p_area->'homeRows', street_ids) r
   where r.street_id is not null
  on conflict (street_id, address) do nothing;
  get diagnostics n_new = row_count;

  -- homes on these streets that are no longer on the list (the same result the old import gave)
  delete from public.homes h
   where h.street_id = any(street_ids)
     and not exists (select 1 from public.hail_rows(p_area->'homeRows', street_ids) r
                      where r.street_id = h.street_id and r.address = h.address);
  get diagnostics n_removed = row_count;

  return jsonb_build_object('updated', n_updated, 'added', n_new, 'removed', n_removed);
end $$;

revoke execute on function public.import_hail_area(jsonb) from public, anon;
grant execute on function public.import_hail_area(jsonb) to authenticated;
