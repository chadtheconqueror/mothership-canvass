-- Mothership Canvass, 11/9/2026. Approved by Chad. Removes public access; deletes no data.
-- Applied in the Supabase SQL editor on 11/9/2026.
drop policy if exists "Allow anon read" on public.kv_store;
drop policy if exists "Allow anon write" on public.kv_store;
drop policy if exists "Allow anon update" on public.kv_store;
drop policy if exists "Public read access" on public.jobnimbus_notifications;
alter table public.kv_store enable row level security;
alter table public.jobnimbus_notifications enable row level security;
