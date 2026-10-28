-- =============================================================================
-- WanBuddy v0.2 / M2  03: 判定用関数(PRD 7.2-6)
--   すべて security definer + search_path 固定(空)。参照オブジェクトは全てスキーマ修飾。
--   private スキーマに置く = PostgREST(RPC)経由では呼べない。
--   念のため「呼び出し元(auth.uid())と無関係なユーザー間の関係」を問い合わせても false を返すガードを入れる
--   (友達関係/ブロック関係の探索に悪用されないように)。
-- =============================================================================

-- ブロック関係(どちらか)。RLSポリシーからは直接呼ばない(can_view/RPC内部専用)。クライアントに EXECUTE を与えない。
create function private.is_blocked_either(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when a is null or b is null then true      -- 不明な相手は「ブロック扱い」(安全側)
    else exists (
      select 1
      from public.blocks bl
      where (bl.blocker_id = a and bl.blocked_id = b)
         or (bl.blocker_id = b and bl.blocked_id = a)
    )
  end
$$;
revoke all on function private.is_blocked_either(uuid, uuid) from public, anon, authenticated;

-- 友達(accepted)かつブロック関係なし。呼び出し元が a/b のどちらかでなければ false。
create function private.is_friend(a uuid, b uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
begin
  if a is null or b is null or a = b then
    return false;
  end if;
  if v_caller is not null and v_caller not in (a, b) then
    return false;
  end if;
  if private.is_blocked_either(a, b) then
    return false;
  end if;
  return exists (
    select 1
    from public.friendships f
    where f.status = 'accepted'
      and ((f.requester_id = a and f.addressee_id = b)
        or (f.requester_id = b and f.addressee_id = a))
  );
end $$;
revoke all on function private.is_friend(uuid, uuid) from public, anon;
grant execute on function private.is_friend(uuid, uuid) to authenticated, service_role;

-- 閲覧可否(7.2 閲覧マトリクス)
--   本人: 常に○ / ブロック関係(どちらか): 常に× / public: ○ / friends: 友達のみ / private・不明な値: ×
--   viewer が呼び出し元(auth.uid())と異なる場合は false(他人の視点での探索を防ぐ)。
create function private.can_view(viewer uuid, owner uuid, visibility text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
begin
  if viewer is null or owner is null then
    return false;
  end if;
  if v_caller is not null and viewer is distinct from v_caller then
    return false;
  end if;
  if viewer = owner then
    return true;
  end if;
  if private.is_blocked_either(viewer, owner) then
    return false;
  end if;
  if visibility = 'public' then
    return true;
  elsif visibility = 'friends' then
    return private.is_friend(viewer, owner);
  end if;
  return false;
end $$;
revoke all on function private.can_view(uuid, uuid, text) from public, anon;
grant execute on function private.can_view(uuid, uuid, text) to authenticated, service_role;

-- 友達数(accepted。双方向)。内部専用。
create function private.friend_count(p_uid uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.friendships f
  where f.status = 'accepted' and (f.requester_id = p_uid or f.addressee_id = p_uid)
$$;
revoke all on function private.friend_count(uuid) from public, anon, authenticated;

-- 施設の「ローカル日付の閉園時刻」と「開園時間内か」
create function private.facility_close_at(p_tz text, p_close time, p_t timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select ((p_t at time zone p_tz)::date + p_close) at time zone p_tz
$$;
revoke all on function private.facility_close_at(text, time, timestamptz) from public, anon, authenticated;

create function private.facility_is_open_at(p_tz text, p_open time, p_close time, p_t timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (p_t at time zone p_tz)::time >= p_open and (p_t at time zone p_tz)::time < p_close
$$;
revoke all on function private.facility_is_open_at(text, time, time, timestamptz) from public, anon, authenticated;
