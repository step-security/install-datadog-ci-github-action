#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.
set -euo pipefail

# shellcheck source=http.sh
source "${GITHUB_ACTION_PATH:-$(dirname "$0")}/http.sh"

version="$1"      # e.g. "v5.6.0"
binary_name="$2"  # e.g. "datadog-ci_linux-x64" (remote asset name, no .exe even for Windows)

# Alpine binaries were added in v5.18.0
if [[ "$binary_name" == datadog-ci_alpine-* ]]; then
  major=$(echo "$version" | sed 's/v\([0-9]*\).*/\1/')
  minor=$(echo "$version" | sed 's/v[0-9]*\.\([0-9]*\).*/\1/')
  if [[ "$major" -lt 5 || ( "$major" -eq 5 && "$minor" -lt 18 ) ]]; then
    echo "::error::Alpine/musl binaries require datadog-ci >= v5.18.0 (got ${version}). Pin a newer version to proceed."
    exit 1
  fi
fi

url="https://github.com/DataDog/datadog-ci/releases/download/${version}/${binary_name}"
dest_dir="${RUNNER_TOOL_CACHE:-${HOME}/.datadog-ci}/datadog-ci/${version}"

mkdir -p "$dest_dir"

# Determine local filename — add .exe on Windows for shell/OS association
if [[ "$RUNNER_OS" == "Windows" ]]; then
  dest_file="$dest_dir/datadog-ci.exe"
else
  dest_file="$dest_dir/datadog-ci"
fi

echo "Downloading ${url} → ${dest_file}"
if ! http_download "$url" "$dest_file"; then
  echo "::error::Failed to download datadog-ci ${version}. Verify the version exists: https://github.com/DataDog/datadog-ci/releases/tag/${version}"
  exit 1
fi

if [[ "$RUNNER_OS" != "Windows" ]]; then
  chmod +x "$dest_file"
fi

echo "Downloaded datadog-ci ${version}"
