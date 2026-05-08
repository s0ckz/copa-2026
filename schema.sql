-- Supabase schema for Copa 2026 album.
-- Run this once in Supabase > SQL Editor (https://supabase.com/dashboard/project/_/sql).
-- Per-user collections: each visitor uses a unique `user_code` (passed in the URL).

create table if not exists sticker_cells (
  user_code     text   not null,
  section_code  text   not null,
  number        int    not null,
  have          boolean not null default false,
  dups          int    not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (user_code, section_code, number)
);

create index if not exists sticker_cells_user_idx on sticker_cells (user_code);

alter table sticker_cells enable row level security;

drop policy if exists "anon read" on sticker_cells;
drop policy if exists "anon insert" on sticker_cells;
drop policy if exists "anon update" on sticker_cells;
drop policy if exists "anon delete" on sticker_cells;

create policy "anon read"   on sticker_cells for select using (true);
create policy "anon insert" on sticker_cells for insert with check (true);
create policy "anon update" on sticker_cells for update using (true) with check (true);
create policy "anon delete" on sticker_cells for delete using (true);

-- Realtime: required so other devices see edits live.
do $$ begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if found then
    begin
      alter publication supabase_realtime add table sticker_cells;
    exception when duplicate_object then null;
    end;
  end if;
end $$;
