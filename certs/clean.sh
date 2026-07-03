#!/bin/bash
#
# Remove every artifact produced by create-certs.sh so the next run
# generates a fresh CA and fresh leaf certificates. Safe to re-run.

set -eu
cd "$(dirname "$0")"

if [ -d out ]; then
  echo ">>> Removing $(pwd)/out"
  rm -rf out
fi

echo ">>> Done."
