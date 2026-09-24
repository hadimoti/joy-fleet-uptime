#!/usr/bin/env bash
set -euo pipefail
source .github/scripts/uptime-classify.sh

assert_classification() {
  local expected="$1" code="$2" curl_exit="$3" body="$4" actual
  actual=$(uptime_classify "$code" "$body" "$curl_exit")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected %s for HTTP %s with curl exit %s, got %s\n' "$expected" "$code" "$curl_exit" "$actual" >&2
    exit 1
  fi
}

assert_classification CHALLENGED 200 0 'challenge-running'
assert_classification CHALLENGED 200 0 '<script src="/cdn-cgi/challenge-platform/script.js"></script>'
assert_classification CHALLENGED 302 0 'Checking+your+browser'
assert_classification CHALLENGED 403 0 '<title>Just a moment...</title>'
assert_classification CHALLENGED 403 0 '<title>Attention Required! | Cloudflare</title>'
assert_classification CHALLENGED 403 0 'Please enable JavaScript and cookies to continue'
assert_classification CHALLENGED 200 0 'cf-chl-abc123'
assert_classification UP 200 0 '<meta content="Cloudflare"><title>Home</title>'
assert_classification UP 200 0 'Our service uses Cloudflare for performance.'
assert_classification UP 200 0 'ordinary successful response'
assert_classification UP 302 0 'ordinary redirect'
assert_classification DOWN 403 0 'ordinary forbidden response'
assert_classification DOWN 503 0 'ordinary unavailable response'
assert_classification DOWN 503 18 'truncated unavailable response'
assert_classification DOWN 503 28 'slow unavailable response'
assert_classification UP 200 28 ''
assert_classification UNREACHABLE 000 0 ''
assert_classification UP 200 7 'partial body'
assert_classification UNKNOWN ERR 0 ''

# Retry evidence: a received HTTP failure beats a later transport-only 000.
assert_retry_failure() {
  local expected="$1" actual
  actual=$(uptime_keep_http_failure "${2:-}" "$3" "$4")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected retry evidence %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}
assert_retry_failure 503 '' 503 DOWN
assert_retry_failure 503 503 000 UNREACHABLE

assert_verdict() {
  local expected="$1" actual
  shift
  actual=$(uptime_verdict "$@")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected verdict %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

# Verdict table: expected, origin, /ready, control curl exit, control HTTP,
# then one result for each CDN. A control exit of -1 asks whether control is
# needed; the classifier returns NEEDS_CONTROL only when timeouts can change
# the verdict.
while IFS='|' read -r expected origin ready control_exit control_code cdn1 cdn2 cdn3; do
  [ -n "$expected" ] || continue
  assert_verdict "$expected" "$origin" "$ready" "$control_exit" "$control_code" \
    "$cdn1" "$cdn2" "$cdn3"
done <<'VERDICTS'
OK|200|200|0|403|UP|UP|UP
CHALLENGED|CHALLENGED|200|0|403|UP|UP|UP
ALL_CHALLENGED|200|200|0|403|CHALLENGED|CHALLENGED|CHALLENGED
CDN_EDGE|200|200|0|403|503|503|UP
ORIGIN_ONLY_DOWN|503|200|0|403|UP|UP|UP
ORIGIN_DOWN|503|200|0|403|503|UP|UP
NOT_READY|200|503|0|403|UP|UP|UP
NEEDS_CONTROL|UNREACHABLE|200|-1|000|UP|UP|UP
ORIGIN_ONLY_DOWN|UNREACHABLE|200|0|403|UP|UP|UP
ORIGIN_ONLY_DOWN|503|200|7|000|UP|UNREACHABLE|UP
PARTIAL|200|200|7|000|503|UNREACHABLE|UP
NOT_READY|200|503|7|000|UP|UNREACHABLE|UP
PROBE_NETWORK|UNREACHABLE|UNREACHABLE|7|000|UNREACHABLE|UNREACHABLE|UNREACHABLE
ORIGIN_ONLY_DOWN|UNREACHABLE|200|56|403|UP|UP|UP
ORIGIN_DOWN|503|200|28|000|503|503|UP
NOT_READY|200|503|0|403|503|503|UP
CDN_EDGE|200|200|0|403|503|503|UP
PROBE_INCONCLUSIVE|CHALLENGED|200|7|000|UNREACHABLE|UP|UP
PROBE_INCONCLUSIVE|200|200|7|000|CHALLENGED|UNREACHABLE|UP
PARTIAL|CHALLENGED|200|0|403|UNREACHABLE|UP|UP
ALL_CHALLENGED|200|200|0|403|CHALLENGED|CHALLENGED|CHALLENGED
PROBE_INCONCLUSIVE|CHALLENGED|CHALLENGED|0|403|CHALLENGED|CHALLENGED|CHALLENGED
ORIGIN_ONLY_DOWN|503|503|7|000|UP|UP|UP
VERDICTS

# Exact two-CDN regression: one successful HTTP response and one timeout must
# not hide the confirmed origin failure when the control host is unreachable.
assert_verdict ORIGIN_ONLY_DOWN 503 200 7 000 UP UNREACHABLE

# A reached control host resolves transport ambiguity despite curl reporting a
# partial-transfer error. Its HTTP 403 is still evidence of connectivity.
assert_verdict ORIGIN_ONLY_DOWN UNREACHABLE 200 56 403 UP UP

# An HTTP response proves connectivity regardless of its HTTP status or a
# later curl transfer error. In
# particular, GitHub's unauthenticated API may answer with 403 or 429.
assert_verdict ORIGIN_DOWN UNREACHABLE UNREACHABLE 0 403 UNREACHABLE
assert_verdict ORIGIN_DOWN UNREACHABLE UNREACHABLE 0 429 UNREACHABLE

# A challenge is neutral evidence. It cannot turn the remaining timeout into
# an origin outage; with a reachable control, that timeout is only PARTIAL.
assert_verdict PARTIAL 200 200 0 403 CHALLENGED UNREACHABLE UP

file=$(mktemp)
trap 'rm -f "$file"' EXIT
printf '%s' 'ordinary content followed by checking+your+browser' > "$file"
if [ "$(uptime_classify_file 200 "$file")" != CHALLENGED ]; then
  printf 'Expected file classifier to find a marker beyond the initial body prefix\n' >&2
  exit 1
fi
printf '%s' '<meta content="Cloudflare"><title>Home</title>' > "$file"
if [ "$(uptime_classify_file 200 "$file")" != UP ]; then
  printf 'Expected normal Cloudflare-branded HTML to remain UP\n' >&2
  exit 1
fi
printf '%s' 'A normal page explaining that we use Cloudflare.' > "$file"
if [ "$(uptime_classify_file 200 "$file")" != UP ]; then
  printf 'Expected ordinary Cloudflare mention to remain UP\n' >&2
  exit 1
fi
printf '%s' '<title>Just a moment...</title><div class="cf-ray">abc</div>' > "$file"
if [ "$(uptime_classify_file 403 "$file")" != CHALLENGED ]; then
  printf 'Expected a real 403 interstitial fixture to be CHALLENGED\n' >&2
  exit 1
fi
printf '%s' '<title>Just a moment...</title>' > "$file"
if [ "$(uptime_classify_file 200 "$file")" != CHALLENGED ]; then
  printf 'Expected a real 200 interstitial fixture to be CHALLENGED\n' >&2
  exit 1
fi
printf '%s' 'ordinary response' > "$file"
if [ "$(uptime_classify_file 403 "$file")" != DOWN ]; then
  printf 'Expected an unmarked HTTP 403 to remain DOWN\n' >&2
  exit 1
fi
printf '%s' '<title>Just a moment...</title>' > "$file"
if [ "$(uptime_classify_file 503 "$file" 28)" != CHALLENGED ]; then
  printf 'Expected a received status and partial challenge body to remain CHALLENGED after curl error\n' >&2
  exit 1
fi
if [ "$(uptime_classify_file 000 "$file" 28)" != UNREACHABLE ]; then
  printf 'Expected curl transport failure to be UNREACHABLE\n' >&2
  exit 1
fi

printf 'uptime classification contract: PASS\n'
