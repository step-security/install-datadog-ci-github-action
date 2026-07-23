#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.
set -euo pipefail

os="$RUNNER_OS"
arch="$RUNNER_ARCH"

case "$os" in
  Linux)   platform="linux" ;;
  macOS)   platform="darwin" ;;
  Windows) platform="win" ;;
  *)
    echo "::error::Unsupported operating system: $os. Supported: Linux, macOS, Windows."
    exit 1
    ;;
esac

case "$arch" in
  X64)   arch_suffix="x64" ;;
  ARM64) arch_suffix="arm64" ;;
  *)
    echo "::error::Unsupported architecture: $arch. Supported: X64, ARM64."
    exit 1
    ;;
esac

# Windows ARM64 has no published binary
if [[ "$platform" == "win" && "$arch_suffix" == "arm64" ]]; then
  echo "::error::Windows ARM64 is not supported. Only Windows X64 binaries are published."
  exit 1
fi

# Use Alpine (musl) binaries when running on Alpine Linux
if [[ "$platform" == "linux" ]] && { [[ -f /etc/alpine-release ]] || ldd /bin/sh 2>&1 | grep -q musl; }; then
  platform="alpine"
fi

# This is the remote asset name as uploaded to GitHub Releases.
# Note: the Windows asset is uploaded as "datadog-ci_win-x64" (without .exe)
# even though the local file produced by pkg has the .exe extension.
# The .exe suffix is added to the local filename in download.sh, not here.
binary_name="datadog-ci_${platform}-${arch_suffix}"

echo "Detected platform: ${platform}-${arch_suffix} → binary: ${binary_name}"
echo "binary-name=$binary_name" >> "$GITHUB_OUTPUT"
