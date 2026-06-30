#!/usr/bin/env bash
#
# Applies the CIS-aligned changes that are not audit rules:
# file permissions, login banners, and the extra SSH controls.
# Idempotent: safe to run more than once.
#
# Run as root. Review before running. This does not touch the
# firewall or partitioning controls, which are intentionally skipped.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

echo "[*] Cron directory and file permissions"
chmod 600 /etc/crontab
chmod 700 /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d
chown root:root /etc/crontab /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d

echo "[*] Login banners"
printf 'Authorized access only. All activity is monitored and logged.\n' > /etc/issue
printf 'Authorized access only. All activity is monitored and logged.\n' > /etc/issue.net
: > /etc/motd
chmod 644 /etc/issue /etc/issue.net /etc/motd
chown root:root /etc/issue /etc/issue.net /etc/motd

echo "[*] sudo log target (referenced by an audit rule)"
touch /var/log/sudo.log
chmod 600 /var/log/sudo.log

echo "[*] SSH: Banner, DisableForwarding, MaxStartups"
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)"
sed -i \
  -e 's|^#\?Banner.*|Banner /etc/issue.net|' \
  -e 's/^#\?DisableForwarding.*/DisableForwarding yes/' \
  -e 's/^#\?MaxStartups.*/MaxStartups 10:30:60/' \
  /etc/ssh/sshd_config

if sshd -t; then
  echo "[*] sshd config valid, reloading"
  systemctl reload sshd
else
  echo "[!] sshd config test failed, NOT reloading. Check the backup." >&2
  exit 1
fi

echo "[*] Done. Re-run the SCA scan to measure the new score."
