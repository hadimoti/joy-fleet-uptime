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

# Produce the fleet verdict for one interpretation of transport-ambiguous
# targets. "exclude" preserves only confirmed HTTP evidence; "down" treats
# UNREACHABLE targets as endpoint failures (after the control host reached HTTP).
uptime_verdict_for() {
  local unreachable_mode="$1" origin_code="$2" ready_code="$3"
  shift 3
  local -a cdn_codes=("$@")
  local n_down=0 n_chal=0 n_answered n_total=${#cdn_codes[@]}
  local origin_ok=0 origin_failed=0 origin_challenged=0
  local ready_ok=0 ready_failed=0 ready_challenged=0
  local code

  for code in "${cdn_codes[@]}"; do
    case "$code" in
      CHALLENGED) n_chal=$((n_chal + 1)) ;;
      UNREACHABLE)
        if [ "$unreachable_mode" = down ]; then n_down=$((n_down + 1)); fi
        ;;
      4*|5*) n_down=$((n_down + 1)) ;;
    esac
  done
  n_answered=$((n_total - n_chal))
  if [ "$unreachable_mode" = exclude ]; then
    local n_unreachable=0
    for code in "${cdn_codes[@]}"; do
      [ "$code" = UNREACHABLE ] && n_unreachable=$((n_unreachable + 1))
    done
    n_answered=$((n_answered - n_unreachable))
  fi

  case "$origin_code" in 2*|3*) origin_ok=1 ;; esac
  case "$origin_code" in 4*|5*) origin_failed=1 ;; esac
  if [ "$origin_code" = UNREACHABLE ] && [ "$unreachable_mode" = down ]; then origin_failed=1; fi
  [ "$origin_code" = CHALLENGED ] && origin_challenged=1
  case "$ready_code" in 2*|3*) ready_ok=1 ;; esac
  case "$ready_code" in 4*|5*) ready_failed=1 ;; esac
  if [ "$ready_code" = UNREACHABLE ] && [ "$unreachable_mode" = down ]; then ready_failed=1; fi
  [ "$ready_code" = CHALLENGED ] && ready_challenged=1

  if [ "$origin_failed" -eq 1 ] && [ "$n_down" -gt 0 ]; then
    echo ORIGIN_DOWN
  elif [ "$origin_ok" -eq 1 ] && [ "$n_down" -gt 0 ] && [ "$n_answered" -gt 0 ] && [ "$n_down" -gt $((n_answered / 2)) ]; then
    echo CDN_EDGE
  elif [ "$n_down" -gt 0 ]; then
    echo PARTIAL
  elif [ "$origin_failed" -eq 1 ]; then
    echo ORIGIN_ONLY_DOWN
  elif [ "$ready_failed" -eq 1 ]; then
    echo NOT_READY
  elif [ "$n_chal" -eq "$n_total" ] && [ "$n_total" -gt 0 ]; then
    echo ALL_CHALLENGED
  elif [ "$origin_challenged" -eq 1 ] || [ "$ready_challenged" -eq 1 ]; then
    echo CHALLENGED
  else
    echo OK
  fi
}

# Arguments: origin code, ready code, control curl exit, control HTTP code,
# then one code per CDN host. Pass -1/000 for control exit/code when asking
# whether a control request is needed. A control HTTP response of any status
# proves connectivity; only curl failure or HTTP 000 means the runner could
# not reach the control host.
uptime_verdict() {
  local origin_code="$1" ready_code="$2" control_exit="$3" control_code="$4"
  shift 4
  local -a cdn_codes=("$@")
  local confirmed_verdict resolved_verdict

  confirmed_verdict=$(uptime_verdict_for exclude "$origin_code" "$ready_code" "${cdn_codes[@]}")
  resolved_verdict=$(uptime_verdict_for down "$origin_code" "$ready_code" "${cdn_codes[@]}")

  # If resolving timeouts cannot change the outcome, confirmed HTTP evidence
  # already determines the verdict and a failing control host is irrelevant.
  if [ "$confirmed_verdict" = "$resolved_verdict" ]; then
    echo "$confirmed_verdict"
  elif [ "$control_exit" = -1 ]; then
    echo NEEDS_CONTROL
  elif [ "$control_exit" -ne 0 ] || [ "$control_code" = 000 ] || [ -z "$control_code" ]; then
    echo PROBE_NETWORK
  else
    # Any HTTP response (including 403/429) confirms the runner reached out.
    echo "$resolved_verdict"
  fi
}
