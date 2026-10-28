-- =============================================================================
-- テスト専用ヘルパー(本番には適用しない。migrations 適用後・tests 実行前に流す)
--   * private.app_now() を差し替え: GUC app.test_now があればそれを「現在時刻」とする
--     (本番の migration 版は now() 固定。ここでテスト時のみ上書きする)
--   * tests スキーマ: ロール切替(become*)、アサーション(ok/eq/throws/cnt)、フィクスチャ
--   結果は NOTICE 'WBTEST PASS|FAIL|<名前>' で出力(トランザクションがロールバックされても集計できる)
-- =============================================================================

create or replace function private.app_now()
returns timestamptz
language sql
stable
as $$
  select coalesce(nullif(current_setting('app.test_now', true), '')::timestamptz, now())
$$;

drop schema if exists tests cascade;
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

-- ---- アサーション ---------------------------------------------------------------
create function tests.ok(p_name text, p_cond boolean) returns void
language plpgsql as $$
begin
  if p_cond is true then
    raise notice 'WBTEST PASS|%', p_name;
  else
    raise notice 'WBTEST FAIL|%', p_name;
  end if;
end $$;

create function tests.eq(p_name text, p_actual anyelement, p_expected anyelement) returns void
language plpgsql as $$
begin
  if p_actual is not distinct from p_expected then
    raise notice 'WBTEST PASS|%', p_name;
  else
    raise notice 'WBTEST FAIL|% (actual=%, expected=%)', p_name, p_actual, p_expected;
  end if;
end $$;

-- 現在のロールで SQL を実行して行数を返す
create function tests.cnt(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  return n;
end $$;

-- DML を現在のロールで実行し、影響行数を返す
create function tests.affected(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- 現在のロールで SQL を実行し、先頭列(text)を返す
create function tests.scalar(p_sql text) returns text
language plpgsql as $$
declare r text;
begin
  execute 'select (' || p_sql || ')::text' into r;
  return r;
end $$;

-- 現在のロールで SQL を実行し、指定の SQLSTATE で失敗することを確認(p_state が NULL なら「何らかのエラー」)
create function tests.throws(p_name text, p_sql text, p_state text default null) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
    raise notice 'WBTEST FAIL|% (エラーにならなかった)', p_name;
    return;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if p_state is null or v_state = p_state then
    raise notice 'WBTEST PASS|%', p_name;
  else
    raise notice 'WBTEST FAIL|% (state=%, expected=%, msg=%)', p_name, v_state, p_state, v_msg;
  end if;
end $$;

-- エラーにならず成功することを確認
create function tests.lives(p_name text, p_sql text) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    raise notice 'WBTEST FAIL|% (state=%, msg=%)', p_name, v_state, v_msg;
    return;
  end;
  raise notice 'WBTEST PASS|%', p_name;
end $$;

-- エラーメッセージ(MESSAGE_TEXT)を返す。成功したら NULL。
create function tests.errmsg(p_sql text) returns text
language plpgsql as $$
declare v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    return v_msg;
  end;
  return null;
end $$;

create function tests.errstate(p_sql text) returns text
language plpgsql as $$
declare v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    return v_state;
  end;
  return null;
end $$;

-- 実行して成功したら 'ok'、失敗したら SQLSTATE を返す。どちらの場合も副作用は取り消す(サブトランザクションをロールバック)。
create function tests.try_rollback(p_sql text) returns text
language plpgsql as $$
declare v_state text;
begin
  begin
    execute p_sql;
    raise exception 'tests-rollback' using errcode = 'WBZ99';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  return case when v_state = 'WBZ99' then 'ok' else v_state end;
end $$;

-- ---- ロール/ユーザー切替 ------------------------------------------------------------
create function tests.uid(p_name text) returns uuid
language sql immutable as $$
  select md5('wbtest:' || p_name)::uuid
$$;

create function tests.become_super() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', '', false);
end $$;

create function tests.become(p_name text) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', tests.uid(p_name)::text, false);
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(p_name), 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;

create function tests.become_anon() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, false);
  set role anon;
end $$;

create function tests.become_service() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, false);
  set role service_role;
end $$;

-- 認証済みだがユーザー指定なし(sub 無し)のケース
create function tests.become_authenticated_no_sub() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, false);
  set role authenticated;
end $$;

-- ---- 時刻 ------------------------------------------------------------------------
-- JST の 'YYYY-MM-DD HH24:MI' で「現在」を固定
create function tests.set_now_jst(p_ts text) returns void
language plpgsql as $$
begin
  perform set_config('app.test_now', ((p_ts || ' Asia/Tokyo')::timestamptz)::text, false);
end $$;

create function tests.clear_now() returns void
language plpgsql as $$
begin
  perform set_config('app.test_now', '', false);
end $$;

create function tests.jst(p_ts text) returns timestamptz
language sql immutable as $$
  select (p_ts || ' Asia/Tokyo')::timestamptz
$$;

-- ---- フィクスチャ(superuser で呼ぶ) ----------------------------------------------------
-- ユーザー(auth.users + profiles(+profile_settings) + 犬1頭)を作る。visibility は 'friends' 既定。
create function tests.mkuser(p_name text, p_vis_owner text default 'friends', p_vis_dog text default 'friends')
returns uuid
language plpgsql as $$
declare
  v_id uuid := tests.uid(p_name);
begin
  insert into auth.users (id, email) values (v_id, p_name || '@example.test');
  insert into public.profiles (id, nickname, visibility_owner) values (v_id, p_name, p_vis_owner);
  insert into public.dogs (id, owner_id, name, visibility_dog)
  values (tests.dog_uid(p_name, 1), v_id, p_name || '-dog1', p_vis_dog);
  return v_id;
end $$;

create function tests.dog_uid(p_name text, p_n int) returns uuid
language sql immutable as $$
  select md5('wbtest-dog:' || p_name || ':' || p_n)::uuid
$$;

create function tests.mkdog(p_name text, p_n int, p_vis text default 'friends') returns uuid
language plpgsql as $$
begin
  insert into public.dogs (id, owner_id, name, visibility_dog)
  values (tests.dog_uid(p_name, p_n), tests.uid(p_name), p_name || '-dog' || p_n, p_vis);
  return tests.dog_uid(p_name, p_n);
end $$;

create function tests.befriend(p_a text, p_b text) returns void
language plpgsql as $$
begin
  insert into public.friendships (requester_id, addressee_id, status, method, responded_at)
  values (tests.uid(p_a), tests.uid(p_b), 'accepted', 'request', now());
end $$;

create function tests.block(p_blocker text, p_blocked text) returns void
language plpgsql as $$
begin
  insert into public.blocks (blocker_id, blocked_id) values (tests.uid(p_blocker), tests.uid(p_blocked));
end $$;

-- 他人の招待コード/ユーザーIDを(RLSに関係なく)取得するテスト用ヘルパー(security definer)
create function tests.icode(p_name text) returns text
language sql stable security definer set search_path = '' as $$
  select s.invite_code from public.profile_settings s where s.user_id = tests.uid(p_name)
$$;
create function tests.ucode(p_name text) returns text
language sql stable security definer set search_path = '' as $$
  select p.user_code from public.profiles p where p.id = tests.uid(p_name)
$$;

create function tests.facility() returns uuid
language sql stable as $$
  select id from public.facilities where code = 'tatsumi-no-mori-dogrun'
$$;

grant execute on all functions in schema tests to public;
