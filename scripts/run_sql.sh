#!/usr/bin/env bash
# SQLファイル中の ${BUCKET} と ${ROLE_ARN} を環境変数で置き換えて snow sql で実行する
# 使い方: SF_CONN=<コネクション名> ./scripts/run_sql.sh sql/02_integration.sql
set -euo pipefail

file="$1"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 置き換える変数を明示し、$$ や METADATA$FILENAME を壊さないようにする
envsubst '${BUCKET} ${ROLE_ARN}' < "$file" > "$tmp"
snow sql -c "${SF_CONN:-default}" -f "$tmp"
