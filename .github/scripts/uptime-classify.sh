#!/usr/bin/env bash
# Shared HTTP response classification for the uptime workflow and offline test.

uptime_body_is_challenge() {
  local body_lc
  body_lc=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$body_lc" in
    *cf-chl-bypass*|*challenge-running*|*cloudflare*title*) return 0 ;;
    *"checking your browser"*|*"checking+your+browser"*|*"please enable javascript"*|*"please+enable+javascript"*|*"attention required"*|*"attention+required"*|*"ray id"*|*"ray+id"*) return 0 ;;
    *) return 1 ;;
  esac
}

uptime_file_is_challenge() {
  local file="$1"
  tr '[:upper:]' '[:lower:]' < "$file" | grep -iE \
    'cf-chl-bypass|challenge-running|cloudflare.*title|checking[ +]your[ +]browser|please[ +]enable[ +]javascript|attention[ +]required|ray[ +]id' >/dev/null
}

uptime_classify() {
  local code="${1:-}" body="${2:-}"
  if uptime_body_is_challenge "$body"; then
    echo CHALLENGED
    return
  fi
  case "$code" in
    2*|3*) echo UP ;;
    4*|5*|000|TIMEOUT) echo DOWN ;;
    ERR|'') echo UNKNOWN ;;
    *) echo UNKNOWN ;;
  esac
}

uptime_classify_file() {
  local code="${1:-}" file="${2:-}"
  if [ -n "$file" ] && uptime_file_is_challenge "$file"; then
    echo CHALLENGED
  else
    uptime_classify "$code" ""
  fi
}
