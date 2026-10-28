-- 旧来の Supabase(新規オブジェクトが anon/authenticated/service_role に自動付与される)を再現するストレステスト。
-- 本プロジェクトは auto expose=OFF なので通常は不要。migrations の REVOKE が効くことの追加確認用(LEGACY=1)。
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
