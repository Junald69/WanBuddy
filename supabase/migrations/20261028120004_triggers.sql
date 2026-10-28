-- =============================================================================
-- WanBuddy v0.2 / M2  04: トリガー
--   トリガー関数は security definer + search_path 固定。EXECUTE は誰にも与えない
--   (トリガー実行に EXECUTE 権限は不要)。
-- =============================================================================

-- ---- profiles: user_code 自動生成(クライアントは指定不可。列GRANTなし)/正規化, updated_at -------------------------------
create function private.trg_profiles_before()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_try integer := 0;
begin
  if tg_op = 'INSERT' then
    if new.user_code is null or btrim(new.user_code) = '' then
      loop
        new.user_code := private.random_code(8, 'abcdefghjkmnpqrstuvwxyz23456789');
        exit when not exists (select 1 from public.profiles p where p.user_code = new.user_code);
        v_try := v_try + 1;
        if v_try > 20 then
          raise exception 'could not generate user_code' using errcode = 'WB500';
        end if;
      end loop;
    end if;
  else
    new.id := old.id;                -- 主キーは変更不可
    new.created_at := old.created_at;
  end if;
  new.user_code := lower(btrim(new.user_code));
  new.updated_at := now();
  return new;
end $$;
revoke all on function private.trg_profiles_before() from public, anon, authenticated;

create trigger profiles_before_ins_upd
  before insert or update on public.profiles
  for each row execute function private.trg_profiles_before();

-- ---- profiles → profile_settings(招待コード生成) ----------------------------------
create function private.trg_profiles_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
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
  insert into public.profile_settings (user_id, invite_code) values (new.id, v_code);
  return new;
end $$;
revoke all on function private.trg_profiles_after_insert() from public, anon, authenticated;

create trigger profiles_after_ins
  after insert on public.profiles
  for each row execute function private.trg_profiles_after_insert();

-- ---- dogs: 上限(既定5頭)をDB側で強制 ----------------------------------------------
create function private.trg_dogs_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- 同時INSERTによる上限超過(競合)を防ぐため、所有者のプロフィール行をロックして直列化
  perform 1 from public.profiles p where p.id = new.owner_id for no key update;
  select count(*) into v_count from public.dogs d where d.owner_id = new.owner_id;
  if v_count >= private.config_int('max_dogs_per_user') then
    raise exception '登録できる犬は最大%頭までです', private.config_int('max_dogs_per_user')
      using errcode = 'WB107';
  end if;
  return new;
end $$;
revoke all on function private.trg_dogs_before_insert() from public, anon, authenticated;

create trigger dogs_before_ins
  before insert on public.dogs
  for each row execute function private.trg_dogs_before_insert();

-- ---- dogs: 削除時の整合(在場から外す/0頭になる在場は終了/最後の1頭は削除不可) -----------
create function private.trg_dogs_before_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := private.app_now();
begin
  -- 退会(profiles の削除→カスケード)の場合は親が既に無い。その場合は何もしない(全削除を許可)。
  if not exists (select 1 from public.profiles p where p.id = old.owner_id) then
    return old;
  end if;

  perform 1 from public.profiles p where p.id = old.owner_id for no key update;

  if not exists (
    select 1 from public.dogs d where d.owner_id = old.owner_id and d.id <> old.id
  ) then
    raise exception '最後の1頭は削除できません' using errcode = 'WB108';
  end if;

  -- この犬を含む在場から犬を外し、0頭になった有効な在場は終了(cancelled)
  delete from public.presence_dogs pd where pd.dog_id = old.id;

  update public.presences pr
     set ended_at = v_now, ended_reason = 'cancelled'
   where pr.user_id = old.owner_id
     and pr.ended_at is null
     and not exists (select 1 from public.presence_dogs pd2 where pd2.presence_id = pr.id);

  return old;
end $$;
revoke all on function private.trg_dogs_before_delete() from public, anon, authenticated;

create trigger dogs_before_del
  before delete on public.dogs
  for each row execute function private.trg_dogs_before_delete();

-- ---- presence_dogs: 在場の持ち主と犬の持ち主が一致すること(多層防御) -------------------
create function private.trg_presence_dogs_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.presences p
    join public.dogs d on d.owner_id = p.user_id
    where p.id = new.presence_id and d.id = new.dog_id
  ) then
    raise exception '在場の犬は自分の犬のみ指定できます' using errcode = 'WB103';
  end if;
  return new;
end $$;
revoke all on function private.trg_presence_dogs_check() from public, anon, authenticated;

create trigger presence_dogs_before_ins_upd
  before insert or update on public.presence_dogs
  for each row execute function private.trg_presence_dogs_check();

-- ---- blocks: ブロック成立時に友達関係(申請含む全状態)を削除 ---------------------------
create function private.trg_blocks_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.friendships f
   where (f.requester_id = new.blocker_id and f.addressee_id = new.blocked_id)
      or (f.requester_id = new.blocked_id and f.addressee_id = new.blocker_id);
  return new;
end $$;
revoke all on function private.trg_blocks_after_insert() from public, anon, authenticated;

create trigger blocks_after_ins
  after insert on public.blocks
  for each row execute function private.trg_blocks_after_insert();

-- ---- dog_instagram: updated_at -------------------------------------------------------
create function private.trg_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;
revoke all on function private.trg_touch_updated_at() from public, anon, authenticated;

create trigger dog_instagram_touch
  before update on public.dog_instagram
  for each row execute function private.trg_touch_updated_at();

-- ---- reports / feedback: 1日あたりの送信上限(スパム・嫌がらせ対策。【提案値】 report 20 / feedback 10)--------
--   JST暦日 × ユーザー単位。private.daily_counters を原子的に加算(同時送信でも上限を超えない)。
--   呼び出し元(auth.uid())基準 = 匿名意見(user_id NULL)でも送信者単位で制限できる。
--   auth.uid() が無い実行(service_role / 運営のSQL)は制限しない。
--   created_at はクライアントから指定不可(列GRANTなし)のため、時刻関数 app_now() で上書き(JST暦日の判定と一致させる)。
create function private.trg_daily_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_kind  text := tg_argv[0];      -- 'report' | 'feedback'
  v_limit integer;
  v_now   timestamptz := private.app_now();
  v_n     integer;
begin
  new.created_at := v_now;
  if v_uid is null then
    return new;
  end if;
  v_limit := private.config_int(case v_kind when 'report' then 'report_daily_limit' else 'feedback_daily_limit' end);

  insert into private.daily_counters as c (user_id, kind, day, n)
  values (v_uid, v_kind, (v_now at time zone 'Asia/Tokyo')::date, 1)
  on conflict (user_id, kind, day) do update set n = c.n + 1 where c.n < v_limit;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    if v_kind = 'report' then
      raise exception '本日の通報の上限(%件)に達しました', v_limit using errcode = 'WB301';
    else
      raise exception '本日の意見送信の上限(%件)に達しました', v_limit using errcode = 'WB302';
    end if;
  end if;
  return new;
end $$;
revoke all on function private.trg_daily_limit() from public, anon, authenticated;

create trigger reports_daily_limit
  before insert on public.reports
  for each row execute function private.trg_daily_limit('report');
create trigger feedback_daily_limit
  before insert on public.feedback
  for each row execute function private.trg_daily_limit('feedback');
