#!/usr/bin/env bash
# Shared HTTP response classification for the uptime workflow and offline test.

# Combiner decision table (target states are UP, CHALLENGED, DOWN, UNREACHABLE;
# DOWN means a received ordinary 4xx/5xx, while challenge pages remain
# CHALLENGED regardless of their HTTP status. CDN majority uses non-challenged
# responses; unresolved transport targets are excluded until control is read.
#
# For each origin, /ready, and CDN target, apply the following reduction. The
# word any below covers each of UP, CHALLENGED, DOWN, and UNREACHABLE; CDN rules
# apply to the host set as a whole. Every target result is retained in its
# output field (origin_code, ready_code, or down_list):
# origin | /ready | CDN hosts                          | control       | result
# -------+-------+------------------------------------+---------------+--------------------
# DOWN   | any   | >=1 DOWN                           | any           | ORIGIN_DOWN
# DOWN   | any   | no DOWN                            | any           | ORIGIN_ONLY_DOWN
# any    | DOWN  | any                                | any           | NOT_READY
# UP     | UP    | DOWN is strict majority           | any           | CDN_EDGE
# any    | any   | >=1 DOWN (remaining cases)        | any           | PARTIAL
# any    | any   | no DOWN/U; all CDN CHALLENGED      | n/a           | ALL_CHALLENGED only if origin and /ready are UP
# C     | any   | no DOWN/U                          | n/a           | CHALLENGED
# any    | C     | no DOWN/U                          | n/a           | CHALLENGED
# any    | any   | no DOWN/U; any CDN CHALLENGED      | n/a           | CHALLENGED
# any    | any   | only C, no U, no positive UP       | n/a           | PROBE_INCONCLUSIVE
# any    | any   | only UP, no C/U                    | n/a           | OK
# any    | any   | any U                             | not needed    | NEEDS_CONTROL
# any    | any   | any U, confirmed DOWN             | connection fail| confirmed result above
# any    | any   | any U, only UP/C/U                | connection fail| PROBE_INCONCLUSIVE if C, else PROBE_NETWORK
# any    | any   | any U                             | HTTP response | recompute with each U as DOWN
# A challenge is never UP/OK and never DOWN. Without independent UP evidence,
#  it is PROBE_INCONCLUSIVE; otherwise it is CHALLENGED (or ALL_CHALLENGED
#  when every CDN host is challenged and origin/ready are UP).
# Workflow handling: OK, CHALLENGED, and ALL_CHALLENGED succeed without a
#  Telegram alert. Challenges stay visible in a warning annotation and summary.
#  All failure verdicts, including inconclusive/network/crash, alert.
# A control HTTP response of any status is reachable; curl failure/HTTP 000 is
# connection failure. Control is otherwise not needed.

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
  # Receiving any HTTP status proves an HTTP response arrived, even if curl
  # later reports a truncated or timed-out body. Use whatever body was read to
  # detect challenges, then classify by status. Only HTTP 000 is transport-only.
  if [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" != "000" ] && uptime_body_is_challenge "$body"; then
    echo CHALLENGED
    return
  fi
  # A non-zero curl exit after receiving a status does not erase that response.
  if [ "$code" = "000" ]; then
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
  if [ -n "$file" ] && [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" != "000" ] && uptime_file_is_challenge "$file"; then
    echo CHALLENGED
  else
    uptime_classify "$code" "" "$curl_exit"
  fi
}

# Return the best ordinary HTTP failure observed across retries. The first
# received 4xx/5xx is durable evidence; a later 000, success, or challenge
# cannot erase it. Challenge responses are intentionally not ordinary DOWN.
uptime_keep_http_failure() {
  local previous="${1:-}" current="${2:-}" classification="${3:-}"
  if [[ "$previous" =~ ^[45][0-9][0-9]$ ]]; then
    echo "$previous"
  elif [ "$classification" = DOWN ] && [[ "$current" =~ ^[45][0-9][0-9]$ ]]; then
    echo "$current"
  fi
}

# Keep alert lists aligned with confirmed evidence. A challenge and a transport
# failure are reported separately and must never be presented as a confirmed
# HTTP outage.
uptime_record_cdn_result() {
  local host="$1" code="$2"
  local -n down_ref="$3" challenged_ref="$4" unreachable_ref="$5"
  case "$code" in
    CHALLENGED) challenged_ref+=("$host") ;;
    UNREACHABLE) unreachable_ref+=("$host") ;;
    4*|5*) down_ref+=("${host}(${code})") ;;
  esac
}

# Only confirmed health or challenge outcomes suppress Telegram. The workflow
# uses this function's result so alert routing stays covered by the contract.
uptime_should_alert() {
  case "${1:-PROBE_CRASH}" in
    OK|CHALLENGED|ALL_CHALLENGED) return 1 ;;
    *) return 0 ;;
  esac
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
  elif [ "$origin_failed" -eq 1 ]; then
    echo ORIGIN_ONLY_DOWN
  elif [ "$ready_failed" -eq 1 ]; then
    echo NOT_READY
  elif [ "$origin_ok" -eq 1 ] && [ "$ready_ok" -eq 1 ] && [ "$n_down" -gt 0 ] && [ "$n_answered" -gt 0 ] && [ "$n_down" -gt $((n_answered / 2)) ]; then
    echo CDN_EDGE
  elif [ "$n_down" -gt 0 ]; then
    echo PARTIAL
  elif [ "$n_chal" -eq "$n_total" ] && [ "$n_total" -gt 0 ] && \
       [ "$origin_ok" -eq 1 ] && [ "$ready_ok" -eq 1 ]; then
    echo ALL_CHALLENGED
  elif [ "$origin_challenged" -eq 1 ] || [ "$ready_challenged" -eq 1 ]; then
    echo CHALLENGED
  elif [ "$n_chal" -gt 0 ]; then
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
  local confirmed_verdict resolved_verdict has_unreachable=0 has_challenge=0 has_up=0 code

  confirmed_verdict=$(uptime_verdict_for exclude "$origin_code" "$ready_code" "${cdn_codes[@]}")
  resolved_verdict=$(uptime_verdict_for down "$origin_code" "$ready_code" "${cdn_codes[@]}")

  for code in "$origin_code" "$ready_code" "${cdn_codes[@]}"; do
    [ "$code" = UNREACHABLE ] && has_unreachable=1
    [ "$code" = CHALLENGED ] && has_challenge=1
    [[ "$code" =~ ^[23][0-9][0-9]$ ]] && has_up=1
  done

  # A transport-only target always requires the control check: it cannot be
  # treated as success just because the remaining evidence is challenged.
  if [ "$has_unreachable" -eq 1 ]; then
    if [ "$control_exit" = -1 ]; then
      echo NEEDS_CONTROL
    elif [ "$control_code" = 000 ] || [ -z "$control_code" ]; then
      if [ "$confirmed_verdict" != OK ] && [ "$confirmed_verdict" != ALL_CHALLENGED ] && [ "$confirmed_verdict" != CHALLENGED ]; then
        echo "$confirmed_verdict"
      elif [ "$has_challenge" -eq 1 ]; then
        echo PROBE_INCONCLUSIVE
      else
        echo PROBE_NETWORK
      fi
    else
      echo "$resolved_verdict"
    fi
    return
  fi

  # Challenges do not provide positive health evidence. With no UP target,
  # the result is an inconclusive failed run rather than a green challenge.
  if [ "$has_challenge" -eq 1 ] && [ "$has_up" -eq 0 ] && \
     { [ "$confirmed_verdict" = OK ] || [ "$confirmed_verdict" = ALL_CHALLENGED ] || [ "$confirmed_verdict" = CHALLENGED ]; }; then
    echo PROBE_INCONCLUSIVE
    return
  fi

  # If resolving timeouts cannot change the outcome, confirmed HTTP evidence
  # already determines the verdict and a failing control host is irrelevant.
  if [ "$confirmed_verdict" = "$resolved_verdict" ]; then
    echo "$confirmed_verdict"
  else
    echo "$confirmed_verdict"
  fi
}
