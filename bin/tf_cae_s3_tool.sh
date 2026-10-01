#!/bin/bash
# A drop-in `cae_s3_tool` for PUBLIC buckets, satisfying the contract CAE's
# S3FileAssimilator invokes:
#
#     <tool> get <bucket> <key> <dest> [range_off range_size]
#     exit 0 on success
#
# CAE builds its own helper only when CAE_ENABLE_S3=ON, which needs the AWS SDK
# for C++. That SDK is not installed here, and for an anonymous public bucket
# none of it is required -- the assimilator deliberately shells out precisely so
# the SDK is not loaded into the runtime process, and that same boundary lets
# this stand in. Point CAE at it with:
#
#     export CAE_S3_TOOL=$PWD/bin/tf_cae_s3_tool.sh
#
# TF_S3_KEEP, if set, receives a hardlink to the downloaded object. CAE unlinks
# the temp file as soon as it has opened it, so without this the bytes are gone
# the moment the ingest finishes; a hardlink keeps them at no extra space.
set -uo pipefail

REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}

[ "${1:-}" = "get" ] || { echo "usage: $0 get <bucket> <key> <dest> [off len]" >&2; exit 2; }
bucket=${2:?bucket}; key=${3:?key}; dest=${4:?dest}
off=${5:-}; len=${6:-}

url="https://${bucket}.s3.${REGION}.amazonaws.com/${key}"
args=(-sS -f -L -o "$dest" --retry 5 --retry-delay 3 --retry-connrefused)
if [ -n "$off" ] && [ -n "$len" ] && [ "$len" != "0" ]; then
  args+=(-r "${off}-$(( off + len - 1 ))")
fi

t0=$SECONDS
curl "${args[@]}" "$url" || { echo "curl failed for s3://${bucket}/${key}" >&2; exit 1; }
sz=$(stat -c %s "$dest" 2>/dev/null || echo 0)
echo "cae_s3_tool: s3://${bucket}/${key} -> ${sz} bytes in $((SECONDS-t0))s" >&2

if [ -n "${TF_S3_KEEP:-}" ]; then
  ln -f "$dest" "$TF_S3_KEEP" 2>/dev/null \
    && echo "cae_s3_tool: kept a hardlink at $TF_S3_KEEP" >&2 \
    || echo "cae_s3_tool: WARNING could not hardlink to $TF_S3_KEEP (different filesystem?)" >&2
fi
exit 0
