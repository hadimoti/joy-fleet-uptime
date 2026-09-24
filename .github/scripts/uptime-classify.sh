#!/usr/bin/env bash
# Shared HTTP response classification for the uptime workflow and offline test.

uptime_file_is_challenge() {
  local file="$1"
  # These are Cloudflare interstitial fingerprints: challenge internals, its
  # dedicated challenge-running state, or the exact titles/text shown to a
  # blocked browser. A normal mention of Cloudflare or a cf-ray header alone
  # is not evidence of a challenge.
  tr '[:upper:]' '[:lower:]' < "$file" | grep -iE \
    'cf-chl-|challenge-platform|challenge-running|<title[^>]*>[[:space:]]*just a moment\.\.\.[[:space:]]*</title>|<title[^>]*>[[:space:]]*attention required!?[[:space:]]*\|[[:space:]]*cloudflare[[:space:]]*</title>|checking[ +]your[ +]browser|please[ +]enable[ +]javascript[ +]and[ +]cookies' >/dev/null
}

uptime_body_is_challenge() {
  local body="${1:-}" file
  file=$(mktemp)
  printf '%s' "$body" > "$file"
  if uptime_file_is_challenge "$file"; then
    rm -f "$file"
    return 0
  fi
  rm -f "$file"
  return 1
}

uptime_classify() {
  local code="${1:-}" body="${2:-}" curl_exit="${3:-0}"
  # Only classify a page as challenged when an HTTP response was received.
  if [ "$curl_exit" -eq 0 ] && [ "$code" != "000" ] && uptime_body_is_challenge "$body"; then
    echo CHALLENGED
    return
  fi
  # curl exit failures and HTTP 000 mean no HTTP response was obtained. Keep
  # these separate so the workflow can check runner connectivity first.
  if [ "$curl_exit" -ne 0 ] || [ "$code" = "000" ]; then
    echo UNREACHABLE
    return
  fi
  case "$code" in
    2*|3*) echo UP ;;
    4*|5*) echo DOWN ;;
    ERR|'') echo UNKNOWN ;;
    *) echo UNKNOWN ;;
  esac
}

uptime_classify_file() {
  local code="${1:-}" file="${2:-}" curl_exit="${3:-0}"
  if [ -n "$file" ] && [ "$curl_exit" -eq 0 ] && [ "$code" != "000" ] && uptime_file_is_challenge "$file"; then
    echo CHALLENGED
  else
    uptime_classify "$code" "" "$curl_exit"
  fi
}
