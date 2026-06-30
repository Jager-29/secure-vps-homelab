# CIS Hardening (Debian 13)

This folder documents the changes made to raise the CIS benchmark score
reported by the Wazuh SCA module on the VPS host. The starting point was a
fresh Debian 13 install scoring 45% against the **CIS Debian Linux 13 Benchmark
v1.1.0** policy that ships with Wazuh.

Everything here was applied on a live host and re-scanned after each change. If
you are hardening your own box from this repo, read the "What not to chase"
section first. A perfect score is neither reachable nor desirable on a VPS that
runs Docker, and forcing some controls will break your stack.

## How the score is measured

The score comes from the Wazuh agent on the host, not from an external scanner.
The agent runs the SCA module against the `cis_debian13` policy and reports
pass/fail per control to the manager. You can read the live result through the
Wazuh API instead of waiting for the dashboard to refresh:

```bash
# Authenticate (the API only listens on the Tailscale interface in this setup)
TOKEN=$(curl -s -k -X POST \
  -u 'API_USER:API_PASSWORD' \
  "https://YOUR_TAILSCALE_IP:55000/security/user/authenticate?raw=true")

# Summary score for agent 004
curl -s -k "https://YOUR_TAILSCALE_IP:55000/sca/004?pretty=true" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data.affected_items[] | "Score: \(.score)% | Pass: \(.pass) | Fail: \(.fail)"'

# Live count of failing controls (more up to date than the summary score)
curl -s -k "https://YOUR_TAILSCALE_IP:55000/sca/004/checks/cis_debian13?result=failed&limit=500" \
  -H "Authorization: Bearer $TOKEN" | jq '.data.total_affected_items'
```

Two things worth knowing before you start:

- The summary `score` field lags. After a scan it can keep showing the old
  number for a while. The `result=failed` count on the `/checks` endpoint is the
  honest, immediate figure. Trust that one.
- The SCA scan is not instant and does not re-run on every agent restart on its
  own schedule. To force one, drop the interval, restart the agent, wait for the
  scan to actually finish, then put the interval back:

```bash
sudo sed -i 's|<interval>12h</interval>|<interval>5m</interval>|' /var/ossec/etc/ossec.conf
sudo systemctl restart wazuh-agent
# a full scan takes ~110 seconds here, so wait longer than that
sleep 135
sudo grep "scan finished" /var/ossec/logs/ossec.log | tail -1
sudo sed -i 's|<interval>5m</interval>|<interval>12h</interval>|' /var/ossec/etc/ossec.conf
```

Reading the score too early is the single most common way to waste time here.
More than once a control looked like it had failed when in fact the scan had run
before the fix was on disk.

## How to find out what a control actually checks

Do not guess what a control wants. The policy tells you exactly. Pull the rule
definition for a control by its id and read the `rules` block, which contains
the literal pattern the agent matches against:

```bash
curl -s -k "https://YOUR_TAILSCALE_IP:55000/sca/004/checks/cis_debian13?q=id=33253&pretty=true" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data.affected_items[] | .title, (.rules[]?|.rule)'
```

For an audit rule control this returns something like
`c:auditctl -l -> r:^-w && r:/etc/sudoers && r:-p wa && r:-k scope`, which tells
you the agent runs `auditctl -l` and looks for those four tokens on one line.
This is how every fix in this folder was derived: read the pattern, match it
exactly.

## What was changed

The changes group into a few families. Each one is small on its own; the score
moves because there are a lot of them.

### Audit rules (the biggest single lever)

The CIS policy expects a specific, fairly large set of `auditd` rules with exact
keys. This is where most of the failing controls lived. The full rule set is in
[`audit-rules/cis.rules`](audit-rules/cis.rules). It covers time changes,
identity files, permission and ownership syscalls, mounts, session and login
records, file deletion, MAC policy, privileged command execution and kernel
module loading.

Two subtleties cost time:

- The agent checks both the **running** rules (`auditctl -l`) and the **file on
  disk** in `/etc/audit/rules.d/`. These two are not byte-identical. `auditd`
  rewrites some rules when it loads them, for example adding `-S all` to a
  path-based watch and normalising `-k key` into `-F key=key`. So the rule you
  write on disk and the rule that shows up at runtime differ, and the policy has
  a pattern for each. The file on disk for the privileged-command watches must
  be written **without** `-S all`; `auditd` adds it at load time, which then
  satisfies the runtime pattern. Write it with `-S all` and the on-disk pattern
  fails instead. You cannot win both with the same literal text, which is the
  whole point.
- `auditd` refuses to load if two rule files contain the same line, and it fails
  the entire service, not just the duplicate. The custom monitoring rules from
  the base hardening step overlapped with the CIS set on a handful of lines
  (`/etc/passwd`, `/etc/shadow`, and similar). The fix was to split the global
  directives (`-D`, `-b`, `-f`) into a `00-globals.rules` that loads first, strip
  the duplicates out of the hardening file, and let the CIS file own the shared
  watches. See [`audit-rules/README.md`](audit-rules/README.md) for the layout.

### Daemon configuration for the audit logs

A few controls read `/etc/audit/auditd.conf` rather than the rules, covering
what happens when the audit log fills up or is running low on space. These are
adjusted to keep logs rather than rotate them away, and to alert on low space.

### File permissions

Straightforward `chmod`/`chown` work with no risk: the cron directories
(`/etc/crontab`, `/etc/cron.{hourly,daily,weekly,monthly,d}`), and the login
banner files. These pass immediately and are pure score with no downside.

### Login banners

`/etc/issue` and `/etc/issue.net` get a plain authorized-access notice. `/etc/motd`
is emptied: the policy wants it to contain no OS identifiers (`\m`, `\r`, `\s`,
`\v`, or the distribution name), and the simplest way to pass cleanly is an empty
file.

### SSH

A second pass on top of the base SSH hardening, for the three controls the
baseline did not cover: `Banner`, `DisableForwarding` and `MaxStartups`.

## What not to chase

These controls fail and are deliberately left failing. Forcing them on this kind
of host is either impossible or actively harmful.

- **Separate partitions** (`/tmp`, `/home`, `/var`, `/var/log`, `/var/log/audit`,
  and the `nodev`/`nosuid`/`noexec` options that go with them). A VPS ships with
  a single provisioned disk. Repartitioning a live root filesystem for a handful
  of points is not worth the risk.
- **Bootloader password and config** (`33040`, `33043`, `33044`). The bootloader
  belongs to the hypervisor on a VPS. You do not control it.
- **Firewall policy controls for ufw / nftables / iptables**. This is the trap.
  These controls want a strict default-deny policy on a host firewall, but Docker
  writes its own nftables rules and CrowdSec manages bans at the firewall layer.
  Forcing the CIS firewall policy here breaks container networking and the IPS
  bouncer. The network is already protected by Docker's own rules, the IPS, and
  by binding admin and agent ports to the VPN interface. The SCA cannot see that,
  so it reports the controls as failed. Leave them.

The realistic target on a Docker VPS is somewhere around 65 to 85 percent, by
fixing everything that is a genuine improvement and consciously skipping the rest.

## Applying it

The rule files in `audit-rules/` go into `/etc/audit/rules.d/`. After copying
them in, load and restart:

```bash
sudo augenrules --load
sudo systemctl restart auditd
sudo systemctl is-active auditd     # must print "active"
sudo /sbin/auditctl -l | wc -l      # sanity check the rule count
```

If `auditd` comes back inactive, the cause is almost always a duplicate line
across two files in `/etc/audit/rules.d/`. Find it with:

```bash
cat /etc/audit/rules.d/*.rules | grep '^-w\|^-a' | sort | uniq -d
```

Then re-scan with the forced-scan snippet above and read the failed count.
