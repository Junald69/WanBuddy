-- =============================================================================
-- WanBuddy v0.2 / M2  02: テーブル(PRD 7.1)
--
-- PRD 7.1 との差分(理由は README「PRDとの差分」):
--   * profiles の invite_code / searchable / QR受付設定 は profile_settings(本人のみ閲覧)へ分離
--     (RLSは行単位であり、「友達に見せる行」から本人専用の列を隠せないため)
--   * dogs の instagram_handle / visibility_instagram は dog_instagram へ分離(同上: 項目ごとの公開範囲)
--   * qr_scans(QR読み取りログ: 1日上限の判定用)を追加
-- 公開範囲の値: 'public'(全体公開) / 'friends'(友達限定) / 'private'(非公開)
-- =============================================================================

-- ---- 飼い主 ------------------------------------------------------------------
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  nickname         text not null
                     check (char_length(nickname) between 1 and 20 and btrim(nickname) <> ''),
  avatar_path      text check (avatar_path is null or char_length(avatar_path) <= 300),
  user_code        text not null unique
                     check (user_code ~ '^[a-z0-9_]{4,20}$'),
  visibility_owner text not null default 'friends'
                     check (visibility_owner in ('public', 'friends', 'private')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.profiles is '飼い主プロフィール。他ユーザーへの表示は visibility_owner と can_view() で制御';
comment on column public.profiles.user_code is 'ユーザーID(完全一致検索用)。小文字英数と_、4〜20文字。トリガーで自動生成のみ(クライアントは指定も変更も不可: 列GRANTなし)';

-- 本人専用の設定(他ユーザーには絶対に見せない)
create table public.profile_settings (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  invite_code text not null unique check (invite_code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  searchable  boolean not null default false,   -- 「ユーザーID検索で見つかる」既定OFF(3.3)
  accept_qr   boolean not null default true,    -- 「QRでの友達登録を受け付ける」既定ON(4.3)
  created_at  timestamptz not null default now()
);

-- ---- 犬(1対多) ----------------------------------------------------------------
create table public.dogs (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references public.profiles (id) on delete cascade,
  name           text not null check (char_length(name) between 1 and 30 and btrim(name) <> ''),
  photo_path     text check (photo_path is null or char_length(photo_path) <= 300),
  breed          text check (breed is null or char_length(breed) <= 50),
  birthday       date check (birthday is null or birthday >= date '1990-01-01'),
  personality    text check (personality is null or char_length(personality) <= 100),
  visibility_dog text not null default 'friends'
                   check (visibility_dog in ('public', 'friends', 'private')),
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now()
);
create index dogs_owner_idx on public.dogs (owner_id, sort_order, created_at);

-- 犬ごとのInstagramリンク(ユーザー名のみ。公開範囲は友達限定/非公開)
create table public.dog_instagram (
  dog_id     uuid primary key references public.dogs (id) on delete cascade,
  handle     text not null check (handle ~ '^[A-Za-z0-9._]{1,30}$'),
  visibility text not null default 'private' check (visibility in ('friends', 'private')),
  updated_at timestamptz not null default now()
);

-- ---- 友達 ---------------------------------------------------------------------
create table public.friendships (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  method       text not null check (method in ('request', 'code', 'qr')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (requester_id <> addressee_id)
);
-- (a,b) と (b,a) の重複を防ぐ(逆向き重複も禁止)
create unique index friendships_pair_uniq
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_addressee_idx on public.friendships (addressee_id, status);
create index friendships_requester_idx on public.friendships (requester_id, status);

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

-- ---- 施設 ---------------------------------------------------------------------
create table public.facilities (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique check (code ~ '^[a-z0-9-]{1,60}$'),
  name                  text not null,
  park_name             text,
  operator              text,
  address               text,
  open_time             time not null,
  close_time            time not null,
  timezone              text not null default 'Asia/Tokyo'
                          check (private.is_valid_timezone(timezone)),   -- 不正なTZだと在場の営業時間判定が壊れるため
  fee_note              text,
  registration_required boolean not null default false,
  registration_note     text,
  official_url          text,
  notice_text           text,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  check (open_time < close_time)    -- 日跨ぎの施設はv0.2では非対応
);

create table public.facility_areas (
  id          uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities (id) on delete cascade,
  code        text not null check (code ~ '^[a-z0-9_-]{1,20}$'),
  name        text not null,
  area_sqm    integer check (area_sqm is null or area_sqm > 0),
  unique (facility_id, code)
);

-- ---- 在場 ---------------------------------------------------------------------
create table public.presences (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  facility_id  uuid not null references public.facilities (id) on delete restrict,
  area_code    text,
  status       text not null check (status in ('now', 'planned')),
  planned_at   timestamptz,
  started_at   timestamptz not null,
  expires_at   timestamptz not null,
  ended_at     timestamptz,
  ended_reason text check (ended_reason in ('manual', 'expired', 'switched_to_now', 'cancelled', 'replaced')),
  source       text not null default 'manual' check (char_length(source) between 1 and 30),
  visibility   text not null default 'friends' check (visibility in ('friends', 'private')),
  created_at   timestamptz not null default now(),
  foreign key (facility_id, area_code) references public.facility_areas (facility_id, code),
  check ((status = 'planned') = (planned_at is not null)),
  check ((ended_at is null) = (ended_reason is null)),
  check (expires_at > started_at)
);
-- 有効(未終了)な now / planned は1ユーザーにつき各1件まで
create unique index presences_one_active_now
  on public.presences (user_id) where status = 'now' and ended_at is null;
create unique index presences_one_active_planned
  on public.presences (user_id) where status = 'planned' and ended_at is null;
create index presences_facility_active_idx
  on public.presences (facility_id, expires_at) where ended_at is null;
create index presences_ended_idx on public.presences (ended_at) where ended_at is not null;
create index presences_expires_idx on public.presences (expires_at);
create index presences_user_idx on public.presences (user_id, started_at);   -- FK(部分インデックスはFKの検索に使えない)
create index presences_area_fk_idx on public.presences (facility_id, area_code);  -- 複合FK(施設+エリア)

create table public.presence_dogs (
  presence_id uuid not null references public.presences (id) on delete cascade,
  dog_id      uuid not null references public.dogs (id) on delete cascade,
  primary key (presence_id, dog_id)
);
create index presence_dogs_dog_idx on public.presence_dogs (dog_id);

-- ---- QR -----------------------------------------------------------------------
create table public.qr_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  token_hash bytea not null unique,                    -- 平文は保存しない(sha256)
  expires_at timestamptz not null,
  use_count  integer not null default 0 check (use_count >= 0),
  max_uses   integer not null check (max_uses > 0),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index qr_tokens_user_idx on public.qr_tokens (user_id);                              -- FK
create index qr_tokens_user_active_idx on public.qr_tokens (user_id) where revoked_at is null;
create index qr_tokens_expires_idx on public.qr_tokens (expires_at);

create table public.qr_scans (
  id         uuid primary key default gen_random_uuid(),
  token_id   uuid references public.qr_tokens (id) on delete set null,
  scanner_id uuid not null references public.profiles (id) on delete cascade,
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  scanned_at timestamptz not null
);
create index qr_scans_scanner_idx on public.qr_scans (scanner_id, scanned_at);
create index qr_scans_owner_idx on public.qr_scans (owner_id);     -- FK(退会カスケード時の全表走査を避ける)
create index qr_scans_token_idx on public.qr_scans (token_id);

-- ---- 通報・意見・同意 -----------------------------------------------------------
create table public.reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references public.profiles (id) on delete cascade,
  target_user_id uuid references public.profiles (id) on delete set null,  -- 対象退会後も記録は残す(保持方針は要決定)
  reason         text not null check (reason in ('harassment', 'inappropriate_image', 'impersonation', 'other')),
  comment        text check (comment is null or char_length(comment) <= 500),
  status         text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  created_at     timestamptz not null default now(),
  check (reporter_id is distinct from target_user_id)
);
create index reports_reporter_idx on public.reports (reporter_id);   -- FK
create index reports_target_idx on public.reports (target_user_id);  -- FK

create table public.feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users (id) on delete cascade,   -- 匿名はNULL
  kind       text not null check (kind in ('bug', 'request', 'other')),
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index feedback_user_idx on public.feedback (user_id);        -- FK

create table public.terms_consents (
  user_id       uuid not null references auth.users (id) on delete cascade,
  terms_version text not null check (char_length(terms_version) between 1 and 50),
  consented_at  timestamptz not null default now(),
  primary key (user_id, terms_version)
);
