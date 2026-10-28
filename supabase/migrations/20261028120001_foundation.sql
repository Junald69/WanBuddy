-- =============================================================================
-- WanBuddy v0.2 / M2  01: 基盤(スキーマ・既定権限・サーバー側定数・時刻関数)
--
-- 方針:
--   * public  : クライアント(PostgREST)から見えるテーブル/ビュー/RPC
--   * private : クライアントから直接呼べない内部関数・設定(PostgRESTの公開スキーマに含めない)
--   * 新規オブジェクトが anon/authenticated/PUBLIC に自動付与されないよう既定権限を絞る。
--     以降の各マイグレーションでも、オブジェクトごとに明示的に REVOKE/GRANT する(二重化)。
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
-- RLSポリシー/ビューから呼ぶ関数のため authenticated には USAGE が必要(関数ごとの EXECUTE で絞る)
grant usage on schema private to authenticated;
grant usage on schema private to service_role;

-- 既定権限: 今後 postgres(マイグレーション実行ロール)が作る public/private のオブジェクトは何も付与しない。
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
alter default privileges in schema private revoke all on tables from anon, authenticated;
alter default privileges in schema private revoke all on sequences from anon, authenticated;
alter default privileges in schema private revoke all on functions from anon, authenticated;
-- 関数の EXECUTE は PostgreSQL の既定で PUBLIC に付与される。スキーマ指定なし(全スキーマ)の既定権限で外す。
alter default privileges revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- サーバー側の設定値(定数)。変更は SQL Editor / service_role から。クライアントには一切公開しない。
-- ---------------------------------------------------------------------------
create table private.app_config (
  key         text primary key,
  value       text not null,
  description text,
  updated_at  timestamptz not null default now()
);
alter table private.app_config enable row level security;
revoke all on table private.app_config from public, anon, authenticated;
-- ポリシーなし = security definer 関数(所有者=RLSバイパス)以外からは読めない

insert into private.app_config (key, value, description) values
  ('max_dogs_per_user',               '5',   '1人あたりの犬の上限(4.2【提案値】)'),
  ('qr_ttl_minutes',                  '10',  'QRトークンの有効期限(分)(4.3【提案値】)'),
  ('qr_max_uses',                     '5',   '1つのQRトークンの最大読み取り回数(4.3【提案値】)'),
  ('qr_daily_scan_limit',             '20',  '読み取り側の1日(JST暦日)あたり登録上限(4.3【提案値】)'),
  ('max_friends',                     '100', '友達上限(4.3【提案値】)'),
  ('max_outgoing_pending_requests',   '30',  '未承認の送信申請の同時上限(PRD外・スパム対策の提案値)'),
  ('presence_now_minutes',            '180', '「今いる」の既定の継続時間(分)(4.4【提案値】)'),
  ('presence_extend_minutes',         '60',  '延長1回あたりの分数(4.4【提案値】)'),
  ('presence_planned_max_ahead_hours','24',  '「これから行く」の予定時刻を指定できる先の上限(時間)(4.5【提案値】)'),
  ('presence_planned_grace_minutes',  '60',  '「これから行く」の失効猶予: expires_at=予定時刻+この分数(4.5【提案値】)'),
  ('presence_purge_after_hours',      '24',  '終了/期限切れの在場を物理削除するまでの時間(5.1【提案値】)'),
  ('qr_token_purge_after_hours',      '24',  '期限切れ/失効QRトークンを物理削除するまでの時間(7.1)'),
  ('qr_scan_log_retention_days',      '7',   'QR読み取りログの保持日数(1日上限の判定には1日以上必要)')
on conflict (key) do nothing;

create function private.config_int(p_key text)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v integer;
begin
  select c.value::integer into v from private.app_config c where c.key = p_key;
  if v is null then
    raise exception 'app_config key missing or null: %', p_key using errcode = 'WB500';
  end if;
  return v;
end $$;
revoke all on function private.config_int(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 現在時刻。製品では now() と同じ。ローカル検証では test_support 側で同名関数を上書きして時刻を差し替える。
-- (本番にはテスト用の上書き口を一切持ち込まない)
-- ---------------------------------------------------------------------------
create function private.app_now()
returns timestamptz
language sql
stable
set search_path = ''
as $$ select now() $$;
revoke all on function private.app_now() from public, anon;
grant execute on function private.app_now() to authenticated, service_role;   -- RLSポリシー/ビューから呼ばれる

-- ---------------------------------------------------------------------------
-- 暗号論的乱数(gen_random_uuid)から偏りなく文字列を作る(招待コード・ユーザーID用)
-- ---------------------------------------------------------------------------
create function private.random_code(p_len integer, p_alphabet text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_out   text := '';
  v_b     bytea;
  v_i     integer;
  v_n     integer := length(p_alphabet);
  v_limit integer := (256 / length(p_alphabet)) * length(p_alphabet);  -- 棄却サンプリング(剰余の偏り除去)
  v_byte  integer;
begin
  while length(v_out) < p_len loop
    v_b := uuid_send(gen_random_uuid());
    for v_i in 0..15 loop
      exit when length(v_out) >= p_len;
      v_byte := get_byte(v_b, v_i);
      if v_byte < v_limit then
        v_out := v_out || substr(p_alphabet, (v_byte % v_n) + 1, 1);
      end if;
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function private.random_code(integer, text) from public, anon, authenticated;
