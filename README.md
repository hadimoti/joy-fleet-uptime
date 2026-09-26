# uptime (retired)

This repository ran synthetic uptime checks on a GitHub Actions schedule and
alerted to Telegram. It was retired on 2026-09-27.

GitHub delivers scheduled workflows on a best-effort basis. The `*/5`
schedule was in practice delivered only every 3–5 hours, so it could not
provide timely outage detection.

Uptime alerting now lives in UptimeRobot (independent cloud checks every
5 minutes, push notifications). The previous workflow, classifier and tests
remain available in this repository's git history.
