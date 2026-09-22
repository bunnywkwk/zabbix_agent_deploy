Zabbix Agent Deploy
====================

Installs and configures Zabbix Agent 2 on monitored RHEL 9/10 hosts, and
prepares each host locally so that whichever Zabbix templates end up linked
to it (via the separate `zabbix_template_deploy` / `zabbix_host_link` roles)
can actually collect data instead of returning "Not supported."

This role never talks to the Zabbix server's API. It only ever touches the
host it's running on, over SSH with `become: yes`. Deploying the template
*definitions* onto the Zabbix server itself is a different role
(`zabbix_template_deploy`), because it's a completely different connection
type (httpapi, not ssh) and a completely different concern (what a template
says to collect, vs. whether this specific host is even allowed to answer
that collection request).

Purpose & Approach
-------------------

The role does three things, in order:

1. **Installs Zabbix Agent 2.** Tries the internet-facing Zabbix 8.0
   repository first; if that fails (air-gapped host), falls back to
   locally staged offline RPMs pushed from the control node. See
   `docs/Air_Gapped_Troubleshooting_Log.md` for why the offline path needs
   `disablerepo: "*"` and `disable_gpg_check: yes` together, and why that's
   safe here specifically (the RPMs were verified over HTTPS from
   `repo.zabbix.com` before being staged).

2. **Points the agent at the Zabbix server.** Deploys a drop-in config
   (`server-connection.conf.j2`) under `/etc/zabbix/zabbix_agent2.d/`
   rather than editing the shipped `zabbix_agent2.conf` directly, so a
   package upgrade never clobbers a local edit.

3. **Grants the agent exactly the host-side access each linked cluster's
   items need, and no more.** This is the part that's easy to miss:
   a template can be perfectly designed and perfectly imported on the
   server, and every item will still fail on a real RHEL host, because by
   default the `zabbix` service account can't read `/var/log/audit`,
   can't run `virsh`, can't run `vgs`, and so on. Which of these get set
   up on a given host is driven entirely by `zabbix_agent_clusters` (see
   below) — a host not in a cluster gets nothing extra touched for it.

   | Cluster ID            | What gets granted, and how                                                        |
   | ---------------------- | ----------------------------------------------------------------------------------- |
   | `host_health`          | ACL: `zabbix` read access on `/var/log/messages`                                    |
   | `storage`               | UserParameter config + sudoers grant for `vgs` (no native LVM plugin exists)         |
   | `virtualisation`        | UserParameter config + sudoers grant for `virsh` (no native libvirt plugin exists)   |
   | `containers`            | UserParameter config + sudoers grant + wrapper script for `podman`                  |
   | `host_access`           | `log_group = zabbix` in `auditd.conf` + execute ACL on `/var/log/audit` (shared)     |
   | `privileged_activity`   | Same as `host_access` — both clusters read `audit.log`, so they share one setup step |

   Every deployed config file is `root:root 0644` (root writes, everyone
   reads — the write-protection, not secrecy, is what matters: it stops a
   compromised agent process from rewriting what it's allowed to run via
   `sudo`). Every sudoers drop-in is `root:root 0440` and validated with
   `visudo -cf` before being placed, and grants only the exact read-only
   commands each cluster's items need — nothing can create, start, stop or
   modify anything.

Requirements
------------

- RHEL 9 or RHEL 10 target host (the repo URL and offline RPM filenames
  are built from `ansible_distribution_major_version`).
- `become: yes` — every task in this role requires root.
- The `ansible.posix` collection (`acl` and `firewalld` modules).
- The `community.zabbix` collection is **not** required by this role —
  that's only needed by `zabbix_template_deploy` / `zabbix_host_link`.
- For air-gapped targets: the 4 offline RPMs must be present in
  `files/` before running. They're gitignored (~13MB, don't belong in
  git history) — see `.gitignore` for the exact filenames and where to
  source them from.

Role Variables
---------------

Defined in `defaults/main.yml`:

| Variable                | Default              | Purpose                                                                 |
| ------------------------ | --------------------- | ------------------------------------------------------------------------ |
| `zabbix_server_ip`       | `192.168.10.160`      | Where the agent's `Server`/`ServerActive` directives point.             |
| `zabbix_agent_clusters`  | `[]`                  | Which requirement clusters this host is monitored under. Drives the table above. Valid values: `host_health`, `storage`, `virtualisation`, `containers`, `host_access`, `privileged_activity`. An empty list means only the base agent gets installed — no per-cluster access is touched. |

In practice, `zabbix_agent_clusters` is set per inventory group rather
than per host — see `tests/group_vars/` for the pattern (a shared
baseline list for every plain RHEL host, with `hypervisors` and
`container_hosts` subgroups adding one extra cluster each via list
concatenation).

Dependencies
------------

None (no other roles). Requires the `ansible.posix` collection to be
installed on the control node (`ansible-galaxy collection install
ansible.posix`) — not yet pinned to a `requirements.yml` in this repo.

Example Playbook
------------------

    - hosts: rhel_nodes:hypervisors:container_hosts
      become: yes
      roles:
        - zabbix_agent_deploy

With inventory groups supplying `zabbix_agent_clusters` per host, e.g.:

    # group_vars/all.yml
    zabbix_agent_clusters_baseline:
      - host_health
      - host_access
      - privileged_activity
      - storage
    zabbix_agent_clusters: "{{ zabbix_agent_clusters_baseline }}"

    # group_vars/hypervisors.yml
    zabbix_agent_clusters: "{{ zabbix_agent_clusters_baseline + ['virtualisation'] }}"

    # group_vars/container_hosts.yml
    zabbix_agent_clusters: "{{ zabbix_agent_clusters_baseline + ['containers'] }}"

Known Limitations
-------------------

- The `/var/log/messages` ACL granted for `host_health` is not guaranteed
  to survive log rotation if logrotate recreates the file rather than
  truncates it — unlike the `auditd` `log_group` approach used for the
  audit-based clusters, which is rotation-safe by design. Re-running this
  role re-applies the ACL if it's been dropped.
- The `storage` cluster's `lvm.vg.free` UserParameter and the
  `virtualisation` cluster's `kvm.pool.discovery` pipeline were written
  by extending an incomplete study guide by analogy to a documented
  sibling command, rather than being copied verbatim from a proven
  source — worth a real test against a host with actual LVM volume
  groups / storage pools before trusting them blind.
- Auto-registration (agents self-attaching to the server on first
  contact, instead of `zabbix_host_link` doing it from the control node)
  is deliberately not implemented — see `docs/Future_Improvements.md` for
  the proposed `HostMetadata` + TLS PSK design.

License
-------

MIT-0

Author Information
--------------------

Part of the `zabbix-roles` project: RHEL observability templates and
their Ansible deployment automation, built cluster-by-cluster against
requirements mapped in `~/zabbix/docs/zabbix_template_mapping_plan.md`.
