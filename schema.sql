-- Supabase schema for Copa 2026 album.
-- Re-runnable: safe to apply repeatedly.
-- Run in: Supabase > SQL Editor.

create extension if not exists pgcrypto;

-- ===================== STICKERS TABLE =====================
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

drop policy if exists "anon read"   on sticker_cells;
drop policy if exists "anon insert" on sticker_cells;
drop policy if exists "anon update" on sticker_cells;
drop policy if exists "anon delete" on sticker_cells;
create policy "anon read" on sticker_cells for select using (true);
-- Writes go through SECURITY DEFINER functions only (so we can enforce password).

-- ===================== LOCKS TABLE =====================
create table if not exists album_locks (
  user_code     text primary key,
  password_hash text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table album_locks enable row level security;

drop policy if exists "anon read locks" on album_locks;
create policy "anon read locks" on album_locks for select using (true);
-- Modifications go through set_album_password() only.

-- ===================== FUNCTIONS =====================
create or replace function set_album_password(
  p_code text,
  p_new_password text,
  p_current_password text default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_existing text;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    raise exception 'invalid_code' using errcode = 'P0001';
  end if;
  select password_hash into v_existing from album_locks where user_code = p_code;
  if v_existing is not null then
    if p_current_password is null
       or crypt(p_current_password, v_existing) <> v_existing then
      raise exception 'wrong_password' using errcode = 'P0001';
    end if;
  end if;
  if p_new_password is null or p_new_password = '' then
    delete from album_locks where user_code = p_code;
  else
    insert into album_locks(user_code, password_hash)
    values (p_code, crypt(p_new_password, gen_salt('bf', 10)))
    on conflict (user_code) do update
    set password_hash = excluded.password_hash, updated_at = now();
  end if;
end $$;

create or replace function verify_album_password(p_code text, p_password text)
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_hash text;
begin
  select password_hash into v_hash from album_locks where user_code = p_code;
  if v_hash is null then return true; end if;
  if p_password is null then return false; end if;
  return crypt(p_password, v_hash) = v_hash;
end $$;

create or replace function set_cell(
  p_code text, p_section text, p_number int,
  p_have boolean, p_dups int, p_password text default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_hash text;
begin
  select password_hash into v_hash from album_locks where user_code = p_code;
  if v_hash is not null
     and (p_password is null or crypt(p_password, v_hash) <> v_hash) then
    raise exception 'wrong_password' using errcode = 'P0001';
  end if;
  insert into sticker_cells(user_code, section_code, number, have, dups)
  values (p_code, p_section, p_number, coalesce(p_have, false), coalesce(p_dups, 0))
  on conflict (user_code, section_code, number) do update
  set have = excluded.have, dups = excluded.dups, updated_at = now();
end $$;

create or replace function set_cells_bulk(
  p_code text, p_cells jsonb, p_password text default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_hash text;
begin
  select password_hash into v_hash from album_locks where user_code = p_code;
  if v_hash is not null
     and (p_password is null or crypt(p_password, v_hash) <> v_hash) then
    raise exception 'wrong_password' using errcode = 'P0001';
  end if;
  insert into sticker_cells(user_code, section_code, number, have, dups)
  select p_code,
         (e->>'section_code')::text,
         (e->>'number')::int,
         coalesce((e->>'have')::boolean, false),
         coalesce((e->>'dups')::int, 0)
  from jsonb_array_elements(p_cells) as e
  on conflict (user_code, section_code, number) do update
  set have = excluded.have, dups = excluded.dups, updated_at = now();
end $$;

create or replace function clear_album(p_code text, p_password text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_hash text;
begin
  select password_hash into v_hash from album_locks where user_code = p_code;
  if v_hash is not null
     and (p_password is null or crypt(p_password, v_hash) <> v_hash) then
    raise exception 'wrong_password' using errcode = 'P0001';
  end if;
  delete from sticker_cells where user_code = p_code;
end $$;

grant execute on function set_album_password(text, text, text) to anon, authenticated;
grant execute on function verify_album_password(text, text) to anon, authenticated;
grant execute on function set_cell(text, text, int, boolean, int, text) to anon, authenticated;
grant execute on function set_cells_bulk(text, jsonb, text) to anon, authenticated;
grant execute on function clear_album(text, text) to anon, authenticated;

-- ===================== REALTIME =====================
do $$ begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if found then
    begin
      alter publication supabase_realtime add table sticker_cells;
    exception when duplicate_object then null;
    end;
  end if;
end $$;
