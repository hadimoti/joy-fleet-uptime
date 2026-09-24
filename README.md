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

Transport failures are tracked separately from HTTP errors. If a probe cannot
connect, the workflow checks `api.github.com` with bounded timeouts; if that
control request also fails, the run reports `PROBE_NETWORK` and does not infer
a fleet outage from the runner's connectivity problem. HTTP 4xx/5xx responses
without a recognized challenge page remain failures. Challenge detection uses
specific interstitial text and challenge markers, so ordinary pages that
mention Cloudflare are not treated as blocked.

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
   with the run link and UTC timestamp. It still runs the probes and never
   uses outage wording. The drill is successful only when Telegram returns
   HTTP 200 and confirms `ok: true`; missing secrets or an unconfirmed response
   fail the drill step. Scheduled runs cannot send a drill.

Recognized challenge response markers are checked on every HTTP status. A
marked response is reported as challenged and is not counted as healthy or
down. The workflow runs the offline classification contract before probing.

## Limitations, stated plainly

- GitHub's `schedule` trigger is **best-effort**. Runs can be delayed or skipped
  under platform load. This is good monitoring, not a hard SLA.
- Scheduled workflows are **disabled automatically after 60 days** without
  repository activity.
- A green run proves the *probe* works. Use the dispatch `drill` option to
  exercise Telegram delivery without reporting an outage.
