#!/usr/bin/env bash
set -euo pipefail
source .github/scripts/uptime-classify.sh

assert_classification() {
  local expected="$1" code="$2" body="$3" actual
  actual=$(uptime_classify "$code" "$body")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected %s for HTTP %s, got %s\n' "$expected" "$code" "$actual" >&2
    exit 1
  fi
}

assert_classification CHALLENGED 200 'Cloudflare challenge-running'
assert_classification CHALLENGED 302 'Checking+your+browser'
assert_classification CHALLENGED 403 'CF-CHL-BYPASS'
assert_classification CHALLENGED 503 'Please enable JavaScript'
assert_classification CHALLENGED 200 'Attention Required ray id'
assert_classification CHALLENGED 200 '<title>Cloudflare</title>'
assert_classification UP 200 'ordinary successful response'
assert_classification UP 302 'ordinary redirect'
assert_classification DOWN 403 'ordinary forbidden response'
assert_classification DOWN 503 'ordinary unavailable response'
assert_classification DOWN 000 ''
assert_classification UNKNOWN ERR ''

file=$(mktemp)
trap 'rm -f "$file"' EXIT
printf '%s' 'ordinary content followed by checking+your+browser' > "$file"
if [ "$(uptime_classify_file 200 "$file")" != CHALLENGED ]; then
  printf 'Expected file classifier to find a marker beyond the initial body prefix\n' >&2
  exit 1
fi
printf '%s' 'ordinary response' > "$file"
if [ "$(uptime_classify_file 403 "$file")" != DOWN ]; then
  printf 'Expected an unmarked HTTP 403 to remain DOWN\n' >&2
  exit 1
fi

printf 'uptime classification contract: PASS\n'
