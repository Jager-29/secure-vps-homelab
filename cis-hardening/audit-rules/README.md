# Audit rule files

These files go into `/etc/audit/rules.d/`. They are loaded in alphabetical
order by `augenrules`, concatenated into `/etc/audit/audit.rules`, and applied
at service start.

The order matters because of `-D`.

```
00-globals.rules    global directives: delete-all (-D), buffer size (-b), failure mode (-f)
cis.rules           the CIS Debian 13 audit rule set
hardening.rules     extra watches specific to this host (Docker, SSH, Wazuh config, cron)
```

## Why the split

`-D` means "delete all loaded rules". If it sits inside a file that loads after
the CIS rules, it wipes everything that was already loaded and the scan finds
nothing. Keeping the global directives in `00-globals.rules` guarantees they run
first, before any actual rule is added.

The default Debian `audit.rules` shipped its own `-D`, `-b` and `-f`. It was
removed, because those directives now live in `00-globals.rules` and having them
declared twice caused the load to fail.

## The on-disk vs runtime difference

`auditd` does not store rules exactly as you write them. On load it normalises
them. Two cases that matter for the CIS patterns:

- A path watch written as
  `-a always,exit -F path=/usr/bin/chcon -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng`
  comes back from `auditctl -l` as
  `-a always,exit -S all -F path=/usr/bin/chcon -F perm=x -F auid>=1000 -F auid!=-1 -F key=perm_chng`.
  Note the added `-S all`, the `auid!=unset` rewritten to `auid!=-1`, and `-k`
  rewritten to `-F key=`.
- The CIS policy checks both forms: the on-disk file (looking for the version
  **without** `-S all`) and the runtime output (looking for the version **with**
  `-S all`). So the file must be written without `-S all`, and `auditd` produces
  the runtime form for you. Adding `-S all` yourself makes the on-disk check
  fail.

If a control that looks correct keeps failing, dump both forms and compare token
by token:

```bash
sudo grep chcon /etc/audit/rules.d/cis.rules      # what is on disk
sudo /sbin/auditctl -l | grep chcon               # what is actually loaded
```

## Duplicates break the whole service

`auditd` will not load a rule set that contains the same line twice, even across
different files, and it fails the entire service rather than skipping the
duplicate. Before restarting, check:

```bash
cat /etc/audit/rules.d/*.rules | grep '^-w\|^-a' | sort | uniq -d
```

This must print nothing. If it prints a line, that line exists in two files;
remove it from one of them.
