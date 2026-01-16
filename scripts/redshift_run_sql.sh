#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/redshift_run_sql.sh path/to/query.sql
#
# Required env vars:
#   RS_REGION   (e.g. eu-west-1)
#   RS_CLUSTER  (e.g. dwhcluster1)
#   RS_DB       (e.g. renmoney)
#   RS_DB_USER  (e.g. renheimdall)
#
# Optional env vars:
#   AWS_PROFILE
#   RS_OUT_DIR   (default: out)   - directory for CSV outputs

SQL_FILE="${1:-}"
if [[ -z "$SQL_FILE" ]]; then
  echo "ERROR: Provide path to .sql file."
  echo "Example: ./scripts/redshift_run_sql.sh cte/client_list.sql"
  exit 1
fi
if [[ ! -f "$SQL_FILE" ]]; then
  echo "ERROR: File not found: $SQL_FILE"
  exit 1
fi

: "${RS_REGION:?Set RS_REGION (e.g. eu-west-1)}"
: "${RS_CLUSTER:?Set RS_CLUSTER (e.g. dwhcluster1)}"
: "${RS_DB:?Set RS_DB (e.g. renmoney)}"
: "${RS_DB_USER:?Set RS_DB_USER (e.g. renheimdall)}"

RS_OUT_DIR="${RS_OUT_DIR:-out}"
mkdir -p "$RS_OUT_DIR"

AWS_BASE=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_BASE+=(--profile "$AWS_PROFILE")
fi
AWS_BASE+=(redshift-data --region "$RS_REGION")

SQL_TEXT="$(cat "$SQL_FILE")"

REQ_ID="$("${AWS_BASE[@]}" execute-statement \
  --cluster-identifier "$RS_CLUSTER" \
  --database "$RS_DB" \
  --db-user "$RS_DB_USER" \
  --sql "$SQL_TEXT" \
| python -c 'import sys, json; print(json.load(sys.stdin)["Id"])')"

echo "Statement ID: $REQ_ID"
echo "Running: $SQL_FILE"
echo "----------------------------------------"

DESC_JSON=""
HAS_RS="false"

while true; do
  DESC_JSON="$("${AWS_BASE[@]}" describe-statement --id "$REQ_ID")"
  STATUS="$(python -c 'import sys,json; d=json.loads(sys.argv[1]); print(d.get("Status",""))' "$DESC_JSON")"
  HAS_RS="$(python -c 'import sys,json; d=json.loads(sys.argv[1]); print(str(d.get("HasResultSet", False)).lower())' "$DESC_JSON")"
  ERROR_MSG="$(python -c 'import sys,json; d=json.loads(sys.argv[1]); print(d.get("Error",""))' "$DESC_JSON")"

  if [[ "$STATUS" == "FINISHED" ]]; then
    echo "Status: FINISHED"
    break
  fi

  if [[ "$STATUS" == "FAILED" || "$STATUS" == "ABORTED" ]]; then
    echo "Status: $STATUS"
    echo "----------------------------------------"
    echo "FAILED: $ERROR_MSG"
    echo "$DESC_JSON" | python -m json.tool
    exit 1
  fi

  sleep 1
done

echo "----------------------------------------"

# If it is not a SELECT (no result set), finish quietly
if [[ "$HAS_RS" != "true" ]]; then
  echo "No result set (DDL/DML). Nothing to export."
  exit 0
fi

# Output CSV file name: out/<sqlfile>__<statement_id>.csv
BASE="$(basename "$SQL_FILE" .sql)"
OUT_FILE="${RS_OUT_DIR}/${BASE}__${REQ_ID}.csv"

TMP_JSON="$(mktemp)"
TMP_ERR="$(mktemp)"

set +e
"${AWS_BASE[@]}" get-statement-result --id "$REQ_ID" >"$TMP_JSON" 2>"$TMP_ERR"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo "ERROR: get-statement-result failed (exit code $RC)"
  echo "stderr:"
  cat "$TMP_ERR"
  rm -f "$TMP_JSON" "$TMP_ERR"
  exit $RC
fi

python - << 'EOF' "$TMP_JSON" "$OUT_FILE"
import sys, json, csv

json_path, out_path = sys.argv[1], sys.argv[2]
data = json.load(open(json_path, "r", encoding="utf-8"))

cols = [c["name"] for c in data["ColumnMetadata"]]
rows = data["Records"]

def cell_to_val(cell):
    if not cell:
        return None
    return next(iter(cell.values()))

with open(out_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    for r in rows:
        w.writerow([cell_to_val(c) for c in r])

EOF

rm -f "$TMP_JSON" "$TMP_ERR"

echo "Saved CSV: $OUT_FILE"
