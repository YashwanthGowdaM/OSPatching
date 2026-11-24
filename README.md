# Automated weekly OS patching

Every server patches itself **once a week on Friday**, **always reboots**, and e-mails the admin a detailed report.

## How it works

```
GitHub repo (this)  <-- git fetch (latest scripts) --  every server, via systemd timer (Fri 22:00 + jitter)
                                                              |
                         1. pull latest patch.sh from GitHub (falls back to cached copy if GitHub is down)
                         2. snapshot packages -> refresh -> upgrade -> snapshot -> diff
                         3. E-MAIL #1: result, every package old->new, kernel, errors, log attached
                         4. reboot (always, 1 min later)
                         5. after boot: health checks (failed units, kernel, ports, journal errors)
                         6. E-MAIL #2: post-reboot verification
```

**Why server-side pull instead of GitHub Actions?** Your fleet scales. A GitHub Actions job needs a server inventory plus SSH/SSM
access to each node, and misses instances launched after the job started. With a pull model, a new instance installs the timer
from user-data (`user-data.example.sh`) and is patched from its first Friday on. If you still want a central trigger, run
`/opt/os-patch/bin/patch-agent.sh --force` through SSM Run Command from EventBridge/Actions, since the same script works.

## Files

| File | Purpose |
|---|---|
| `patch.sh` | The patching logic (apt, dnf, yum), reports, reboot, post-reboot check |
| `patch-agent.sh` | Tiny launcher: `git fetch` the configured branch/tag, then run `patch.sh` |
| `install.sh` | Installs agent, config and systemd timer. Idempotent |
| `patching.conf.example` | All settings (the real file lives on the server at `/etc/os-patch/patch.conf`, mode 600) |
| `user-data.example.sh` | Bootstrap for Auto Scaling Group launch templates (secrets from SSM Parameter Store) |
| `.github/workflows/shellcheck.yml` | Lints every push/PR; servers run this as root, so keep `main` protected |

## Setup

1. Push this folder to a **private** GitHub repo. Protect `main` (require PR + review).
2. Create a fine-grained token: this repo only, **Contents: read-only**. Store it, plus SMTP creds, in SSM Parameter Store.
3. Existing servers: `git clone` the repo, then
   `sudo ADMIN_EMAIL=you@x.com SMTP_URL=smtps://... SMTP_USER=... SMTP_PASS=... GITHUB_TOKEN=... ./install.sh`
   New/scaled servers: put `user-data.example.sh` (edited) in the launch template, and bake nothing else.
4. Test, with no changes made and no reboot: `sudo /opt/os-patch/bin/patch-agent.sh --force --dry-run`
   The e-mail is written to `/var/log/os-patch/dryrun-patch-*.eml`.
5. Real test on one box: `sudo /opt/os-patch/bin/patch-agent.sh --force` (it **will patch and reboot**).

E-mail: SMTP via `curl`, so no mail server is needed. Amazon SES SMTP works (verify the sender, and use the SES SMTP credentials).
Set `MAIL_METHOD=sendmail` if the box already has postfix/msmtp.

## Behaviour you should know

- **Schedule:** `Fri *-*-* 22:00:00` in the *server's* time zone (UTC on most cloud images, so that is Sat 03:30 IST), plus random jitter
  (`PATCH_JITTER_MIN`, default 60). Change it with `PATCH_ONCALENDAR` and re-run `install.sh`. `Persistent=true` makes a server that was
  off at that time patch when it next boots.
- **Once per 7 days:** a guard skips a run if one started in the last 6 days (`MIN_INTERVAL_DAYS`). `--force` overrides.
- **Always reboots**, whether or not updates were found, and even if patching failed (`REBOOT_ON_FAILURE=true`). On failure the script
  runs `dpkg --configure -a` / `apt -f install` (or `clean all`), retries once, and flags the e-mail `[FAILED]`.
- **Fleet availability:** jitter alone does not stop many nodes rebooting together. For a big ASG, use a wide jitter (120+ min) and put
  drain/undrain steps in hook directories. Executables in `/etc/os-patch/pre-patch.d/`, `post-patch.d/` (before reboot) and
  `post-reboot.d/` run in order; for example, a script that sets the instance to Standby in the ASG or deregisters it from the target group.
- **Scope:** `PATCH_SCOPE=all` (default, full dist-upgrade) or `security`.
- **Logs/reports:** `/var/log/os-patch/` (kept 90 days). Timer status: `systemctl list-timers os-patch.timer`.

## Security notes

The servers execute whatever is on the configured branch as root. Keep the repo private, use a read-only token, protect `main`, and
consider pointing servers at a release tag (`REPO_REF=v1.0.0`) so changes roll out only when you cut a tag. Never commit
`patch.conf` or tokens.
