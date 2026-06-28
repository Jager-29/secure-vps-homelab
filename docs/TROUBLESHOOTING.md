# Troubleshooting and lessons

These are the problems that cost real time during this build. They are here
because they are more useful than a clean walkthrough that hides the friction.

## Docker bypasses UFW

Publishing a container port with `-p PORT:PORT` exposes it on all interfaces,
including the public one, regardless of UFW rules. Docker inserts its own
nftables rules ahead of UFW, so `ufw status` looks correct while the port is
actually reachable from the internet.

This was discovered by reaching an admin interface from both the VPN IP and the
public IP. The admin plane was wide open without any UFW rule allowing it.

Fix: use explicit bind addresses. Admin and private services publish as
`127.0.0.1:PORT:PORT` or `VPN_IP:PORT:PORT`. Only genuinely public services
publish as `PORT:PORT`. After starting any container, run `docker ps` and read
the PORTS column to confirm the interface. A public bind shows `0.0.0.0:PORT`,
a private one shows the loopback or VPN address.

## SIEM queue filled the disk after a password change

This was the longest single incident.

The SIEM admin password was changed on the indexer but not propagated to the
manager. The manager's log shipper kept using the old password, so every
attempt to index returned 401 Unauthorized. Events could not be written, so they
piled up in the manager queue. The queue grew to over twelve gigabytes.

Symptoms:

- Repeated `Failed to sync agent` warnings in the manager log
- `filebeat test output` returning `talk to server... ERROR 401 Unauthorized`
- The queue volume growing without bound

Root cause: the admin password must match across three places, the indexer, the
manager and the dashboard. Changing it in one place breaks the others silently.

A second problem made it worse. The first replacement password contained special
characters, including the literal word used by config keys and shell-significant
symbols. It did not survive encoding cleanly, so even after updating the manager
the indexer rejected it. Direct authentication against the indexer with both the
old and new passwords failed, which proved the stored password was neither.

Fix that worked:

1. Generate a long alphanumeric password with no special characters
2. Generate its hash with the indexer's hash tool
3. Put the hash in the indexer internal users file
4. Apply with the security admin tool, using the correct certificate paths
5. Confirm directly against the indexer that it accepts the new password
6. Set the same plain password in the compose file for the manager and the
   dashboard
7. Recreate the manager and dashboard
8. Confirm with `filebeat test output` returning OK

Lesson: never use exotic special characters in service passwords that travel
through config files and shell. Long alphanumeric is both strong and safe.

## The queue did not shrink on its own

After fixing authentication, indexing resumed but the queue stayed large. The
bulk was in the vulnerability detection cache, which had bloated during the
outage.

Clearing it: stop the manager, remove the vulnerability detection cache from the
queue volume, start the manager. The cache rebuilds itself on the next run.

A caution learned here: clearing the whole vulnerability directory was too
aggressive and removed database structure, triggering a full feed re-download and
a temporary error about a missing column family. It self-repairs by rebuilding,
but it is cleaner to remove only the transient cache files rather than the entire
directory.

The vulnerability detection module is the heaviest and most fragile part of the
SIEM, and most of the CVEs it reports on a Debian host are noise, because Debian
backports security fixes without changing version numbers. Consider whether you
need this module before keeping it.

## The IPS firewall bouncer is not a Docker image

The IPS agent runs fine in a container, but the component that actually enforces
bans at the firewall is not distributed as a Docker image. It must be installed
natively on the host and pointed at the agent's local API. Time was lost looking
for a container that does not exist.

## The SIEM container reports the wrong CIS policy

The configuration assessment inside the manager container runs against an Amazon
Linux policy, because the container image is based on Amazon Linux. This is
normal and unrelated to the host. The host's own agent runs the correct Debian
policy.

When reading the CIS report, select the host agent, not the manager's self
assessment. Confusing the two leads to reading a benchmark for the wrong
distribution.

## CIS partitioning checks on a VPS

The first CIS failures are separate partitions for /tmp, /home, /var and friends
with restrictive mount options. A VPS ships as a single partition from the
provider. Repartitioning a live system is risky for little gain in a homelab.
These checks are deliberately left failing. The point of CIS work is high impact
low risk changes, not chasing 100 percent.

## VM on a home connection sleeps at night

The remote agent on a home machine went offline at the same time every night,
and the filesystem came back read-only on wake. The cause was the home router
entering scheduled standby, which cut the VM without a clean shutdown.

A read-only root after an unclean stop can be remounted live if the filesystem
is healthy:

```bash
sudo mount -o remount,rw /
```

If that fails, a reboot with a filesystem check repairs it. Treat a machine on a
home connection as best effort, not 24/7. The critical stack lives on the VPS,
which runs in a datacenter.
