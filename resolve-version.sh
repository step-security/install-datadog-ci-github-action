#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.
set -euo pipefail

# shellcheck source=http.sh
source "${GITHUB_ACTION_PATH:-$(dirname "$0")}/http.sh"

requested_version="$1"

sanitize_message() {
  local message="$1"
  message=${message//$'\r'/ }
  message=${message//$'\n'/ }
  printf '%s' "$message"
}

json_payload_type() {
  local response_file="$1"

  if command -v jq &>/dev/null; then
    jq -r 'type' "$response_file" 2>/dev/null || echo "invalid-json"
    return
  fi

  local first_char
  first_char=$(awk '
    match($0, /[^[:space:]]/) {
      print substr($0, RSTART, 1)
      exit
    }
  ' "$response_file")

  case "$first_char" in
    '[') echo "array" ;;
    '{') echo "object" ;;
    '') echo "empty" ;;
    *) echo "unknown" ;;
  esac
}

json_error_message() {
  local response_file="$1"

  if command -v jq &>/dev/null; then
    jq -r 'if type == "object" and (.message? | type) == "string" then .message else empty end' "$response_file" 2>/dev/null || true
    return
  fi

  awk '
    /"message"[[:space:]]*:/ {
      message_line = $0
      sub(/.*"message"[[:space:]]*:[[:space:]]*"/, "", message_line)
      sub(/".*/, "", message_line)
      print message_line
      exit
    }
  ' "$response_file"
}

extract_release_versions() {
  local response_file="$1"

  if command -v jq &>/dev/null; then
    jq -r '
      if type == "array" then
        .[]
        | select(.draft != true and .prerelease != true and (.tag_name | type) == "string")
        | .tag_name
      else
        empty
      end
    ' "$response_file"
  else
    awk '
      /"tag_name"/ {
        tag_line = $0
        gsub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag_line)
        gsub(/".*/, "", tag_line)
        tag = tag_line
      }
      /"draft"[[:space:]]*:/ {
        draft = ($0 ~ /false/ ? "false" : "true")
        if (tag != "" && draft == "false" && prerelease == "false") {
          print tag
          tag = ""
          draft = ""
          prerelease = ""
        }
      }
      /"prerelease"[[:space:]]*:/ {
        prerelease = ($0 ~ /false/ ? "false" : "true")
        if (tag != "" && draft == "false" && prerelease == "false") {
          print tag
          tag = ""
          draft = ""
          prerelease = ""
        }
      }
    ' "$response_file"
  fi
}

should_retry_request() {
  local status_code="$1"
  local error_message

  error_message=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')

  if [[ "$status_code" == "429" || "$status_code" =~ ^5[0-9][0-9]$ ]]; then
    return 0
  fi

  if [[ "$status_code" == "403" && "$error_message" == *"rate limit"* ]]; then
    return 0
  fi

  return 1
}

if [[ "$requested_version" =~ ^v?[0-9]+$ ]]; then
  # Major version only (e.g., "v5" or "5") → resolve to the latest release within that major version.
  major="${requested_version#v}"

  api_url="https://api.github.com/repos/DataDog/datadog-ci/releases?per_page=100"
  headers=(
    "Accept: application/vnd.github+json"
    "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=("Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  max_attempts=4
  backoff_seconds=1
  all_versions=""

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    response_file=$(mktemp)
    if ! status_code=$(http_get_with_status "$response_file" "$api_url" ${headers[@]+"${headers[@]}"}); then
      rm -f "$response_file"

      if (( attempt < max_attempts )); then
        echo "::warning::Failed to query the GitHub Releases API while resolving datadog-ci v${major}. Retrying in ${backoff_seconds}s (attempt $((attempt + 1))/${max_attempts})."
        sleep "$backoff_seconds"
        backoff_seconds=$((backoff_seconds * 2))
        continue
      fi

      echo "::error::Failed to query the GitHub Releases API while resolving datadog-ci v${major}. Check network connectivity and GitHub API availability."
      exit 1
    fi

    api_message=$(sanitize_message "$(json_error_message "$response_file")")

    if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
      payload_type=$(json_payload_type "$response_file")
      if [[ "$payload_type" != "array" ]]; then
        error_message="Unexpected GitHub Releases API response while resolving datadog-ci v${major}: expected a JSON array but received ${payload_type}."
        if [[ -n "$api_message" ]]; then
          error_message+=" GitHub API message: ${api_message}."
        fi
        rm -f "$response_file"
        echo "::error::${error_message}"
        exit 1
      fi

      all_versions=$(extract_release_versions "$response_file")
      rm -f "$response_file"
      break
    fi

    if should_retry_request "$status_code" "$api_message" && (( attempt < max_attempts )); then
      retry_message="GitHub Releases API request returned HTTP ${status_code} while resolving datadog-ci v${major}."
      if [[ -n "$api_message" ]]; then
        retry_message+=" GitHub API message: ${api_message}."
      fi
      retry_message+=" Retrying in ${backoff_seconds}s (attempt $((attempt + 1))/${max_attempts})."
      rm -f "$response_file"
      echo "::warning::${retry_message}"
      sleep "$backoff_seconds"
      backoff_seconds=$((backoff_seconds * 2))
      continue
    fi

    error_message="GitHub Releases API request failed with HTTP ${status_code} while resolving datadog-ci v${major}."
    if [[ -n "$api_message" ]]; then
      error_message+=" GitHub API message: ${api_message}."
    fi
    rm -f "$response_file"
    echo "::error::${error_message}"
    exit 1
  done

  resolved_version=$(printf '%s\n' "$all_versions" | grep -E "^v${major}\." | head -n 1 || true)

  if [[ -z "$resolved_version" ]]; then
    echo "::error::Failed to resolve the latest stable v${major}.x datadog-ci version from GitHub Releases."
    exit 1
  fi

  echo "Resolved 'v${major}' → ${resolved_version}"
else
  resolved_version="$requested_version"
  echo "Using pinned version: ${resolved_version}"
fi

# Normalize: ensure it starts with 'v'
if [[ "$resolved_version" != v* ]]; then
  resolved_version="v${resolved_version}"
fi

echo "version=$resolved_version" >> "$GITHUB_OUTPUT"
