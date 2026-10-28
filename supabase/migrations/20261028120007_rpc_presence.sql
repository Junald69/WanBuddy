-- =============================================================================
-- WanBuddy v0.2 / M2  07: RPC(在場)と定期メンテナンス関数
--   presences / presence_dogs は RPC 経由でのみ書き込み(直接 INSERT/UPDATE/DELETE 権限なし)。
--   時刻は private.app_now() 経由(テストで差し替え可能)。
--   エラーコード:
--     WB101 施設が見つからない/無効 / WB102 犬が未指定 / WB103 他人の犬 or 存在しない犬
--     WB104 status不正 / WB105 planned_at 必須/不正 / WB107 犬の数が上限 / WB108 最後の1頭は削除不可
--     WB201 開園時間外 / WB202 エリアが存在しない / WB203 過去時刻 / WB204 先すぎる予定
--     WB205 閉園時刻を超えて延長不可 / WB206 延長できる状態ではない(planned/終了済み/期限切れ)
--     WB207 在場が見つからない
-- =============================================================================

-- 自分の有効期限切れ在場を完了させる(登録/延長前の整合用。内部専用)
create function private.complete_user_expired(p_uid uuid, p_now timestamptz)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.presences p
     set ended_at = p.expires_at, ended_reason = 'expired'
   where p.user_id = p_uid and p.ended_at is null and p.expires_at <= p_now;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function private.complete_user_expired(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 在場登録(now / planned)
--   now    : 現在開園中のみ。expires_at = min(now + presence_now_minutes, 当日の閉園時刻)。
--            同一ユーザーの有効な now は 'replaced' で終了。同一施設の有効な planned は
--            同一トランザクションで 'switched_to_now' で終了。
--   planned: planned_at は 現在より後〜24時間以内、かつ開園時間内。
--            expires_at = min(planned_at + grace, 閉園時刻)。既存の有効な planned は 'replaced'。
-- ---------------------------------------------------------------------------
create function public.register_presence(
  p_facility_id uuid,
  p_status      text,
  p_dog_ids     uuid[],
  p_planned_at  timestamptz default null,
  p_area_code   text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := private.require_profile();
  v_now     timestamptz := private.app_now();
  v_fac     public.facilities%rowtype;
  v_dogs    uuid[];
  v_basis   timestamptz;       -- 営業時間の判定基準(now: 現在 / planned: planned_at)
  v_close   timestamptz;
  v_expires timestamptz;
  v_id      uuid;
begin
  if p_status is null or p_status not in ('now', 'planned') then
    raise exception 'statusが不正です' using errcode = 'WB104';
  end if;

  select * into v_fac from public.facilities f where f.id = p_facility_id and f.is_active;
  if not found then
    raise exception '施設が見つかりません' using errcode = 'WB101';
  end if;

  if p_area_code is not null and not exists (
    select 1 from public.facility_areas a where a.facility_id = v_fac.id and a.code = p_area_code
  ) then
    raise exception 'エリアが見つかりません' using errcode = 'WB202';
  end if;

  -- 犬: 1頭以上・重複除去・すべて自分の犬
  select coalesce(array_agg(distinct x), '{}') into v_dogs
    from unnest(coalesce(p_dog_ids, '{}')) as t(x) where x is not null;
  if cardinality(v_dogs) = 0 then
    raise exception '犬を1頭以上選んでください' using errcode = 'WB102';
  end if;
  if (select count(*) from public.dogs d where d.owner_id = v_uid and d.id = any (v_dogs))
     <> cardinality(v_dogs) then
    raise exception '自分の犬のみ選べます' using errcode = 'WB103';
  end if;

  perform private.complete_user_expired(v_uid, v_now);

  if p_status = 'now' then
    v_basis := v_now;
  else
    if p_planned_at is null then
      raise exception '予定時刻を指定してください' using errcode = 'WB105';
    end if;
    if p_planned_at <= v_now then
      raise exception '予定時刻は現在より後にしてください' using errcode = 'WB203';
    end if;
    if p_planned_at > v_now + make_interval(hours => private.config_int('presence_planned_max_ahead_hours')) then
      raise exception '予定は%時間先までです', private.config_int('presence_planned_max_ahead_hours')
        using errcode = 'WB204';
    end if;
    v_basis := p_planned_at;
  end if;

  if not private.facility_is_open_at(v_fac.timezone, v_fac.open_time, v_fac.close_time, v_basis) then
    raise exception '開園時間外です(%〜%)', to_char(v_fac.open_time, 'HH24:MI'), to_char(v_fac.close_time, 'HH24:MI')
      using errcode = 'WB201';
  end if;
  v_close := private.facility_close_at(v_fac.timezone, v_fac.close_time, v_basis);

  if p_status = 'now' then
    v_expires := least(v_now + make_interval(mins => private.config_int('presence_now_minutes')), v_close);

    -- 同一施設の planned → switched_to_now(同一トランザクション)
    update public.presences p
       set ended_at = v_now, ended_reason = 'switched_to_now'
     where p.user_id = v_uid and p.ended_at is null and p.status = 'planned' and p.facility_id = v_fac.id;
    -- 既存の now → replaced
    update public.presences p
       set ended_at = v_now, ended_reason = 'replaced'
     where p.user_id = v_uid and p.ended_at is null and p.status = 'now';

    insert into public.presences (user_id, facility_id, area_code, status, started_at, expires_at)
    values (v_uid, v_fac.id, p_area_code, 'now', v_now, v_expires)
    returning id into v_id;
  else
    v_expires := least(
      p_planned_at + make_interval(mins => private.config_int('presence_planned_grace_minutes')),
      v_close);

    update public.presences p
       set ended_at = v_now, ended_reason = 'replaced'
     where p.user_id = v_uid and p.ended_at is null and p.status = 'planned';

    insert into public.presences (user_id, facility_id, area_code, status, planned_at, started_at, expires_at)
    values (v_uid, v_fac.id, p_area_code, 'planned', p_planned_at, v_now, v_expires)
    returning id into v_id;
  end if;

  insert into public.presence_dogs (presence_id, dog_id)
  select v_id, unnest(v_dogs);

  return v_id;
end $$;
revoke all on function public.register_presence(uuid, text, uuid[], timestamptz, text) from public, anon;
grant execute on function public.register_presence(uuid, text, uuid[], timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 延長(now のみ)。expires_at += presence_extend_minutes。ただし閉園時刻を超えない。
-- ---------------------------------------------------------------------------
create function public.extend_presence(p_presence_id uuid)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := private.require_profile();
  v_now   timestamptz := private.app_now();
  v_p     public.presences%rowtype;
  v_fac   public.facilities%rowtype;
  v_close timestamptz;
  v_new   timestamptz;
begin
  perform private.complete_user_expired(v_uid, v_now);

  select * into v_p from public.presences p
   where p.id = p_presence_id and p.user_id = v_uid for update;
  if not found then
    raise exception '在場が見つかりません' using errcode = 'WB207';
  end if;
  if v_p.status <> 'now' or v_p.ended_at is not null then
    raise exception '延長できません' using errcode = 'WB206';
  end if;

  select * into v_fac from public.facilities f where f.id = v_p.facility_id;
  -- 閉園時刻 = 開始日(施設のローカル日付)の閉園時刻
  v_close := private.facility_close_at(v_fac.timezone, v_fac.close_time, v_p.started_at);
  v_new := least(v_p.expires_at + make_interval(mins => private.config_int('presence_extend_minutes')), v_close);
  if v_new <= v_p.expires_at then
    raise exception '閉園時刻(%)を超えて延長できません', to_char(v_fac.close_time, 'HH24:MI')
      using errcode = 'WB205';
  end if;

  update public.presences p set expires_at = v_new where p.id = v_p.id;
  return v_new;
end $$;
revoke all on function public.extend_presence(uuid) from public, anon;
grant execute on function public.extend_presence(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 終了(now: manual / planned: cancelled)。既に終了済みなら何もしない(冪等)。
-- ---------------------------------------------------------------------------
create function public.end_presence(p_presence_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_profile();
  v_now timestamptz := private.app_now();
  v_p   public.presences%rowtype;
begin
  select * into v_p from public.presences p
   where p.id = p_presence_id and p.user_id = v_uid for update;
  if not found then
    raise exception '在場が見つかりません' using errcode = 'WB207';
  end if;
  if v_p.ended_at is not null then
    return;
  end if;
  if v_p.expires_at <= v_now then
    update public.presences p set ended_at = p.expires_at, ended_reason = 'expired' where p.id = v_p.id;
    return;
  end if;
  update public.presences p
     set ended_at = v_now,
         ended_reason = case when p.status = 'now' then 'manual' else 'cancelled' end
   where p.id = v_p.id;
end $$;
revoke all on function public.end_presence(uuid) from public, anon;
grant execute on function public.end_presence(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 定期メンテナンス(pg_cron / Edge Function(service_role)から呼ぶ。クライアントには非公開)
-- ---------------------------------------------------------------------------
-- 期限切れの在場を完了(ended_at = expires_at, ended_reason = 'expired')
create function public.complete_expired_presences()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.presences p
     set ended_at = p.expires_at, ended_reason = 'expired'
   where p.ended_at is null and p.expires_at <= private.app_now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.complete_expired_presences() from public, anon, authenticated;
grant execute on function public.complete_expired_presences() to service_role;

-- 終了から presence_purge_after_hours(既定24h)経過した在場を物理削除(presence_dogs はカスケード)。
-- あわせて失効/期限切れQR・古いQR読み取りログも削除。
create function public.purge_old_presence_data()
returns table (presences_deleted integer, qr_tokens_deleted integer, qr_scans_deleted integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := private.app_now();
  v_a integer;
  v_b integer;
  v_c integer;
begin
  perform public.complete_expired_presences();

  delete from public.presences p
   where p.ended_at is not null
     and p.ended_at < v_now - make_interval(hours => private.config_int('presence_purge_after_hours'));
  get diagnostics v_a = row_count;

  delete from public.qr_tokens t
   where least(t.expires_at, coalesce(t.revoked_at, t.expires_at))
         < v_now - make_interval(hours => private.config_int('qr_token_purge_after_hours'));
  get diagnostics v_b = row_count;

  delete from public.qr_scans q
   where q.scanned_at < v_now - make_interval(days => private.config_int('qr_scan_log_retention_days'));
  get diagnostics v_c = row_count;

  return query select v_a, v_b, v_c;
end $$;
revoke all on function public.purge_old_presence_data() from public, anon, authenticated;
grant execute on function public.purge_old_presence_data() to service_role;
