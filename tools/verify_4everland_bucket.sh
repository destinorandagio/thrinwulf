#!/usr/bin/env bash
set -euo pipefail
: "${FOUREVER_BUCKET:?missing FOUREVER_BUCKET}"
: "${FOUREVER_IMAGE_PREFIX:?missing FOUREVER_IMAGE_PREFIX}"
: "${AWS_ACCESS_KEY_ID:?missing 4EVERLAND access key}"
: "${AWS_SECRET_ACCESS_KEY:?missing 4EVERLAND secret key}"
endpoint="https://endpoint.4everland.co"
report="${1:-4everland-ipfs-report.tsv}"
objects="$(mktemp)"
aws --endpoint-url "$endpoint" s3api list-objects-v2 --bucket "$FOUREVER_BUCKET" --prefix "$FOUREVER_IMAGE_PREFIX" --output json > "$objects"
count="$(jq '[.Contents[]|select(.Key|test("\\.(png|jpg|jpeg|webp)$";"i"))]|length' "$objects")"
bytes="$(jq '[.Contents[]|select(.Key|test("\\.(png|jpg|jpeg|webp)$";"i"))|.Size]|add//0' "$objects")"
if [ "$count" -ne 1652 ]; then echo "Expected 1652 final images, found $count" >&2; exit 1; fi
printf 'key\tsize\tipfs_cid\n' > "$report"
jq -r '.Contents[]|select(.Key|test("\\.(png|jpg|jpeg|webp)$";"i"))|[.Key,.Size]|@tsv' "$objects" | while IFS=$'\t' read -r key size; do
  cid="$(aws --endpoint-url "$endpoint" s3api head-object --bucket "$FOUREVER_BUCKET" --key "$key" --query 'Metadata."ipfs-hash"' --output text)"
  if [ -z "$cid" ] || [ "$cid" = None ]; then echo "Missing IPFS CID: $key" >&2; exit 1; fi
  printf '%s\t%s\t%s\n' "$key" "$size" "$cid" >> "$report"
done
unique="$(tail -n +2 "$report" | cut -f3 | sort -u | wc -l | tr -d ' ')"
if [ "$unique" -ne 1652 ]; then echo "Expected 1652 unique CIDs, found $unique" >&2; exit 1; fi
sha256sum "$report" > "$report.sha256"
jq -n --argjson files "$count" --argjson bytes "$bytes" --arg report_sha256 "$(cut -d' ' -f1 "$report.sha256")" '{status:"PASS",provider:"4EVERLAND",final_images:$files,total_bytes:$bytes,unique_ipfs_cids:$files,report_sha256:$report_sha256}'
