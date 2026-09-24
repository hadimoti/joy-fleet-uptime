# uptime

Synthetic uptime monitoring for a small set of public websites, running on a
GitHub Actions schedule and alerting to Telegram.

## Why it exists

Most of the monitored hostnames sit behind a CDN. When a CDN edge or a network
path breaks, every site appears to fail at once — which looks exactly like the
server having died. Those two situations need opposite responses, and guessing
wrong means debugging a server that was never broken.

So one hostname deliberately bypasses the CDN and resolves straight to the
origin. Watching both paths separately makes the two cases distinguishable:

| CDN hosts | Origin host | Meaning |
| :--- | :--- | :--- |
| failing | failing | The server really is down. |
| failing | healthy | CDN / DNS / network-path problem. The server is fine. |
| healthy | healthy | All good. |

The probe also checks a `/ready` endpoint, which reports whether the
application's own dependencies are healthy — something a homepage check cannot
see, since an app can serve a perfectly good homepage while its database is
unreachable.

Transport failures are tracked separately from HTTP errors. The control check
is used whenever any target is transport-only. Confirmed HTTP failures continue
to drive the verdict even if the control connection fails. Any HTTP response
from `api.github.com` proves the runner reached the internet, including
403/429; only a curl connection failure or HTTP 000 leaves transport-only
targets unresolved. `PROBE_NETWORK` is used only when those are the only
non-UP signals. A challenge mixed with an unresolved transport failure is
`PROBE_INCONCLUSIVE`, so it cannot make the run green.
For endpoint probes, any received HTTP status is classified by status even if
curl later exits non-zero while reading a slow or truncated body. Any challenge
marker in the portion of the body that was read still takes precedence; an
empty body with HTTP 200 remains `UP`. Only HTTP 000 is `UNREACHABLE`.
HTTP 4xx/5xx responses without a recognized challenge page remain failures.
Challenge detection uses specific interstitial text and challenge markers, so
ordinary pages that mention Cloudflare are not treated as blocked.

| Origin | `/ready` | CDN hosts | Control failure / HTTP 000 | Any control HTTP status |
| :--- | :--- | :--- | :--- | :--- |
| `DOWN` | any | at least one `DOWN` | `ORIGIN_DOWN` | `ORIGIN_DOWN` |
| `DOWN` | any | no `DOWN` | `ORIGIN_ONLY_DOWN` | `ORIGIN_ONLY_DOWN` |
| any | `DOWN` | any | `NOT_READY` | `NOT_READY` |
| `UP` | `UP` | strict majority `DOWN` | `CDN_EDGE` | `CDN_EDGE` |
| any | any | at least one `DOWN` in other combinations | `PARTIAL` | `PARTIAL` |
| any | any | only `CHALLENGED`, no transport ambiguity or `UP` evidence | `PROBE_INCONCLUSIVE` | same |
| `UP` | `UP` | all CDN hosts `CHALLENGED`, no transport ambiguity | `ALL_CHALLENGED` | same |
| any | any | `UP` plus `CHALLENGED`, no transport ambiguity | `CHALLENGED` / `ALL_CHALLENGED` | same |
| any | any | transport failure, no confirmed `DOWN` or challenge | `PROBE_NETWORK` | Treat unreachable targets as `DOWN` and classify |
| any | any | transport failure mixed with challenge, no confirmed `DOWN` | `PROBE_INCONCLUSIVE` | Treat unreachable targets as `DOWN` and classify |
| any | any | transport failure plus confirmed HTTP `DOWN` | Preserve the confirmed verdict | Treat unreachable targets as `DOWN` and classify |

Verdict precedence is `ORIGIN_DOWN`, `ORIGIN_ONLY_DOWN`, `NOT_READY`,
`CDN_EDGE`, then `PARTIAL`. A readiness failure cannot be described as a
healthy origin even when most CDN hosts also return failures; the alert includes
the failing CDN host list for investigation. Challenges are neither `UP` nor
`DOWN`; without any independent `UP` evidence, they produce a failed,
inconclusive run. `CHALLENGED` and `ALL_CHALLENGED` exit successfully without a
Telegram alert; the challenged host list appears in a GitHub warning and job
summary. `PROBE_INCONCLUSIVE` still fails and alerts when there is no positive
health evidence.
Across at most two attempts per target, any `UP` result wins and stops retries;
otherwise a received ordinary 4xx/5xx (`DOWN`) wins, then any invalid status or
HTTP 000 (`UNREACHABLE`), and finally all-challenge attempts produce
`CHALLENGED`. A later success clears an earlier failure, while a confirmed HTTP
failure is retained over a later timeout or challenge.

## Why this repository is public

GitHub Actions is free and unmetered on public repositories but metered on
private ones. Keeping this workflow in its own public repository lets it run
every 5 minutes indefinitely at no cost.

Nothing private lives here. Every hostname probed is already resolvable in
public DNS, and the workflow reads no private data.

`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are GitHub Actions **secrets**:
encrypted, never rendered in logs, and deliberately withheld by GitHub from
workflows triggered by pull requests from forks, so a fork cannot read them.

## Setup

1. **Settings → Secrets and variables → Actions** and add:
   - `TELEGRAM_BOT_TOKEN` — from [@BotFather](https://t.me/BotFather)
   - `TELEGRAM_CHAT_ID` — the chat that should receive alerts
2. Send your alert bot a message once (press **Start**). A Telegram bot cannot
   open a conversation with a user who has never messaged it — skip this and
   every alert fails with `403: bot can't initiate conversation`, leaving you
   with monitoring that looks healthy but can never actually reach you.
3. Run it once by hand: **Actions → uptime → Run workflow**.
   The optional `drill` checkbox sends one `[DRILL]` Telegram delivery test
   with the run link and UTC timestamp. The `[DRILL]` message itself never
   uses outage wording. If the probe step fails, a separate status alert may
   accompany the drill. The drill is
   successful only when Telegram returns
   HTTP 200 and confirms `ok: true`; missing secrets or an unconfirmed response
   fail the drill step. Scheduled runs cannot send a drill.

Recognized challenge response markers are checked on every HTTP status. A
marked response is reported as challenged and is not counted as healthy or
down. The workflow runs the offline classification contract before probing.
Each endpoint gets two attempts with a 15-second curl limit and a 3-second
sleep only between attempts. The worst probe path is 12 targets × 33 seconds
(396 seconds), plus the 10-second control request, 20-second failure alert,
and optional 20-second delivery drill: 446 seconds total. The probe step has
an 8-minute limit and the job an 18-minute limit for checkout, checks, and
runner overhead. Scheduled probes share a concurrency group, so probes remain
serialized and a running probe is never cancelled. Manual dispatch runs with
the `drill` option use a separate group so a later scheduled probe cannot
replace a pending drill.

## Limitations, stated plainly

- GitHub's `schedule` trigger is **best-effort**. Runs can be delayed or skipped
  under platform load. This is good monitoring, not a hard SLA.
- Scheduled workflows are **disabled automatically after 60 days** without
  repository activity.
- A green run proves the *probe* works. Use the dispatch `drill` option to
  exercise Telegram delivery without reporting an outage.
