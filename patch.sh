#!/usr/bin/env bash
#
# patch.sh - weekly OS patching:
#   patch -> e-mail report -> reboot (always) -> verify after boot -> e-mail report
#
# Normally launched by patch-agent.sh, which first pulls the latest copy from GitHub.
#
#   --post-reboot   post-boot verification + second e-mail (called by os-patch-postboot.service)
#   --force         ignore the "already ran within MIN_INTERVAL_DAYS" guard
#   --dry-run       change nothing, never reboot, write e-mails to $LOG_DIR/*.eml instead of sending
#
# Supported: Debian/Ubuntu (apt), RHEL / Rocky / Alma / Amazon Linux (dnf, yum).
#
set -uo pipefail
export LC_ALL=C
umask 077

VERSION="1.0.0"
CONF="${OS_PATCH_CONF:-/etc/os-patch/patch.conf}"
STATE_DIR="${OS_PATCH_STATE_DIR:-/var/lib/os-patch}"
LOG_DIR="${OS_PATCH_LOG_DIR:-/var/log/os-patch}"
HOOK_DIR="${OS_PATCH_HOOK_DIR:-/etc/os-patch}"

# ---- defaults (override in /etc/os-patch/patch.conf) -------------------------
ADMIN_EMAIL=""                 # comma/space separated recipients
MAIL_FROM=""                   # default: os-patch@<hostname>
MAIL_METHOD="smtp"             # smtp (curl, no MTA needed) | sendmail
SMTP_URL=""                    # e.g. smtps://email-smtp.ap-south-1.amazonaws.com:465
SMTP_USER=""
SMTP_PASS=""
SUBJECT_PREFIX="[OS-PATCH]"
PATCH_SCOPE="all"              # all | security
AUTOREMOVE="true"              # autoremove unused packages / old kernels
REBOOT_DELAY_MIN=1             # minutes between "patching done" e-mail and reboot
REBOOT_ON_FAILURE="true"       # reboot even if patching failed (your requirement)
MIN_INTERVAL_DAYS=6            # skip if a run started less than this many days ago
MIN_FREE_MB=1024               # warn if / or /var has less free space
UPGRADE_TIMEOUT="90m"          # hard limit for the package upgrade command
LOG_RETENTION_DAYS=90
LOG_TAIL_LINES=150
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

MODE="patch"; DRY_RUN=0; FORCE=0
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
  case "$arg" in
    --post-reboot) MODE="post" ;;
    --dry-run)     DRY_RUN=1 ;;
    --force)       FORCE=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != 1 ]; then echo "must run as root" >&2; exit 1; fi
mkdir -p "$STATE_DIR" "$LOG_DIR" || exit 1

HOST="$(hostname -f 2>/dev/null || hostname)"
[ -n "$MAIL_FROM" ] || MAIL_FROM="os-patch@${HOST}"
TS="$(date +%Y%m%d-%H%M%S)"
if [ "$MODE" = post ]; then LOG="$LOG_DIR/postboot-$TS.log"; else LOG="$LOG_DIR/patch-$TS.log"; fi
: > "$LOG"
REPORT="$LOG_DIR/report-$MODE-$TS.txt"
WARNINGS=(); ERRORS=()

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
warn() { WARNINGS+=("$*"); log "WARN: $*"; }
err()  { ERRORS+=("$*");   log "ERROR: $*"; }
die()  { log "FATAL: $*"; exit 1; }
logrun() { "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
bullets() { local i; for i in "$@"; do printf '  - %s\n' "$i"; done; }
section() { printf '\n== %s ==\n' "$1"; }

# ---- package-manager abstraction ---------------------------------------------
if   command -v apt-get >/dev/null 2>&1; then PM="apt"
elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
elif command -v yum     >/dev/null 2>&1; then PM="yum"
else PM=""; fi

SEC_FLAG=""; [ "$PATCH_SCOPE" = security ] && SEC_FLAG="--security"

pm_refresh() {
  case "$PM" in
    apt) logrun apt-get -q update ;;
    dnf|yum) logrun "$PM" -y -q makecache ;;
  esac
}

pm_pending() {   # one line per pending update, empty if none
  case "$PM" in
    apt)
      apt-get -s -q dist-upgrade 2>/dev/null | awk '/^Inst /' |
        { if [ "$PATCH_SCOPE" = security ]; then grep -i 'security'; else cat; fi; } ;;
    dnf|yum)
      # shellcheck disable=SC2086
      "$PM" -q check-update $SEC_FLAG 2>/dev/null |
        awk 'NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ {print $1, $2, $3}' ;;
  esac
}

pm_upgrade() {
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
      local o=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600)
      if [ "$PATCH_SCOPE" = security ]; then
        local pkgs; pkgs="$(awk '{print $2}' "$PENDING_FILE" | tr '\n' ' ')"
        [ -n "$pkgs" ] || return 0
        # shellcheck disable=SC2086
        logrun timeout "$UPGRADE_TIMEOUT" apt-get "${o[@]}" install --only-upgrade $pkgs
      else
        logrun timeout "$UPGRADE_TIMEOUT" apt-get "${o[@]}" dist-upgrade
      fi ;;
    dnf|yum)
      # shellcheck disable=SC2086
      logrun timeout "$UPGRADE_TIMEOUT" "$PM" -y upgrade $SEC_FLAG ;;
  esac
}

pm_repair() {
  case "$PM" in
    apt) export DEBIAN_FRONTEND=noninteractive
         logrun dpkg --configure -a; logrun apt-get -y -q -f install ;;
    dnf|yum) logrun "$PM" -y -q clean all ;;
  esac
}

pm_cleanup() {
  [ "$AUTOREMOVE" = true ] || return 0
  case "$PM" in
    apt) logrun apt-get -y -q autoremove --purge; logrun apt-get -q autoclean ;;
    dnf|yum) logrun "$PM" -y -q autoremove ;;
  esac
}

pm_snapshot() {  # "name version" per installed package, sorted
  case "$PM" in
    apt) dpkg-query -W -f='${Package}:${Architecture} ${Version}\n' ;;
    dnf|yum) rpm -qa --qf '%{NAME}.%{ARCH} %{VERSION}-%{RELEASE}\n' ;;
  esac | sort
}

pm_reboot_flag() {  # yes | no | unknown  (informational only - we reboot regardless)
  case "$PM" in
    apt) if [ -f /var/run/reboot-required ]; then echo yes; else echo no; fi ;;
    dnf|yum)
      if command -v needs-restarting >/dev/null 2>&1; then
        needs-restarting -r >/dev/null 2>&1; case $? in 0) echo no ;; 1) echo yes ;; *) echo unknown ;; esac
      else echo unknown; fi ;;
  esac
}

latest_kernel() {
  local k
  k="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v rescue | sort -V | tail -1)"
  echo "${k:-unknown}"
}

pkg_diff() {  # $1=before $2=after -> "U name old -> new" / "N name ver" / "R name ver"
  awk '
    function add(arr, k, v) { if (k in arr) arr[k] = arr[k] "," v; else arr[k] = v }
    NR == FNR { add(b, $1, $2); next }
    { add(a, $1, $2) }
    END {
      for (k in a) {
        if (!(k in b))         printf "N %s %s\n", k, a[k]
        else if (a[k] != b[k]) printf "U %s %s -> %s\n", k, b[k], a[k]
      }
      for (k in b) if (!(k in a)) printf "R %s %s\n", k, b[k]
    }' "$1" "$2" | sort -k1,1 -k2,2
}

# ---- helpers ------------------------------------------------------------------
imds() {  # EC2 metadata (IMDSv2); silently fails off-AWS
  local t
  t="$(curl -fsS --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token 2>/dev/null)" || return 1
  curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $t" \
        "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}

host_info() {
  HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; HOST_IP="${HOST_IP:-n/a}"
  OS_NAME="$( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") )"
  INSTANCE_ID="$(imds instance-id || true)"; INSTANCE_ID="${INSTANCE_ID:-n/a}"
  AZ="$(imds placement/availability-zone || true)"; AZ="${AZ:-n/a}"
  COMMIT="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  REPO_SYNC="${PATCH_REPO_SYNC:-n/a}"
}

run_hooks() {  # run executables in $HOOK_DIR/<name>/ (e.g. deregister from LB)
  local d="$HOOK_DIR/$1" f
  [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    log "hook: $f"
    [ "$DRY_RUN" = 1 ] && continue
    timeout 300 "$f" >>"$LOG" 2>&1 || warn "hook failed: $f"
  done
}

esc() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }

send_mail() {  # $1 subject  $2 body file  $3 optional attachment file
  local subject="$1" body="$2" attach="${3:-}" list r rcpts=() to_hdr msg boundary i rc=1
  list="${ADMIN_EMAIL//,/ }"
  for r in $list; do rcpts+=("$r"); done
  if [ ${#rcpts[@]} -eq 0 ]; then warn "ADMIN_EMAIL not set - report NOT e-mailed (saved: $REPORT)"; return 1; fi
  to_hdr="$(printf '%s, ' "${rcpts[@]}")"; to_hdr="${to_hdr%, }"
  msg="$(mktemp)"; boundary="=_ospatch_$(date +%s)_$$"
  {
    echo "From: ${MAIL_FROM}"
    echo "To: ${to_hdr}"
    echo "Subject: ${subject}"
    echo "Date: $(date -R)"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
    echo
    echo "--${boundary}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    cat "$body"
    if [ -n "$attach" ] && [ -s "$attach" ]; then
      echo
      echo "--${boundary}"
      echo "Content-Type: text/plain; charset=UTF-8; name=\"$(basename "$attach")\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"$(basename "$attach")\""
      echo
      tail -c 1500000 "$attach" | base64
    fi
    echo "--${boundary}--"
  } > "$msg"

  if [ "$DRY_RUN" = 1 ]; then
    cp "$msg" "$LOG_DIR/dryrun-$MODE-$TS.eml"; rm -f "$msg"
    log "dry-run: e-mail written to $LOG_DIR/dryrun-$MODE-$TS.eml (subject: $subject)"; return 0
  fi

  for i in 1 2 3; do
    if [ "$MAIL_METHOD" = sendmail ]; then
      sendmail -t -oi < "$msg" && { rc=0; break; }
    else
      [ -n "$SMTP_URL" ] || { warn "SMTP_URL not set"; break; }
      local args=(--silent --show-error --max-time 60 --ssl-reqd --url "$SMTP_URL"
                  --mail-from "$MAIL_FROM" --upload-file "$msg")
      for r in "${rcpts[@]}"; do args+=(--mail-rcpt "$r"); done
      if [ -n "$SMTP_USER" ]; then
        printf 'user = "%s:%s"\n' "$(esc "$SMTP_USER")" "$(esc "$SMTP_PASS")" |
          curl "${args[@]}" -K - >>"$LOG" 2>&1 && { rc=0; break; }
      else
        curl "${args[@]}" >>"$LOG" 2>&1 && { rc=0; break; }
      fi
    fi
    log "mail attempt $i failed"; sleep 20
  done
  rm -f "$msg"
  if [ $rc -eq 0 ]; then log "e-mail sent to: $to_hdr"; else warn "e-mail FAILED after 3 attempts (report saved: $REPORT)"; fi
  return $rc
}

preflight() {
  local mp free min
  for mp in / /var /boot; do
    [ "$mp" = / ] || mountpoint -q "$mp" 2>/dev/null || continue
    free="$(df -Pm "$mp" 2>/dev/null | awk 'NR==2{print $4}')"
    min="$MIN_FREE_MB"; [ "$mp" = /boot ] && min=100
    if [ "${free:-0}" -lt "$min" ]; then warn "low disk space on $mp: ${free:-?} MB free (< $min MB)"; fi
  done
}

# ---- PATCH RUN ----------------------------------------------------------------
main_patch() {
  [ -n "$PM" ] || die "no supported package manager found (apt/dnf/yum)"
  exec 9>"$STATE_DIR/patch.lock"
  flock -n 9 || { log "another patch run is in progress - exiting"; exit 0; }

  START_EPOCH="$(date +%s)"; START_HUMAN="$(date '+%F %T %Z')"
  if [ "$FORCE" != 1 ] && [ -f "$STATE_DIR/last_run" ]; then
    local last; last="$(cat "$STATE_DIR/last_run" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( START_EPOCH - last )) -lt $(( MIN_INTERVAL_DAYS * 86400 )) ]; then
      log "last run was $(( (START_EPOCH - last) / 3600 ))h ago (< ${MIN_INTERVAL_DAYS}d) - skipping. Use --force to override."
      exit 0
    fi
  fi
  [ "$DRY_RUN" = 1 ] || echo "$START_EPOCH" > "$STATE_DIR/last_run"

  host_info
  PENDING_FILE="$STATE_DIR/pending.txt"
  DIFF_FILE="$STATE_DIR/pkgdiff.txt"
  RESULT="OK"
  log "== OS patching start: $HOST ($INSTANCE_ID) pm=$PM scope=$PATCH_SCOPE script=v$VERSION@$COMMIT repo-sync=$REPO_SYNC dry-run=$DRY_RUN"

  run_hooks pre-patch.d
  preflight
  KERNEL_BEFORE="$(uname -r)"
  pm_snapshot > "$STATE_DIR/pkgs.before"

  if ! pm_refresh; then
    log "metadata refresh failed, retrying once"; sleep 15
    pm_refresh || err "could not refresh package metadata (repo/network problem?)"
  fi

  pm_pending > "$PENDING_FILE"
  PENDING_COUNT="$(grep -c . "$PENDING_FILE" || true)"
  log "pending updates before patching: $PENDING_COUNT"

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: skipping package upgrade"
  elif [ "$PENDING_COUNT" -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
    if ! pm_upgrade; then
      warn "package upgrade failed - running repair and retrying once"
      pm_repair; pm_refresh
      pm_upgrade || err "package upgrade failed after retry"
    fi
    pm_cleanup
  else
    log "nothing to upgrade"
  fi

  pm_snapshot > "$STATE_DIR/pkgs.after"
  pkg_diff "$STATE_DIR/pkgs.before" "$STATE_DIR/pkgs.after" > "$DIFF_FILE"
  N_UP="$(grep -c '^U ' "$DIFF_FILE" || true)"
  N_NEW="$(grep -c '^N ' "$DIFF_FILE" || true)"
  N_RM="$(grep -c '^R ' "$DIFF_FILE" || true)"
  KERNEL_LATEST="$(latest_kernel)"
  REBOOT_FLAG="$(pm_reboot_flag)"

  run_hooks post-patch.d

  if   [ ${#ERRORS[@]}   -gt 0 ]; then RESULT="FAILED"
  elif [ ${#WARNINGS[@]} -gt 0 ]; then RESULT="WARN"
  else RESULT="OK"; fi

  DO_REBOOT="yes"
  if [ "$RESULT" = FAILED ] && [ "$REBOOT_ON_FAILURE" != true ]; then DO_REBOOT="no"; fi
  END_EPOCH="$(date +%s)"
  REBOOT_AT="$(date -d "+${REBOOT_DELAY_MIN} min" '+%F %T %Z' 2>/dev/null || echo "in ${REBOOT_DELAY_MIN} min")"

  build_prereboot_report
  cat "$REPORT" >> "$LOG"

  if [ "$DO_REBOOT" = yes ] && [ "$DRY_RUN" != 1 ]; then
    {
      printf 'P_START=%q\nP_RESULT=%q\nP_KERNEL_BEFORE=%q\nP_KERNEL_LATEST=%q\n' \
        "$START_HUMAN" "$RESULT" "$KERNEL_BEFORE" "$KERNEL_LATEST"
      printf 'P_PENDING=%q\nP_UP=%q\nP_NEW=%q\nP_RM=%q\nP_LOG=%q\nP_REBOOT_AT=%q\n' \
        "$PENDING_COUNT" "$N_UP" "$N_NEW" "$N_RM" "$LOG" "$REBOOT_AT"
    } > "$STATE_DIR/reboot_pending"
  fi

  local dry=""; [ "$DRY_RUN" = 1 ] && dry="DRY-RUN "
  send_mail "$SUBJECT_PREFIX ${dry}[$RESULT] $HOST - patching complete, reboot $( [ "$DO_REBOOT" = yes ] && echo scheduled || echo SKIPPED )" "$REPORT" "$LOG"

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would reboot at $REBOOT_AT"
  elif [ "$DO_REBOOT" = yes ]; then
    log "scheduling reboot in ${REBOOT_DELAY_MIN} min"
    shutdown -r "+${REBOOT_DELAY_MIN}" "os-patch: weekly patching complete, rebooting" \
      || systemctl reboot || reboot
  else
    log "reboot skipped (patching failed and REBOOT_ON_FAILURE=false)"
  fi

  find "$LOG_DIR" -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
  [ "$RESULT" = FAILED ] && exit 1
  exit 0
}

build_prereboot_report() {
  {
    echo "OS PATCHING REPORT (pre-reboot)"
    echo "================================"
    echo "Result          : $RESULT"
    echo "Host            : $HOST"
    echo "IP / Instance   : $HOST_IP / $INSTANCE_ID ($AZ)"
    echo "OS              : $OS_NAME"
    echo "Started         : $START_HUMAN"
    echo "Duration        : $(( END_EPOCH - START_EPOCH ))s"
    echo "Package manager : $PM   Scope: $PATCH_SCOPE"
    echo "Script          : v$VERSION commit $COMMIT   GitHub sync: $REPO_SYNC"
    [ "$DRY_RUN" = 1 ] && echo "MODE            : DRY RUN (package metadata refreshed only; nothing installed, no reboot)"

    section "SUMMARY"
    echo "  Updates pending before run : $PENDING_COUNT"
    echo "  Packages upgraded          : $N_UP"
    echo "  Packages newly installed   : $N_NEW"
    echo "  Packages removed           : $N_RM"

    section "KERNEL / REBOOT"
    echo "  Running kernel (pre-reboot): $KERNEL_BEFORE"
    echo "  Newest installed kernel    : $KERNEL_LATEST"
    echo "  OS says reboot required    : $REBOOT_FLAG  (policy: always reboot)"
    if [ "$DO_REBOOT" = yes ]; then echo "  Reboot                     : scheduled for $REBOOT_AT"
    else echo "  Reboot                     : SKIPPED (patching failed, REBOOT_ON_FAILURE=false)"; fi
    echo "  A post-reboot verification e-mail will follow."

    section "ERRORS"
    if [ ${#ERRORS[@]} -gt 0 ]; then bullets "${ERRORS[@]}"; else echo "  none"; fi
    section "WARNINGS"
    if [ ${#WARNINGS[@]} -gt 0 ]; then bullets "${WARNINGS[@]}"; else echo "  none"; fi

    section "PACKAGES UPGRADED (name  old -> new)"
    if [ "$N_UP" -gt 0 ]; then grep '^U ' "$DIFF_FILE" | sed 's/^U /  /' | head -n 400; else echo "  none"; fi
    section "PACKAGES NEWLY INSTALLED"
    if [ "$N_NEW" -gt 0 ]; then grep '^N ' "$DIFF_FILE" | sed 's/^N /  /' | head -n 200; else echo "  none"; fi
    section "PACKAGES REMOVED"
    if [ "$N_RM" -gt 0 ]; then grep '^R ' "$DIFF_FILE" | sed 's/^R /  /' | head -n 200; else echo "  none"; fi

    section "UPDATES AVAILABLE BEFORE PATCHING ($PENDING_COUNT)"
    if [ "$PENDING_COUNT" -gt 0 ]; then head -n 300 "$PENDING_FILE" | cut -c1-160 | sed 's/^/  /'; else echo "  none"; fi

    section "LAST $LOG_TAIL_LINES LOG LINES (full log attached)"
    tail -n "$LOG_TAIL_LINES" "$LOG" | sed 's/^/  /'
  } > "$REPORT"
}

# ---- POST-REBOOT VERIFICATION -------------------------------------------------
main_post() {
  if [ ! -f "$STATE_DIR/reboot_pending" ]; then log "no pending post-reboot report - nothing to do"; exit 0; fi
  # shellcheck disable=SC1090
  . "$STATE_DIR/reboot_pending"
  : "${P_START:=unknown}" "${P_RESULT:=unknown}" "${P_KERNEL_BEFORE:=unknown}" "${P_KERNEL_LATEST:=unknown}"
  : "${P_PENDING:=?}" "${P_UP:=?}" "${P_NEW:=?}" "${P_RM:=?}" "${P_LOG:=?}" "${P_REBOOT_AT:=?}"
  host_info

  local running latest sys_state failed_units n_failed
  running="$(uname -r)"; latest="$(latest_kernel)"
  sys_state="$(systemctl is-system-running 2>/dev/null || true)"
  failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  n_failed="$(printf '%s' "$failed_units" | grep -c . || true)"

  run_hooks post-reboot.d
  [ "$n_failed" -gt 0 ] && warn "$n_failed failed systemd unit(s) after reboot"
  case "$sys_state" in running) ;; *) warn "systemd state is '$sys_state' (expected 'running')" ;; esac
  if [ "$latest" != unknown ] && [ "$running" != "$latest" ]; then
    warn "running kernel ($running) differs from newest installed ($latest)"
  fi
  [ "$P_RESULT" = FAILED ] && warn "the patch run itself reported FAILED - see pre-reboot e-mail"

  local overall="OK"; [ ${#WARNINGS[@]} -gt 0 ] && overall="WARN"
  {
    echo "OS PATCHING REPORT (post-reboot verification)"
    echo "=============================================="
    echo "Result          : $overall   (patch run result: $P_RESULT)"
    echo "Host            : $HOST"
    echo "IP / Instance   : $HOST_IP / $INSTANCE_ID ($AZ)"
    echo "OS              : $OS_NAME"
    echo "Patch run start : $P_START   (reboot was scheduled for $P_REBOOT_AT)"
    echo "Booted at       : $(uptime -s 2>/dev/null || echo n/a)   ($(uptime -p 2>/dev/null))"
    echo "Report time     : $(date '+%F %T %Z')"

    section "SUMMARY OF PATCH RUN"
    echo "  Updates pending : $P_PENDING   upgraded: $P_UP   new: $P_NEW   removed: $P_RM"
    echo "  Pre-patch log   : $P_LOG"

    section "HEALTH AFTER REBOOT"
    echo "  Kernel before reboot : $P_KERNEL_BEFORE"
    echo "  Kernel now running   : $running"
    echo "  Newest installed     : $latest"
    echo "  Reboot still needed  : $(pm_reboot_flag)"
    echo "  systemd state        : $sys_state"
    echo "  Failed units         : $n_failed"
    [ "$n_failed" -gt 0 ] && printf '%s\n' "$failed_units" | sed 's/^/    - /'
    echo "  Load average         : $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "  Memory (MB)          : $(free -m 2>/dev/null | awk '/^Mem:/{print "total="$2" used="$3" free="$4}')"

    section "WARNINGS"
    if [ ${#WARNINGS[@]} -gt 0 ]; then bullets "${WARNINGS[@]}"; else echo "  none"; fi

    section "DISK USAGE"
    df -hP -x tmpfs -x devtmpfs 2>/dev/null | sed 's/^/  /'

    section "LISTENING TCP PORTS"
    (ss -ltnH 2>/dev/null || true) | awk '{print "  " $4}' | sort -u | head -n 40

    section "JOURNAL ERRORS SINCE BOOT (last 30)"
    journalctl -b -p err --no-pager -q 2>/dev/null | tail -n 30 | sed 's/^/  /'
  } > "$REPORT"
  cat "$REPORT" >> "$LOG"

  send_mail "$SUBJECT_PREFIX [$overall] $HOST - post-reboot verification" "$REPORT" ""
  rm -f "$STATE_DIR/reboot_pending"
  exit 0
}

case "$MODE" in
  patch) main_patch ;;
  post)  main_post ;;
esac
