-- =============================================================================
-- WanBuddy v0.2 / M2  04: トリガー
--   トリガー関数は security definer + search_path 固定。EXECUTE は誰にも与えない
--   (トリガー実行に EXECUTE 権限は不要)。
-- =============================================================================

-- ---- profiles: user_code 自動生成/正規化, updated_at -------------------------------
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
  perform 1 from public.profiles p where p.id = new.owner_id for update;
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

  perform 1 from public.profiles p where p.id = old.owner_id for update;

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
