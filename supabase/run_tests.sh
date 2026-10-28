#!/usr/bin/env bash
# =============================================================================
# WanBuddy v0.2 / M2 ローカル検証スクリプト
#   PostgreSQL(15以上)を用意 → 一時クラスタ作成 → stub → migrations → テスト用ヘルパー → tests/*.sql → 集計
#   外部サービスには一切接続しない(ローカルPostgreSQLのみ。TCPも開かない=unixソケットのみ)。
#
# 使い方:   ./run_tests.sh            # 全テスト
#           KEEP=1 ./run_tests.sh     # 終了後もDBサーバーを止めない(psqlで調査したいとき)
#           PG_BIN=/path/to/bin ./run_tests.sh   # 使うPostgreSQLのbinを指定
#           ONLY=05_qr ./run_tests.sh # 指定テストのみ(部分一致)
#           LEGACY=1 ./run_tests.sh   # 旧来のSupabase(デフォルト権限の自動付与あり)を再現して追加確認
# PostgreSQLの探し方(順):
#   1) $PG_BIN  2) PATH上の psql/initdb(15以上)  3) 前回ダウンロード済み(.pg-local)
#   4) 自動取得: root なら apt-get install postgresql、そうでなければ PyPI の pixeltable-pgserver
#      (PostgreSQLバイナリ入りwheel)を .pg-local に展開
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WB_WORK:-${TMPDIR:-/tmp}/wanbuddy-pgtest}"
LOCAL_PG="$HERE/.pg-local"
DB=wanbuddy_test
mkdir -p "$WORK"

log() { printf '\033[1m[run_tests]\033[0m %s\n' "$*" >&2; }

pg_major() { "$1/psql" --version 2>/dev/null | sed -E 's/[^0-9]*([0-9]+).*/\1/'; }

find_pg() {
  local c
  if [[ -n "${PG_BIN:-}" && -x "$PG_BIN/initdb" ]]; then echo "$PG_BIN"; return; fi
  if command -v initdb >/dev/null && command -v psql >/dev/null; then
    c="$(dirname "$(command -v initdb)")"
    [[ "$(pg_major "$c")" -ge 15 ]] && { echo "$c"; return; }
  fi
  for c in /usr/lib/postgresql/*/bin "$LOCAL_PG"/pkg/pixeltable_pgserver/pginstall/bin; do
    [[ -x "$c/initdb" && -x "$c/psql" ]] || continue
    [[ "$(pg_major "$c")" -ge 15 ]] && { echo "$c"; return; }
  done
  return 1
}

install_pg() {
  if [[ "$(id -u)" = 0 ]] && command -v apt-get >/dev/null; then
    log "apt-get で PostgreSQL をインストールします"
    if apt-get install -y postgresql >&2; then return 0; fi
    log "apt が失敗。wheel方式に切り替えます"
  fi
  log "PyPI の pixeltable-pgserver(PostgreSQLバイナリ入りwheel)を $LOCAL_PG に展開します"
  mkdir -p "$LOCAL_PG/dl" "$LOCAL_PG/pkg"
  python3 -m pip download pixeltable-pgserver --no-deps --only-binary=:all: -d "$LOCAL_PG/dl" >&2
  python3 - "$LOCAL_PG" <<'PY'
import glob, sys, zipfile, os
root = sys.argv[1]
whl = sorted(glob.glob(os.path.join(root, "dl", "pixeltable_pgserver-*.whl")))[-1]
zipfile.ZipFile(whl).extractall(os.path.join(root, "pkg"))
b = os.path.join(root, "pkg", "pixeltable_pgserver", "pginstall", "bin")
for f in os.listdir(b):
    os.chmod(os.path.join(b, f), 0o755)
PY
}

BIN="$(find_pg || true)"
if [[ -z "$BIN" ]]; then install_pg; BIN="$(find_pg)" || { log "PostgreSQL 15+ を用意できませんでした"; exit 2; }; fi
log "PostgreSQL: $("$BIN/psql" --version) ($BIN)"

# ---- 一時クラスタ ---------------------------------------------------------------
DATA="$WORK/data"; SOCK="$WORK/sock"; LOG="$WORK/pg.log"
if [[ -f "$DATA/postmaster.pid" ]]; then "$BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; fi
rm -rf "$DATA" "$SOCK"; mkdir -p "$SOCK"
"$BIN/initdb" -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --locale=C.UTF-8 >/dev/null 2>"$WORK/initdb.err" \
  || "$BIN/initdb" -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --locale=C >/dev/null
"$BIN/pg_ctl" -D "$DATA" -l "$LOG" -w -o "-c listen_addresses='' -c unix_socket_directories='$SOCK' -c fsync=off" start </dev/null >/dev/null 2>&1

cleanup() { [[ "${KEEP:-0}" = 1 ]] || "$BIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

PSQL=("$BIN/psql" -h "$SOCK" -U postgres -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB"
P=("${PSQL[@]}" -d "$DB")

# ---- 構築 -----------------------------------------------------------------------
log "1/4 Supabase互換stub"
"${P[@]}" -f "$HERE/test_support/00_supabase_stub.sql" >/dev/null
if [[ "${LEGACY:-0}" = 1 ]]; then
  log "  (LEGACY=1) 旧来のデフォルト権限自動付与を再現"
  "${P[@]}" -f "$HERE/test_support/01_legacy_default_privileges.sql" >/dev/null
fi

log "2/4 migrations(ファイル名順)"
for f in "$HERE"/migrations/*.sql; do
  echo "  - $(basename "$f")" >&2
  "${P[@]}" -1 -f "$f" >/dev/null
done

log "3/4 テスト用ヘルパー(app_now差し替え等)"
"${P[@]}" -f "$HERE/test_support/10_test_helpers.sql" >/dev/null 2>&1

# ---- テスト ---------------------------------------------------------------------
log "4/4 テスト実行"
PASS=0; FAIL=0; ERRFILES=0
shopt -s nullglob
for t in "$HERE"/tests/[0-9]*.sql; do
  name="$(basename "$t" .sql)"
  [[ -n "${ONLY:-}" && "$name" != *"$ONLY"* ]] && continue
  out="$WORK/$name.out"
  if "${PSQL[@]}" -d "$DB" -f "$t" >"$out" 2>&1; then rc=0; else rc=$?; fi
  p=$(grep -c 'WBTEST PASS|' "$out" || true)
  f=$(grep -c 'WBTEST FAIL|' "$out" || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  if [[ $rc -ne 0 ]]; then
    ERRFILES=$((ERRFILES + 1))
    printf '  \033[31mERROR\033[0m %-28s pass=%-4s fail=%-3s (psql異常終了)\n' "$name" "$p" "$f"
    grep -v 'WBTEST PASS|' "$out" | tail -n 15 | sed 's/^/        /'
  elif [[ $f -gt 0 ]]; then
    printf '  \033[31mFAIL \033[0m %-28s pass=%-4s fail=%s\n' "$name" "$p" "$f"
    grep 'WBTEST FAIL|' "$out" | sed 's/^.*WBTEST FAIL|/        FAIL: /'
  else
    printf '  \033[32mok   \033[0m %-28s pass=%s\n' "$name" "$p"
  fi
done

echo
echo "================ 結果: PASS=$PASS  FAIL=$FAIL  ERROR(異常終了ファイル)=$ERRFILES ================"
[[ $FAIL -eq 0 && $ERRFILES -eq 0 && $PASS -gt 0 ]]
