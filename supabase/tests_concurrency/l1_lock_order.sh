#!/usr/bin/env bash
# L-1 再現テスト: 相互操作(A→B と B→A がほぼ同時)でデッドロックしないこと。
#   旧実装: require_profile が自分のプロフィール行を FOR UPDATE → friendships INSERT の FK(相手のプロフィール行に FOR KEY SHARE)と衝突して
#          A↔B で相互待ち(40P01 deadlock detected)。
#   現実装: プロフィールのロックは FOR NO KEY UPDATE(KEY SHARE と衝突しない) + 2者間フローはペア単位の advisory lock で直列化。
# 使い方(run_tests.sh から呼ばれる): l1_lock_order.sh <psql> <socket-dir> <template-db>
#   出力: "WBTEST PASS|name" / "WBTEST FAIL|name (詳細)" 行(run_tests.sh が集計)
set -u
PSQL_BIN="$1"; SOCK="$2"; TEMPLATE="$3"; DB="${TEMPLATE}_conc"
PS=("$PSQL_BIN" -h "$SOCK" -U postgres -X -q -At)
"${PS[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" >/dev/null 2>&1 || { echo "WBTEST FAIL|concurrency: DB作成失敗"; exit 1; }
P=("${PS[@]}" -d "$DB")
T="$(mktemp -d)"; trap 'rm -rf "$T"; "${PS[@]}" -d postgres -c "drop database if exists $DB" >/dev/null 2>&1' EXIT

ok()   { echo "WBTEST PASS|$1"; }
fail() { echo "WBTEST FAIL|$1"; }
check(){ if [[ "$2" == "1" ]]; then ok "$1"; else fail "$1 ($3)"; fi; }

uid() { "${P[@]}" -c "select md5('wbconc:$1')::uuid"; }
mkuser() {   # name
  local id; id="$(uid "$1")"
  "${P[@]}" -c "insert into auth.users (id,email) values ('$id','$1@example.test'); insert into public.profiles (id,nickname) values ('$id','$1'); update public.profile_settings set searchable = true where user_id='$id';" >/dev/null
}
# 認証済みユーザーとして SQL を実行するためのプレリュード
prelude() { cat <<SQL
set role authenticated;
select set_config('request.jwt.claim.sub', '$(uid "$1")', false);
select set_config('request.jwt.claims', json_build_object('sub','$(uid "$1")','role','authenticated')::text, false);
SQL
}
run_as() { # name sql...  (1セッション)
  local n="$1"; shift
  { prelude "$n"; echo "$*"; } | timeout 40 "${PS[@]}" -d "$DB" -v ON_ERROR_STOP=0 2>&1
}

# ------------------------------------------------------------------
# シナリオ共通: B が自分のプロフィール行ロックを取ったまま 2秒待つ間に A が先に動き、その後 B が A に対して同じ操作をする。
#   旧実装なら A(自分の行をロック済み)が B の行待ち / B(自分の行をロック済み)が A の行待ち → デッドロック。
scenario() {  # name  A側SQL  B側SQL(待機後)
  local name="$1" sqlA="$2" sqlB="$3"
  {
    prelude "${name}_b"
    echo "begin;"
    echo "select 'LOCKED' from public.regenerate_invite_code();"   # B のプロフィール行をロック(トランザクションを開いたまま)
    echo "select pg_sleep(2);"
    echo "$sqlB"
    echo "commit;"
  } | timeout 40 "${PS[@]}" -d "$DB" -v ON_ERROR_STOP=0 >"$T/$name.B" 2>&1 &
  local pb=$!
  sleep 0.7
  run_as "${name}_a" "begin; $sqlA commit;" >"$T/$name.A" &
  local pa=$!
  wait $pa; local ra=$?; wait $pb; local rb=$?
  echo "$ra $rb"
}

# ---- S1: QR 同時読み取り(A が B のQRを、B が A のQRを) -----------------------------------------------
mkuser s1_a; mkuser s1_b
tA="$(run_as s1_a "select qr_token from public.issue_qr_token();" | grep -E '^[0-9a-f]{64}$' | head -1)"
tB="$(run_as s1_b "select qr_token from public.issue_qr_token();" | grep -E '^[0-9a-f]{64}$' | head -1)"
[[ -n "$tA" && -n "$tB" ]] && ok "L-1 前提: QRトークン発行" || fail "L-1 前提: QRトークン発行に失敗"
rc="$(scenario s1 "select 'A_REDEEM_OK', friend_id from public.redeem_qr_token('$tB');" "select 'B_REDEEM_DONE', friend_id from public.redeem_qr_token('$tA');")"
check "L-1 QR相互読み取り: 両セッションが時間内に終了(ハング無し)" "$([[ "$rc" != *124* ]] && echo 1 || echo 0)" "exit=$rc"
check "L-1 QR相互読み取り: deadlock detected (40P01) が発生しない" "$(! grep -qiE 'deadlock|40P01' "$T"/s1.A "$T"/s1.B && echo 1 || echo 0)" "$(grep -hiE 'deadlock' "$T"/s1.A "$T"/s1.B | head -2)"
check "L-1 QR相互読み取り: 先に動いた A の登録は成功する" "$(grep -q 'A_REDEEM_OK' "$T/s1.A" && echo 1 || echo 0)" "$(head -c 300 "$T/s1.A")"
n="$("${P[@]}" -c "select count(*) from public.friendships where status='accepted' and method='qr' and '$(uid s1_a)' in (requester_id,addressee_id) and '$(uid s1_b)' in (requester_id,addressee_id)")"
check "L-1 QR相互読み取り: 友達関係はちょうど1行(重複なし)" "$([[ "$n" == "1" ]] && echo 1 || echo 0)" "count=$n"
check "L-1 QR相互読み取り: 後続の B は『登録済み』として整然と拒否される(すでに友達です)" "$(grep -q 'ERROR:  すでに友達です' "$T/s1.B" && echo 1 || echo 0)" "$(head -c 300 "$T/s1.B")"

# ---- S2: 友達申請の交差(A→B と B→A) -----------------------------------------------------------------
mkuser s2_a; mkuser s2_b
ucB="$("${P[@]}" -c "select user_code from public.profiles where id='$(uid s2_b)'")"
ucA="$("${P[@]}" -c "select user_code from public.profiles where id='$(uid s2_a)'")"
rc="$(scenario s2 "select 'A_REQ_OK', public.request_friend_by_user_code('$ucB');" "select 'B_REQ_DONE', public.request_friend_by_user_code('$ucA');")"
check "L-1 申請交差: 両セッションが時間内に終了(ハング無し)" "$([[ "$rc" != *124* ]] && echo 1 || echo 0)" "exit=$rc"
check "L-1 申請交差: deadlock detected (40P01) が発生しない" "$(! grep -qiE 'deadlock|40P01' "$T"/s2.A "$T"/s2.B && echo 1 || echo 0)" "$(grep -hiE 'deadlock' "$T"/s2.A "$T"/s2.B | head -2)"
check "L-1 申請交差: 先に動いた A の申請は成功する" "$(grep -q 'A_REQ_OK' "$T/s2.A" && echo 1 || echo 0)" "$(head -c 300 "$T/s2.A")"
n="$("${P[@]}" -c "select count(*) from public.friendships where '$(uid s2_a)' in (requester_id,addressee_id) and '$(uid s2_b)' in (requester_id,addressee_id)")"
check "L-1 申請交差: 友達関係の行はちょうど1行" "$([[ "$n" == "1" ]] && echo 1 || echo 0)" "count=$n"

# ---- S3: 双方が同時に相手を申請(両方ロック無しの純粋な競合。結果は『1行』に収束) ----------------------------------------------
mkuser s3_a; mkuser s3_b
ucB="$("${P[@]}" -c "select user_code from public.profiles where id='$(uid s3_b)'")"
ucA="$("${P[@]}" -c "select user_code from public.profiles where id='$(uid s3_a)'")"
run_as s3_a "select pg_sleep(0.5); select 'A3_DONE', public.request_friend_by_user_code('$ucB');" >"$T/s3.A" &
pa=$!
run_as s3_b "select pg_sleep(0.5); select 'B3_DONE', public.request_friend_by_user_code('$ucA');" >"$T/s3.B" &
pb=$!
wait $pa; ra=$?; wait $pb; rb=$?
check "L-1 同時申請: deadlock しない・ハングしない" "$(! grep -qiE 'deadlock|40P01' "$T"/s3.A "$T"/s3.B && [[ $ra != 124 && $rb != 124 ]] && echo 1 || echo 0)" "ra=$ra rb=$rb"
n="$("${P[@]}" -c "select count(*) from public.friendships where '$(uid s3_a)' in (requester_id,addressee_id) and '$(uid s3_b)' in (requester_id,addressee_id)")"
check "L-1 同時申請: 友達関係の行はちょうど1行" "$([[ "$n" == "1" ]] && echo 1 || echo 0)" "count=$n"

# 調査用: WB_CONC_DEBUG=1 で各セッションの出力を stderr に表示
if [[ -n "${WB_CONC_DEBUG:-}" ]]; then for f in "$T"/*.A "$T"/*.B; do echo "--- $(basename "$f")" >&2; cat "$f" >&2; done; fi
