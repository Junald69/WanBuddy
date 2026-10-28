-- =============================================================================
-- Supabase 互換スタブ(ローカルPostgreSQL検証専用。migrations 本体には含めない)
--   ・roles: anon / authenticated / service_role (+ authenticator)
--   ・auth.users, auth.uid(), auth.role(), auth.jwt()
--   ・storage.buckets / storage.objects / storage.foldername() 等
--   ・本プロジェクトの Supabase 設定を再現: 「新規テーブルの自動公開(auto expose)=OFF」
--     =新規テーブル/関数/シーケンスに anon/authenticated への権限が【自動付与されない】
--     (ALTER DEFAULT PRIVILEGES を設定しない)。必要な GRANT は migrations で明示する。
--   ・「自動RLS=ON」: public に新規テーブルを作ると自動で RLS が有効になる(event trigger)。
--     ※ migrations 側でも明示的に enable row level security する(設定に依存しない)。
--   ・(任意) 01_legacy_default_privileges.sql: 旧来の Supabase(自動付与あり)を再現するストレステスト用。
-- 本番(Supabase)では上記はすべて既に存在するため、このファイルは実行しない。
-- =============================================================================

-- ロール(Supabase と同じ属性)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login;
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- ---- auth ------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Supabase の auth.uid() と同じ実装
create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt() to anon, authenticated, service_role;

-- ---- storage ---------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  owner_id text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;

-- Supabase と同様、storage の表は anon/authenticated に権限が付いていて RLS ポリシーで制御される
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;

create or replace function storage.foldername(name text) returns text[]
language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $$;

create or replace function storage.filename(name text) returns text
language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[array_length(_parts, 1)];
end $$;

create or replace function storage.extension(name text) returns text
language plpgsql immutable as $$
declare _parts text[]; _filename text;
begin
  select string_to_array(name, '/') into _parts;
  select _parts[array_length(_parts, 1)] into _filename;
  return reverse(split_part(reverse(_filename), '.', 1));
end $$;

grant execute on function storage.foldername(text), storage.filename(text), storage.extension(text)
  to anon, authenticated, service_role;

-- ---- public スキーマ: USAGE のみ(デフォルト権限は付与しない = auto expose OFF) -----------
grant usage on schema public to anon, authenticated, service_role;

-- ---- 自動RLS(新規テーブルは RLS 有効で作られる) ----------------------------------------
create or replace function extensions.zz_auto_enable_rls() returns event_trigger
language plpgsql as $$
declare cmd record;
begin
  for cmd in select * from pg_event_trigger_ddl_commands() where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  loop
    if cmd.schema_name = 'public' and cmd.object_type in ('table', 'partitioned table') then
      execute format('alter table %s enable row level security', cmd.object_identity);
    end if;
  end loop;
end $$;
drop event trigger if exists zz_auto_rls;
create event trigger zz_auto_rls on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function extensions.zz_auto_enable_rls();
