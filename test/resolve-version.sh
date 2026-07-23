#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2024-present Datadog, Inc.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP_DIRS=()
TEST_FAILURES=0

cleanup() {
  if ((${#TEST_TMP_DIRS[@]} == 0)); then
    return
  fi

  for dir in "${TEST_TMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}

trap cleanup EXIT

fail() {
  local message="$1"
  echo "not ok - ${message}"
  TEST_FAILURES=$((TEST_FAILURES + 1))
}

pass() {
  local message="$1"
  echo "ok - ${message}"
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail "${message}: expected '${expected}', got '${actual}'"
    return 1
  fi

  return 0
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message}: expected output to contain '${needle}'"
    return 1
  fi

  return 0
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${message}: output unexpectedly contained '${needle}'"
    return 1
  fi

  return 0
}

link_tool() {
  local bin_dir="$1"
  local command_name="$2"
  ln -s "$(command -v "$command_name")" "$bin_dir/$command_name"
}

write_fake_sleep() {
  local bin_dir="$1"

  cat >"$bin_dir/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_SLEEP_LOG:-}" ]]; then
  printf '%s\n' "${1:-0}" >> "$FAKE_SLEEP_LOG"
fi
exit 0
EOF
  chmod +x "$bin_dir/sleep"
}

write_fake_curl() {
  local bin_dir="$1"

  cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
write_format=""
url=""

while (($#)); do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    -w)
      write_format="$2"
      shift 2
      ;;
    -H)
      if [[ -n "${FAKE_HTTP_HEADERS_LOG:-}" ]]; then
        printf '%s\n' "$2" >> "$FAKE_HTTP_HEADERS_LOG"
      fi
      shift 2
      ;;
    -s|-S|-L)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

counter=$(<"$FAKE_HTTP_DIR/counter")
counter=$((counter + 1))
printf '%s' "$counter" >"$FAKE_HTTP_DIR/counter"

if [[ -n "${FAKE_HTTP_URL_LOG:-}" ]]; then
  printf '%s\n' "$url" >> "$FAKE_HTTP_URL_LOG"
fi

status=$(<"$FAKE_HTTP_DIR/${counter}.status")
exit_code=$(<"$FAKE_HTTP_DIR/${counter}.exit")
body_file="$FAKE_HTTP_DIR/${counter}.body"

if [[ -n "$output_file" ]]; then
  cat "$body_file" >"$output_file"
else
  cat "$body_file"
fi

if [[ -n "$write_format" ]]; then
  printf '%s' "${write_format//\%\{http_code\}/$status}"
fi

exit "$exit_code"
EOF
  chmod +x "$bin_dir/curl"
}

write_fake_wget() {
  local bin_dir="$1"

  cat >"$bin_dir/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""

while (($#)); do
  case "$1" in
    --header=*)
      if [[ -n "${FAKE_HTTP_HEADERS_LOG:-}" ]]; then
        printf '%s\n' "${1#--header=}" >> "$FAKE_HTTP_HEADERS_LOG"
      fi
      shift
      ;;
    --no-verbose|--server-response|--content-on-error|-O-)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

counter=$(<"$FAKE_HTTP_DIR/counter")
counter=$((counter + 1))
printf '%s' "$counter" >"$FAKE_HTTP_DIR/counter"

if [[ -n "${FAKE_HTTP_URL_LOG:-}" ]]; then
  printf '%s\n' "$url" >> "$FAKE_HTTP_URL_LOG"
fi

status=$(<"$FAKE_HTTP_DIR/${counter}.status")
exit_code=$(<"$FAKE_HTTP_DIR/${counter}.exit")
body_file="$FAKE_HTTP_DIR/${counter}.body"

printf '  HTTP/1.1 %s Fake\r\n' "$status" >&2
cat "$body_file"
exit "$exit_code"
EOF
  chmod +x "$bin_dir/wget"
}

setup_env() {
  local include_jq="$1"
  local include_curl="$2"
  local include_wget="$3"
  local env_dir
  local bin_dir

  env_dir=$(mktemp -d)
  TEST_TMP_DIRS+=("$env_dir")
  bin_dir="$env_dir/bin"

  mkdir -p "$bin_dir" "$env_dir/http"
  printf '0' >"$env_dir/http/counter"
  : >"$env_dir/headers.log"
  : >"$env_dir/urls.log"
  : >"$env_dir/sleep.log"

  for command_name in awk bash cat dirname grep head mktemp rm tr; do
    link_tool "$bin_dir" "$command_name"
  done

  write_fake_sleep "$bin_dir"

  if [[ "$include_jq" == "1" ]]; then
    link_tool "$bin_dir" "jq"
  fi

  if [[ "$include_curl" == "1" ]]; then
    write_fake_curl "$bin_dir"
  fi

  if [[ "$include_wget" == "1" ]]; then
    write_fake_wget "$bin_dir"
  fi

  printf '%s\n' "$env_dir"
}

add_response() {
  local env_dir="$1"
  local index="$2"
  local status="$3"
  local exit_code="$4"
  local body="$5"

  printf '%s' "$status" >"$env_dir/http/${index}.status"
  printf '%s' "$exit_code" >"$env_dir/http/${index}.exit"
  printf '%s' "$body" >"$env_dir/http/${index}.body"
}

run_resolver() {
  local env_dir="$1"
  local requested_version="$2"
  local github_token="${3:-}"
  local stdout_file="$env_dir/stdout.log"
  local stderr_file="$env_dir/stderr.log"
  local output_file="$env_dir/github_output"

  set +e
  PATH="$env_dir/bin" \
    GITHUB_ACTION_PATH="$ROOT_DIR" \
    GITHUB_OUTPUT="$output_file" \
    GITHUB_TOKEN="$github_token" \
    FAKE_HTTP_DIR="$env_dir/http" \
    FAKE_HTTP_HEADERS_LOG="$env_dir/headers.log" \
    FAKE_HTTP_URL_LOG="$env_dir/urls.log" \
    FAKE_SLEEP_LOG="$env_dir/sleep.log" \
    bash "$ROOT_DIR/resolve-version.sh" "$requested_version" >"$stdout_file" 2>"$stderr_file"
  RUN_EXIT_CODE=$?
  set -e

  RUN_STDOUT="$(cat "$stdout_file")"
  RUN_STDERR="$(cat "$stderr_file")"
  RUN_OUTPUT=""
  if [[ -f "$output_file" ]]; then
    RUN_OUTPUT="$(cat "$output_file")"
  fi
  RUN_LOG="${RUN_STDOUT}"$'\n'"${RUN_STDERR}"
}

test_resolves_latest_major_with_jq() {
  local env_dir
  env_dir=$(setup_env 1 1 0)

  add_response "$env_dir" 1 200 0 '[
    {"tag_name":"v5.7.0","draft":false,"prerelease":false},
    {"tag_name":"v5.7.0-rc.1","draft":false,"prerelease":true},
    {"tag_name":"v4.9.0","draft":false,"prerelease":false}
  ]'

  run_resolver "$env_dir" "v5" "test-token"

  assert_equals "$RUN_EXIT_CODE" "0" "jq path should succeed" || return
  assert_contains "$RUN_OUTPUT" "version=v5.7.0" "jq path should resolve the latest stable major version" || return
  assert_contains "$(cat "$env_dir/headers.log")" "Authorization: Bearer" "jq path should send the GitHub token" || return
  assert_contains "$(cat "$env_dir/urls.log")" "https://api.github.com/repos/DataDog/datadog-ci/releases?per_page=100" "jq path should query the GitHub releases endpoint" || return
  pass "resolves latest major version with jq"
}

test_retries_server_errors_and_succeeds() {
  local env_dir
  env_dir=$(setup_env 1 1 0)

  add_response "$env_dir" 1 500 0 '{"message":"GitHub is having problems"}'
  add_response "$env_dir" 2 200 0 '[
    {"tag_name":"v5.8.0","draft":false,"prerelease":false}
  ]'

  run_resolver "$env_dir" "v5"

  assert_equals "$RUN_EXIT_CODE" "0" "resolver should retry transient server errors" || return
  assert_contains "$RUN_OUTPUT" "version=v5.8.0" "resolver should succeed after retrying a transient server error" || return
  assert_contains "$RUN_LOG" "Retrying in 1s (attempt 2/4)." "resolver should emit a retry warning" || return
  assert_contains "$(cat "$env_dir/sleep.log")" "1" "resolver should back off before retrying" || return
  pass "retries transient server errors"
}

test_reports_rate_limit_errors_cleanly() {
  local env_dir
  env_dir=$(setup_env 1 1 0)

  add_response "$env_dir" 1 403 0 '{"message":"API rate limit exceeded"}'
  add_response "$env_dir" 2 403 0 '{"message":"API rate limit exceeded"}'
  add_response "$env_dir" 3 403 0 '{"message":"API rate limit exceeded"}'
  add_response "$env_dir" 4 403 0 '{"message":"API rate limit exceeded"}'

  run_resolver "$env_dir" "v5"

  assert_equals "$RUN_EXIT_CODE" "1" "resolver should fail after exhausting rate-limit retries" || return
  assert_contains "$RUN_LOG" "API rate limit exceeded" "resolver should surface the GitHub API message" || return
  assert_not_contains "$RUN_LOG" 'Cannot index string with string "prerelease"' "resolver should not leak raw jq errors" || return
  pass "reports rate-limit errors cleanly"
}

test_reports_rate_limit_errors_cleanly_without_jq() {
  local env_dir
  env_dir=$(setup_env 0 1 0)

  add_response "$env_dir" 1 403 0 '{"message":"API RATE LIMIT EXCEEDED"}'
  add_response "$env_dir" 2 403 0 '{"message":"API RATE LIMIT EXCEEDED"}'
  add_response "$env_dir" 3 403 0 '{"message":"API RATE LIMIT EXCEEDED"}'
  add_response "$env_dir" 4 403 0 '{"message":"API RATE LIMIT EXCEEDED"}'

  run_resolver "$env_dir" "v5"

  assert_equals "$RUN_EXIT_CODE" "1" "resolver should fail after exhausting rate-limit retries without jq" || return
  assert_contains "$RUN_LOG" "API RATE LIMIT EXCEEDED" "resolver should surface the GitHub API message without jq" || return
  assert_contains "$RUN_LOG" "Retrying in 1s (attempt 2/4)." "resolver should retry rate-limit errors without jq" || return
  assert_not_contains "$RUN_LOG" "awk: syntax error" "resolver should not use gawk-only syntax without jq" || return
  pass "reports rate-limit errors cleanly without jq"
}

test_reports_unexpected_payload_shape_with_jq() {
  local env_dir
  env_dir=$(setup_env 1 1 0)

  add_response "$env_dir" 1 200 0 '{"message":"not an array"}'

  run_resolver "$env_dir" "v5"

  assert_equals "$RUN_EXIT_CODE" "1" "resolver should reject non-array payloads when jq is available" || return
  assert_contains "$RUN_LOG" "expected a JSON array but received object" "resolver should explain invalid payload shapes when jq is available" || return
  assert_not_contains "$RUN_LOG" 'Cannot index string with string "prerelease"' "resolver should not leak jq shape errors" || return
  pass "rejects non-array payloads with jq"
}

test_reports_unexpected_payload_shape_without_jq() {
  local env_dir
  env_dir=$(setup_env 0 1 0)

  add_response "$env_dir" 1 200 0 '{"message":"not an array"}'

  run_resolver "$env_dir" "v5"

  assert_equals "$RUN_EXIT_CODE" "1" "resolver should reject non-array payloads without jq" || return
  assert_contains "$RUN_LOG" "expected a JSON array but received object" "resolver should explain invalid payload shapes without jq" || return
  pass "rejects non-array payloads without jq"
}

test_retries_with_wget_and_awk_fallback() {
  local env_dir
  env_dir=$(setup_env 0 0 1)

  add_response "$env_dir" 1 429 8 '{"message":"Too Many Requests"}'
  add_response "$env_dir" 2 200 0 '[
    {"tag_name":"v5.9.0","draft":false,"prerelease":false}
  ]'

  run_resolver "$env_dir" "v5" "wget-token"

  assert_equals "$RUN_EXIT_CODE" "0" "resolver should retry 429 responses with wget" || return
  assert_contains "$RUN_OUTPUT" "version=v5.9.0" "resolver should succeed after retrying a 429 response with wget" || return
  assert_contains "$RUN_LOG" "Retrying in 1s (attempt 2/4)." "resolver should emit retry warnings for wget-based requests" || return
  assert_contains "$(cat "$env_dir/headers.log")" "Authorization: Bearer" "wget path should send the GitHub token" || return
  pass "retries with wget and awk fallback"
}

test_pinned_versions_skip_api_lookup() {
  local env_dir
  env_dir=$(setup_env 1 1 0)

  run_resolver "$env_dir" "v5.6.0"

  assert_equals "$RUN_EXIT_CODE" "0" "pinned versions should succeed" || return
  assert_contains "$RUN_OUTPUT" "version=v5.6.0" "pinned versions should be written to GITHUB_OUTPUT unchanged" || return
  assert_equals "$(cat "$env_dir/http/counter")" "0" "pinned versions should not call the GitHub releases API" || return
  pass "pinned versions skip API lookup"
}

main() {
  test_resolves_latest_major_with_jq
  test_retries_server_errors_and_succeeds
  test_reports_rate_limit_errors_cleanly
  test_reports_rate_limit_errors_cleanly_without_jq
  test_reports_unexpected_payload_shape_with_jq
  test_reports_unexpected_payload_shape_without_jq
  test_retries_with_wget_and_awk_fallback
  test_pinned_versions_skip_api_lookup

  if ((TEST_FAILURES > 0)); then
    echo "${TEST_FAILURES} test(s) failed"
    exit 1
  fi

  echo "All resolve-version tests passed"
}

main "$@"
