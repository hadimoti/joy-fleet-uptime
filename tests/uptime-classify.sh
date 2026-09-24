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
assert_classification UNREACHABLE ERR 0 ''
assert_classification UNREACHABLE '' 0 ''
assert_classification UNREACHABLE garbage 0 ''
assert_classification UNREACHABLE 20 0 ''

# Per-target reduction table; UP clears earlier failures, then DOWN, then
# UNREACHABLE, with CHALLENGED only when every attempt was challenged.
assert_target_result() {
  local expected="$1" actual
  shift
  actual=$(uptime_reduce_attempts "$@")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected target result %s for attempts %s, got %s\n' "$expected" "$*" "$actual" >&2
    exit 1
  fi
}
assert_target_result UP DOWN UP
assert_target_result DOWN DOWN UNREACHABLE
assert_target_result UNREACHABLE CHALLENGED UNREACHABLE
assert_target_result UNREACHABLE UNREACHABLE CHALLENGED
assert_target_result CHALLENGED CHALLENGED CHALLENGED
assert_target_result UNREACHABLE UNREACHABLE

assert_verdict() {
  local expected="$1" actual
  shift
  actual=$(uptime_verdict "$@")
  if [ "$actual" != "$expected" ]; then
    printf 'Expected verdict %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_alert_decision() {
  local verdict="$1" expected="$2" actual=alert
  if uptime_should_alert "$verdict"; then actual=alert; else actual=no-alert; fi
  if [ "$actual" != "$expected" ]; then
    printf 'Expected %s for verdict %s, got %s\n' "$expected" "$verdict" "$actual" >&2
    exit 1
  fi
}

# Only successful health/challenge verdicts suppress alerts. Every failure
# verdict and crash fallback routes to Telegram.
for verdict in OK CHALLENGED ALL_CHALLENGED; do
  assert_alert_decision "$verdict" no-alert
done
for verdict in ORIGIN_DOWN ORIGIN_ONLY_DOWN NOT_READY CDN_EDGE PARTIAL \
  PROBE_INCONCLUSIVE PROBE_NETWORK PROBE_CRASH NEEDS_CONTROL UNKNOWN; do
  assert_alert_decision "$verdict" alert
done

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
CHALLENGED|200|200|0|403|CHALLENGED|UP|UP
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
CHALLENGED|CHALLENGED|200|0|403|CHALLENGED|CHALLENGED|CHALLENGED
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

# Twelve transport-only targets must never collapse to OK: an unreachable
# control means PROBE_NETWORK; an HTTP response resolves them as failures.
assert_verdict PROBE_NETWORK UNREACHABLE UNREACHABLE 7 000 \
  UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE \
  UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE
assert_verdict ORIGIN_DOWN UNREACHABLE UNREACHABLE 7 403 \
  UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE \
  UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE UNREACHABLE

# /ready challenge followed by HTTP 000 reduces to UNREACHABLE and cannot be
# green after the reachable control resolves that transport ambiguity.
assert_target_result UNREACHABLE CHALLENGED UNREACHABLE
assert_verdict NOT_READY 200 UNREACHABLE 7 403 UP UP UP

# A challenge is neutral evidence. It cannot turn the remaining timeout into
# an origin outage; with a reachable control, that timeout is only PARTIAL.
assert_verdict PARTIAL 200 200 0 403 CHALLENGED UNREACHABLE UP

# A CDN challenge is an inconclusive fleet verdict when otherwise healthy
# responses provide positive health evidence. Confirmed failures retain their
# higher priority.
assert_verdict CHALLENGED 200 200 0 403 UP CHALLENGED UP
assert_verdict PARTIAL 200 200 0 403 503 CHALLENGED UP
assert_verdict ORIGIN_ONLY_DOWN 503 200 0 403 CHALLENGED UP UP

# Only received ordinary HTTP failures enter down; challenge and transport
# outcomes have their own lists.
down_list=()
challenged_list=()
unreachable_list=()
uptime_record_cdn_result joy.example 403 down_list challenged_list unreachable_list
uptime_record_cdn_result challenge.example CHALLENGED down_list challenged_list unreachable_list
uptime_record_cdn_result timeout.example UNREACHABLE down_list challenged_list unreachable_list
uptime_record_cdn_result unavailable.example 503 down_list challenged_list unreachable_list
if [ "${down_list[*]}" != 'joy.example(403) unavailable.example(503)' ] || \
   [ "${challenged_list[*]}" != 'challenge.example' ] || \
   [ "${unreachable_list[*]}" != 'timeout.example' ]; then
  printf 'Expected confirmed failures, challenges, and unreachable hosts to use separate lists\n' >&2
  exit 1
fi

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
if [ "$(uptime_classify_file 000 "$file" 28)" != CHALLENGED ]; then
  printf 'Expected a challenge marker to classify as CHALLENGED at any status\n' >&2
  exit 1
fi

printf 'uptime classification contract: PASS\n'
