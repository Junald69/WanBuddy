-- =============================================================================
-- WanBuddy v0.2 / M2  06: RPC(友達・QR・招待コード・ID検索)
--   すべて security definer / search_path 固定 / anon・PUBLIC から EXECUTE 剥奪 / authenticated のみ許可。
--   エラーコード(SQLSTATE。クライアントは code で分岐する):
--     WB401 未ログイン / WB402 プロフィール未作成
--     WB001 汎用拒否「このQRコードは使用できません」(期限切れ・失効・回数超過・ブロック・受付OFF・相手の上限 を区別しない)
--     WB002 自分自身 / WB003 既に友達 / WB004 1日の登録上限 / WB005 自分の友達上限
--     WB006 申請済み / WB007 QR受付OFF(自分のQR発行時) / WB009 承認不可(相手側が上限)
--     WB011 汎用拒否「コードが見つかりません」(存在しない・検索OFF・ブロック を区別しない)
--     WB013 この相手には申請できません(拒否済み) / WB014 未承認の申請が多すぎる / WB015 申請が見つかりません
-- =============================================================================

-- 認証済み+プロフィール作成済みを確認し uid を返す(プロフィール行をロックして同一ユーザーの操作を直列化)
create function private.require_profile()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'ログインが必要です' using errcode = 'WB401';
  end if;
  perform 1 from public.profiles p where p.id = v_uid for update;
  if not found then
    raise exception 'プロフィールを作成してください' using errcode = 'WB402';
  end if;
  return v_uid;
end $$;
revoke all on function private.require_profile() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- QR発行(再生成)。旧トークンは即失効(= F2を開いた/自動更新/手動再生成)。
-- ---------------------------------------------------------------------------
create function public.issue_qr_token()
returns table (qr_token text, qr_expires_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := private.require_profile();
  v_now   timestamptz := private.app_now();
  v_token text;
  v_exp   timestamptz;
begin
  if not exists (select 1 from public.profile_settings s where s.user_id = v_uid and s.accept_qr) then
    raise exception 'QRでの友達登録を受け付けない設定になっています' using errcode = 'WB007';
  end if;

  update public.qr_tokens t set revoked_at = v_now
   where t.user_id = v_uid and t.revoked_at is null;

  -- 122bit x 2 のランダム(gen_random_uuid は暗号論的乱数)。DBには sha256 のみ保存。
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_exp := v_now + make_interval(mins => private.config_int('qr_ttl_minutes'));

  insert into public.qr_tokens (user_id, token_hash, expires_at, max_uses, created_at)
  values (v_uid, sha256(convert_to(v_token, 'UTF8')), v_exp, private.config_int('qr_max_uses'), v_now);

  return query select v_token, v_exp;
end $$;
revoke all on function public.issue_qr_token() from public, anon;
grant execute on function public.issue_qr_token() to authenticated;

-- QR失効(F2を閉じたとき)。失効した件数を返す。
create function public.revoke_qr_tokens()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_profile();
  v_n   integer;
begin
  update public.qr_tokens t set revoked_at = private.app_now()
   where t.user_id = v_uid and t.revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.revoke_qr_tokens() from public, anon;
grant execute on function public.revoke_qr_tokens() to authenticated;

-- ---------------------------------------------------------------------------
-- QR読み取り(自動承認)。読み取った側(呼び出し元)が requester、QR表示側が addressee。
-- ---------------------------------------------------------------------------
create function public.redeem_qr_token(p_token text)
returns table (friendship_id uuid, friend_id uuid, friend_nickname text, friend_avatar_path text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := private.require_profile();
  v_now   timestamptz := private.app_now();
  v_tok   public.qr_tokens%rowtype;
  v_fs    public.friendships%rowtype;
  v_fs_id uuid;
  v_max   integer := private.config_int('max_friends');
begin
  if p_token is null or char_length(p_token) < 16 or char_length(p_token) > 200 then
    raise exception 'このQRコードは使用できません' using errcode = 'WB001';
  end if;

  -- 同一トークンの同時読み取りで回数上限を超えないよう行ロック
  select * into v_tok
    from public.qr_tokens t
   where t.token_hash = sha256(convert_to(btrim(p_token), 'UTF8'))
   for update;

  if not found
     or v_tok.revoked_at is not null
     or v_tok.expires_at <= v_now
     or v_tok.use_count >= v_tok.max_uses then
    raise exception 'このQRコードは使用できません' using errcode = 'WB001';
  end if;

  if v_tok.user_id = v_uid then
    raise exception '自分自身のQRコードは読み取れません' using errcode = 'WB002';
  end if;

  -- ブロック関係(どちらから)・QR受付OFF は、期限切れ等と同一の文言/コードで拒否(ブロックを悟らせない)
  if private.is_blocked_either(v_uid, v_tok.user_id)
     or not exists (select 1 from public.profile_settings s
                    where s.user_id = v_tok.user_id and s.accept_qr) then
    raise exception 'このQRコードは使用できません' using errcode = 'WB001';
  end if;

  select * into v_fs
    from public.friendships f
   where (f.requester_id = v_uid and f.addressee_id = v_tok.user_id)
      or (f.requester_id = v_tok.user_id and f.addressee_id = v_uid)
   for update;

  if found and v_fs.status = 'accepted' then
    raise exception 'すでに友達です' using errcode = 'WB003';
  end if;

  if (select count(*) from public.qr_scans q
       where q.scanner_id = v_uid
         and (q.scanned_at at time zone 'Asia/Tokyo')::date = (v_now at time zone 'Asia/Tokyo')::date)
     >= private.config_int('qr_daily_scan_limit') then
    raise exception '本日のQR登録の上限に達しました' using errcode = 'WB004';
  end if;

  if private.friend_count(v_uid) >= v_max then
    raise exception '友達の上限(%人)に達しています', v_max using errcode = 'WB005';
  end if;
  if private.friend_count(v_tok.user_id) >= v_max then
    raise exception 'このQRコードは使用できません' using errcode = 'WB001';
  end if;

  if v_fs.id is not null then
    -- 申請中(双方向)/拒否済みでも、対面でQRを見せた=相手の意思なので承認済みに更新
    update public.friendships f
       set status = 'accepted', method = 'qr', responded_at = v_now
     where f.id = v_fs.id;
    v_fs_id := v_fs.id;
  else
    insert into public.friendships (requester_id, addressee_id, status, method, created_at, responded_at)
    values (v_uid, v_tok.user_id, 'accepted', 'qr', v_now, v_now)
    returning id into v_fs_id;
  end if;

  update public.qr_tokens t set use_count = t.use_count + 1 where t.id = v_tok.id;
  insert into public.qr_scans (token_id, scanner_id, owner_id, scanned_at)
  values (v_tok.id, v_uid, v_tok.user_id, v_now);

  -- 相手の表示名/アイコンのみ返す(対面でQRを見せてもらった相手)
  return query
    select v_fs_id, p.id, p.nickname, p.avatar_path
      from public.profiles p
     where p.id = v_tok.user_id;
end $$;
revoke all on function public.redeem_qr_token(text) from public, anon;
grant execute on function public.redeem_qr_token(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 申請の共通処理(招待コード/ID検索)。内部専用。
-- ---------------------------------------------------------------------------
create function private.request_friend(p_uid uuid, p_target uuid, p_method text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_now  timestamptz := private.app_now();
  v_fs   public.friendships%rowtype;
  v_id   uuid;
  v_max  integer := private.config_int('max_friends');
begin
  if p_target is null then
    raise exception 'コードが見つかりません' using errcode = 'WB011';
  end if;
  if p_target = p_uid then
    raise exception '自分自身には申請できません' using errcode = 'WB002';
  end if;
  if private.is_blocked_either(p_uid, p_target) then
    raise exception 'コードが見つかりません' using errcode = 'WB011';   -- ブロックを悟らせない
  end if;

  select * into v_fs
    from public.friendships f
   where (f.requester_id = p_uid and f.addressee_id = p_target)
      or (f.requester_id = p_target and f.addressee_id = p_uid)
   for update;

  if found then
    if v_fs.status = 'accepted' then
      raise exception 'すでに友達です' using errcode = 'WB003';
    elsif v_fs.status = 'pending' then
      if v_fs.requester_id = p_uid then
        raise exception 'すでに申請済みです' using errcode = 'WB006';
      end if;
      -- 相手から自分への申請が既にある = 双方が望んでいるので承認
      if private.friend_count(p_uid) >= v_max then
        raise exception '友達の上限(%人)に達しています', v_max using errcode = 'WB005';
      end if;
      if private.friend_count(p_target) >= v_max then
        raise exception '承認できません' using errcode = 'WB009';
      end if;
      update public.friendships f
         set status = 'accepted', responded_at = v_now
       where f.id = v_fs.id;
      return v_fs.id;
    else  -- declined
      if v_fs.requester_id = p_uid then
        raise exception 'この相手には申請できません' using errcode = 'WB013';
      end if;
      -- 自分が拒否した相手に、今度は自分から申請する場合は拒否履歴を消して新規申請
      delete from public.friendships f where f.id = v_fs.id;
    end if;
  end if;

  if private.friend_count(p_uid) >= v_max then
    raise exception '友達の上限(%人)に達しています', v_max using errcode = 'WB005';
  end if;
  if (select count(*) from public.friendships f
       where f.requester_id = p_uid and f.status = 'pending')
     >= private.config_int('max_outgoing_pending_requests') then
    raise exception '未承認の申請が多すぎます。相手の承認を待ってください' using errcode = 'WB014';
  end if;

  insert into public.friendships (requester_id, addressee_id, status, method, created_at)
  values (p_uid, p_target, 'pending', p_method, v_now)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function private.request_friend(uuid, uuid, text) from public, anon, authenticated;

-- 招待コードで申請(承認制)。コードは恒久(再生成可)。検索ON/OFFには依存しない。
create function public.request_friend_by_invite_code(p_code text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := private.require_profile();
  v_target uuid;
begin
  select s.user_id into v_target
    from public.profile_settings s
   where s.invite_code = upper(btrim(coalesce(p_code, '')));
  return private.request_friend(v_uid, v_target, 'code');
end $$;
revoke all on function public.request_friend_by_invite_code(text) from public, anon;
grant execute on function public.request_friend_by_invite_code(text) to authenticated;

-- ユーザーID完全一致で申請(承認制)。相手が searchable=true の場合のみ。
create function public.request_friend_by_user_code(p_user_code text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := private.require_profile();
  v_target uuid;
begin
  select p.id into v_target
    from public.profiles p
    join public.profile_settings s on s.user_id = p.id and s.searchable
   where p.user_code = lower(btrim(coalesce(p_user_code, '')));
  return private.request_friend(v_uid, v_target, 'request');
end $$;
revoke all on function public.request_friend_by_user_code(text) from public, anon;
grant execute on function public.request_friend_by_user_code(text) to authenticated;

-- ID検索(完全一致のみ)。searchable=true かつブロック関係なしの相手の ニックネーム・アイコン のみ返す。
-- 見つからない/検索OFF/ブロックはいずれも0行(区別不可)。
create function public.search_user_by_user_code(p_user_code text)
returns table (nickname text, avatar_path text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_profile();
begin
  return query
    select p.nickname, p.avatar_path
      from public.profiles p
      join public.profile_settings s on s.user_id = p.id and s.searchable
     where p.user_code = lower(btrim(coalesce(p_user_code, '')))
       and p.id <> v_uid
       and not private.is_blocked_either(v_uid, p.id);
end $$;
revoke all on function public.search_user_by_user_code(text) from public, anon;
grant execute on function public.search_user_by_user_code(text) to authenticated;

-- 申請の承認/拒否(addressee のみ)。戻り値は新しい status。
create function public.respond_friend_request(p_friendship_id uuid, p_accept boolean)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := private.require_profile();
  v_now  timestamptz := private.app_now();
  v_fs   public.friendships%rowtype;
  v_max  integer := private.config_int('max_friends');
begin
  select * into v_fs
    from public.friendships f
   where f.id = p_friendship_id and f.addressee_id = v_uid and f.status = 'pending'
   for update;
  if not found or private.is_blocked_either(v_uid, v_fs.requester_id) then
    raise exception '申請が見つかりません' using errcode = 'WB015';
  end if;

  if p_accept is not true then
    update public.friendships f set status = 'declined', responded_at = v_now where f.id = v_fs.id;
    return 'declined';
  end if;

  if private.friend_count(v_uid) >= v_max then
    raise exception '友達の上限(%人)に達しています', v_max using errcode = 'WB005';
  end if;
  if private.friend_count(v_fs.requester_id) >= v_max then
    raise exception '承認できません' using errcode = 'WB009';
  end if;

  update public.friendships f set status = 'accepted', responded_at = v_now where f.id = v_fs.id;
  return 'accepted';
end $$;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

-- 受信した未承認の申請一覧(申請者の ニックネーム・アイコン 付き。申請者の公開範囲に関わらず返す: 申請した側の意思による)
create function public.list_incoming_friend_requests()
returns table (
  friendship_id    uuid,
  from_user_id     uuid,
  from_nickname    text,
  from_avatar_path text,
  request_method   text,
  requested_at     timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_profile();
begin
  return query
    select f.id, p.id, p.nickname, p.avatar_path, f.method, f.created_at
      from public.friendships f
      join public.profiles p on p.id = f.requester_id
     where f.addressee_id = v_uid
       and f.status = 'pending'
       and not private.is_blocked_either(v_uid, f.requester_id)
     order by f.created_at desc;
end $$;
revoke all on function public.list_incoming_friend_requests() from public, anon;
grant execute on function public.list_incoming_friend_requests() to authenticated;

-- 招待コードの再生成(旧コードは即無効)
create function public.regenerate_invite_code()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := private.require_profile();
  v_code text;
  v_try  integer := 0;
begin
  loop
    v_code := private.random_code(10, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    exit when not exists (select 1 from public.profile_settings s where s.invite_code = v_code);
    v_try := v_try + 1;
    if v_try > 20 then
      raise exception 'could not generate invite_code' using errcode = 'WB500';
    end if;
  end loop;
  update public.profile_settings s set invite_code = v_code where s.user_id = v_uid;
  return v_code;
end $$;
revoke all on function public.regenerate_invite_code() from public, anon;
grant execute on function public.regenerate_invite_code() to authenticated;
