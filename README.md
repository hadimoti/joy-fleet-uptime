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

## Limitations, stated plainly

- GitHub's `schedule` trigger is **best-effort**. Runs can be delayed or skipped
  under platform load. This is good monitoring, not a hard SLA.
- Scheduled workflows are **disabled automatically after 60 days** without
  repository activity.
- A green run proves the *probe* works. The alert step only executes on failure,
  so a healthy fleet never exercises message delivery — test that separately.
