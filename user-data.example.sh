#!/bin/bash
# EC2 user-data / launch-template bootstrap for Auto Scaling Groups.
# Every new instance installs the patching timer on first boot - no inventory, no SSH.
#
# Needs: instance role with ssm:GetParameter on /os-patch/*, and the AWS CLI (preinstalled on Amazon Linux).
# Store secrets as SecureString parameters, e.g.:
#   aws ssm put-parameter --type SecureString --name /os-patch/github-token --value ghp_xxx
#   aws ssm put-parameter --type SecureString --name /os-patch/smtp-user    --value AKIA...
#   aws ssm put-parameter --type SecureString --name /os-patch/smtp-pass    --value ...
set -euo pipefail

REGION="ap-south-1"
REPO_URL="https://github.com/YOUR_ORG/os-patching.git"
REPO_REF="main"

get() { aws ssm get-parameter --region "$REGION" --with-decryption --name "$1" --query Parameter.Value --output text; }

export GITHUB_TOKEN; GITHUB_TOKEN="$(get /os-patch/github-token)"
export SMTP_USER;    SMTP_USER="$(get /os-patch/smtp-user)"
export SMTP_PASS;    SMTP_PASS="$(get /os-patch/smtp-pass)"
export ADMIN_EMAIL="admin@example.com"
export MAIL_FROM="os-patch@example.com"
export SMTP_URL="smtps://email-smtp.${REGION}.amazonaws.com:465"
export REPO_REF
export PATCH_ONCALENDAR="Fri *-*-* 22:00:00"   # server local time (UTC on most AMIs)
export PATCH_JITTER_MIN="120"                  # spread reboots across the fleet

if ! command -v git >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then apt-get update -q && apt-get install -y -q git
  else dnf install -y -q git || yum install -y -q git; fi
fi

SRC=/opt/os-patch-src
rm -rf "$SRC"
git -c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)" \
    clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC"

"$SRC/install.sh"
rm -rf "$SRC"    # install.sh copied it to /opt/os-patch/repo (origin URL has no token in it)
