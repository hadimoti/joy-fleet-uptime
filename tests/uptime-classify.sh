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
assert_classification UNREACHABLE 000 0 ''
assert_classification UNREACHABLE 200 7 'partial body'
assert_classification UNKNOWN ERR 0 ''

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
if [ "$(uptime_classify_file 000 "$file" 28)" != UNREACHABLE ]; then
  printf 'Expected curl transport failure to be UNREACHABLE\n' >&2
  exit 1
fi

printf 'uptime classification contract: PASS\n'
