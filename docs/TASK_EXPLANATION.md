# zabbix_agent_deploy — the tasks, block by block

Plain-language walkthrough of every task file in this role: what each
line does, why it is there, and whether it is really needed. Written
against the code as it stands; every path below is relative to this
role's folder.

## What this role is for (one paragraph)

It runs **over SSH on each monitored RHEL host** (not against Zabbix).
Its job is to make a host *ready to be monitored*: install Zabbix
Agent 2, point it at the Zabbix server, and grant the `zabbix` user
just enough local access for the templates that will later be linked to
the host. It never touches the Zabbix server itself — creating the host
object and linking templates is `zabbix_host_link`'s job.

## How the pieces call each other

```
tasks/main.yml
 ├─ repo_setup.yml         1. add Zabbix's package repo
 ├─ agent_install.yml      2. install the zabbix-agent2 package
 ├─ agent_config.yml       3. write Server=/ServerActive=/Hostname=
 ├─ cluster_access.yml     4. per-cluster access (decides which of these run):
 │    ├─ cluster_host_health.yml    (if 'host_health' in zabbix_agent_clusters)
 │    ├─ cluster_storage.yml        (if 'storage')
 │    ├─ cluster_virtualisation.yml (if 'virtualisation')
 │    ├─ cluster_containers.yml     (if 'containers')
 │    └─ cluster_audit_access.yml   (if 'host_access' OR 'privileged_activity')
 │         (host_health and audit both first run ensure_acl_support.yml)
 └─ service_enable.yml     5. open firewall port, enable + start the service
handlers/main.yml          restart the agent / auditd when config changed
```

The order matters: the package must exist before its config directory
is used, and the service is started last so it comes up with the final
configuration.

---

## 1. `tasks/main.yml` — the table of contents

```yaml
- name: Set up the Zabbix package repository
  ansible.builtin.include_tasks: repo_setup.yml
- name: Install the Zabbix Agent 2 package
  ansible.builtin.include_tasks: agent_install.yml
- name: Deploy the base agent configuration
  ansible.builtin.include_tasks: agent_config.yml
- name: Configure per-cluster monitoring access on this host
  ansible.builtin.include_tasks: cluster_access.yml
- name: Enable and start the Zabbix Agent 2 service
  ansible.builtin.include_tasks: service_enable.yml
```

- Each block is `include_tasks`: "go run that file's tasks here." It
  keeps `main.yml` readable as a five-step recipe instead of one long
  file.
- **Why needed:** a single order-of-operations list makes the role
  easy to follow and lets each step be edited in isolation.
- **Relevant?** Yes — pure structure, no behavior of its own.

---

## 2. `tasks/repo_setup.yml` — get the Zabbix repository onto the host

Three tasks, in order. Internet only: the target hosts are fresh
RHEL 9.x / 10.1 with internet access and no EPEL, so there is no
EPEL handling and no offline fallback.

**Task: "Construct Zabbix Release RPM URL"**
```yaml
ansible.builtin.set_fact:
  zabbix_repo_url: "https://repo.zabbix.com/zabbix/8.0/release/rhel/{{ ansible_distribution_major_version }}/noarch/\
    zabbix-release-latest-8.0.el{{ ansible_distribution_major_version }}.noarch.rpm"
```
- Builds the download URL and drops in the host's RHEL major version
  (`9` or `10`), a fact Ansible gathered automatically. The trailing
  `\` just continues the string on the next line.
- **Why:** one task works for both RHEL 9 and RHEL 10 instead of two
  hard-coded URLs. This is why `deploy_agents.yml` must leave fact
  gathering **on** (unlike `deploy_zabbix.yml`).

**Task: "Import the Zabbix GPG key"**
```yaml
ansible.builtin.rpm_key:
  key: https://repo.zabbix.com/zabbix-official-repo.key
  state: present
```
- Trusts Zabbix's package-signing key so `dnf` can verify what it
  installs. (Added earlier to fix a "download issues" failure; kept.)

**Task: "Install the Zabbix 8.0 release repository"**
```yaml
ansible.builtin.dnf:
  name: "{{ zabbix_repo_url }}"
  state: present
```
- `dnf` can install straight from a URL. This installs the
  `zabbix-release` package, which drops the Zabbix repo definition onto
  the host so `zabbix-agent2` can be installed from it next.
- `state: present` = install if missing, do nothing if already there.
- **Relevant?** Yes: without the repo the agent package can't be found.

**What was removed, and how to bring it back if needed:**
- The EPEL check + `excludepkgs=zabbix*` edit: only matters if EPEL is
  enabled. Fresh RHEL 9.x / 10.1 has none (checked on the live hosts).
- The `block`/`rescue` offline fallback, `disablerepo` and
  `disable_gpg_check`: only needed for hosts with no internet. If an
  air-gapped host returns, `docs/Air_Gapped_Troubleshooting_Log.md`
  records exactly why those flags were needed.

---

## 3. `tasks/agent_install.yml` — install the agent package

```yaml
- name: Install Zabbix Agent 2
  ansible.builtin.dnf:
    name: zabbix-agent2
    state: present
```

- A single `dnf` install of `zabbix-agent2` from the repo added in the
  previous step. `state: present` keeps re-runs safe.
- **Why needed:** the package is the agent. Nothing else works without it.
- **Relevant?** Yes.

---

## 4. `tasks/agent_config.yml` — tell the agent who to talk to

**Task: "Ensure Zabbix drop-in directory exists"**
```yaml
ansible.builtin.file:
  path: /etc/zabbix/zabbix_agent2.d
  state: directory
  owner: root
  group: root
  mode: "0755"
```
- Makes sure the folder for extra config files exists, owned by root,
  readable by everyone but writable only by root.
- **Why:** everything this role adds (server address, UserParameters)
  goes in this folder as small "drop-in" files instead of editing the
  main `zabbix_agent2.conf`. A package update can therefore never
  overwrite this role's settings.

**Task: "Deploy the Zabbix Drop-In Configuration File"**
```yaml
ansible.builtin.template:
  src: server-connection.conf.j2
  dest: /etc/zabbix/zabbix_agent2.d/server-connection.conf
  owner: root
  group: root
  mode: "0644"
notify: Restart Zabbix Agent 2
```
- Renders `templates/server-connection.conf.j2` and writes it to the
  host. The template is three lines:
  - `Server={{ zabbix_server_ip }}` — which server may poll this agent
    (passive checks).
  - `ServerActive={{ zabbix_server_ip }}` — which server this agent
    pushes to (active checks).
  - `Hostname={{ inventory_hostname }}` — the name this agent reports
    itself as.
- `notify:` queues the "Restart Zabbix Agent 2" handler — but only if
  the file actually *changed*, so re-runs don't bounce the service.
- **Why needed:** without `Server=` the agent refuses all polling.
  `Hostname=` matters just as much: it must equal the host name
  `zabbix_host_link` registers on the server (both come from the same
  inventory name, so they agree without anyone typing it twice).
- **Relevant?** Yes — the most important file the role writes.
- **Watch out:** `zabbix_server_ip` is `192.168.20.10` (set in the
  inventory), *not* `192.168.10.160`. The role's own fallback in
  `defaults/main.yml` is still `192.168.10.160`, which is the wrong
  subnet for agents. It's harmless while the inventory always sets the
  value, but a run without that inventory would silently produce agents
  that never report.

---

## 5. `tasks/cluster_access.yml` — the switchboard

```yaml
- name: Configure Host Health log access
  ansible.builtin.include_tasks: cluster_host_health.yml
  when: "'host_health' in zabbix_agent_clusters"
...
- name: Configure audit-based log access (Host Access / Privileged Activity)
  ansible.builtin.include_tasks: cluster_audit_access.yml
  when: "'host_access' in zabbix_agent_clusters or 'privileged_activity' in zabbix_agent_clusters"
```

- Five `include_tasks` lines, each guarded by `when:`. The `when` asks
  "is this cluster's ID in this host's `zabbix_agent_clusters` list?"
- The last one uses `or` because Host Access and Privileged Activity
  both read the same audit log, so they share one task file.
- **Why needed:** this is what makes access **least-privilege per
  host**. A plain VM gets no `virsh` or `podman` sudo rights because
  its list never contains `virtualisation`/`containers`.
- **Relevant?** Yes — it is the reason the cluster idea works. The
  list comes from inventory (`group_vars/`), so *where a host sits in
  the inventory decides what it is granted*.
- A host with an empty list simply skips all five.

---

## 6. `tasks/ensure_acl_support.yml` — make sure `setfacl` exists

```yaml
- name: Ensure the acl package is installed (setfacl/getfacl)
  ansible.builtin.dnf:
    name: acl
    state: present
```

- Installs the `acl` package (provides `setfacl`/`getfacl`).
- **Why:** the `ansible.posix.acl` module used below shells out to
  those tools. Checked on the live hosts: a fresh RHEL 9 already has
  `acl`, a fresh RHEL 10.1 does **not**, so this task really does work
  on RHEL 10.
- Shared: included by both `cluster_host_health.yml` and
  `cluster_audit_access.yml`. On a host with both it runs twice, which
  is harmless (already installed = no change).
- **If it fails on RHEL 10 with a GPG-signature error:** earlier runs
  hit that here. The fix that worked then was importing
  `/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release` with `rpm_key` first
  (and, when that wasn't enough, `disable_gpg_check: yes`). Both were
  removed as unproven on the current hosts; re-add only if the error
  comes back.
- **Relevant?** Yes, for the host_health and audit-based clusters.

---

## 7. `tasks/cluster_host_health.yml` — read `/var/log/messages`

```yaml
- ansible.builtin.include_tasks: ensure_acl_support.yml
- ansible.posix.acl:
    path: /var/log/messages
    entity: zabbix
    etype: user
    permissions: r
    state: present
```

- After making sure ACL tools exist, add an ACL entry: **user `zabbix`
  may read `/var/log/messages`**. `etype: user` says the entity is a
  user (not a group); `permissions: r` is read-only.
- **Why:** the Host Health template's log items (kernel errors, OOM
  kills, boot outcome) read that file, and it is root-only by default.
  An ACL grants exactly one extra reader without changing the file's
  owner or making it world-readable.
- **Relevant?** Yes for the Host Health cluster (which every host
  gets). Be aware an ACL lives on the file itself, so it can be lost if
  log rotation recreates the file — the audit tasks below avoid that
  differently.

---

## 8. `tasks/cluster_audit_access.yml` — read the audit log

**Task: "Ensure auditd hands audit.log group ownership to zabbix"**
```yaml
ansible.builtin.lineinfile:
  path: /etc/audit/auditd.conf
  regexp: '^log_group\s*='
  line: "log_group = zabbix"
  state: present
notify: Restart auditd
```
- Finds the line starting `log_group =` in auditd's config and sets it
  to `log_group = zabbix` (adds it if absent). Queues an auditd restart
  so the change takes effect.
- **Why:** auditd owns and rotates `audit.log` itself, so a file ACL
  would be wiped at the next rotation. Telling auditd to give the
  `zabbix` group ownership is a setting that survives rotation.

**Task: "Grant zabbix execute (traverse) access to /var/log/audit"**
```yaml
ansible.posix.acl:
  path: /var/log/audit
  entity: zabbix
  etype: user
  permissions: x
  state: present
```
- The directory is root-only, so group-read on the file is not enough
  to reach it. `x` (execute) on a directory means "may walk through it
  to a known filename" without being able to list what is inside.
- **Relevant?** Yes — Host Access and Privileged Activity both need the
  audit log, and this is the smallest grant that lets them reach it.

---

## 9. The three "UserParameter + sudoers" clusters

These three files follow one pattern: **(a)** drop a `.conf` telling
the agent about custom commands, **(b)** drop a sudoers file letting
`zabbix` run exactly those commands as root.

| Piece | What it is | Why |
| --- | --- | --- |
| `UserParameter=key,command` (in `files/*.conf`) | A custom item the agent can answer, e.g. `lvm.vg.free[vg]` | No built-in Zabbix item exists for LVM/KVM/Podman |
| `zabbix ALL=(root) NOPASSWD: <exact commands>` (in `files/*.sudoers`) | Lets `zabbix` run only those commands as root without a password | The agent runs as the unprivileged `zabbix` user; `vgs`/`virsh`/`podman` need root |

Each `copy` of a sudoers file uses `validate: 'visudo -cf %s'`, which
syntax-checks the file *before* installing it, and `mode: '0440'`
(read-only, required by sudo). A typo therefore fails the task instead
of installing a broken sudoers file that could lock out sudo.

### `cluster_storage.yml` (LVM)
- Copies `zabbix_lvm.conf` → `/etc/zabbix/zabbix_agent2.d/` (notifies
  an agent restart, since new UserParameters need one).
- Copies `zabbix_lvm.sudoers` → `/etc/sudoers.d/zabbix_lvm`.
- The sudoers allows only `vgs` report commands (list names, size,
  free) — none of which can create, extend, remove, or modify a volume
  group.

### `cluster_virtualisation.yml` (KVM)
- Same two steps with `zabbix_virtualisation.conf` / `.sudoers`.
- The UserParameters list VMs and storage pools and read state,
  CPU/RAM/disk stats and snapshot counts; the sudoers allows only those
  read-only `virsh` subcommands. The trailing `*` covers the VM/pool
  name, which is the one dynamic part.

### `cluster_containers.yml` (Podman) — one extra step
- First creates `/etc/zabbix/scripts` (`root:root`, `0755`).
- Copies `podman_status.sh` there as `root:zabbix`, mode `0750` — root
  can edit it, the `zabbix` group can run it, nobody else can. Owned by
  root **on purpose**: a compromised agent process can't rewrite what
  it is allowed to run as root.
- The script prints **one** JSON document (containers, stats, disk
  usage); the template's items are all derived from that single call,
  so the host is queried once per interval however many containers run.
  On a host without podman it returns a valid empty document instead of
  erroring.
- `zabbix_podman.conf` holds a single `UserParameter=podman.status,...`;
  `zabbix_podman.sudoers` allows exactly three podman commands, no
  wildcards.
- **Relevant?** Yes — these are the mechanism behind the Storage,
  Virtualisation and Containers templates. Without them those templates
  would show every item as "Not supported".

---

## 10. `tasks/service_enable.yml` — open the door and start the agent

**Task: "Ensure firewalld allows Zabbix Agent port 10050"**
```yaml
ansible.posix.firewalld:
  port: 10050/tcp
  permanent: true
  immediate: true
  state: enabled
```
- Opens TCP 10050 (the agent's listening port). `permanent` writes it
  to the saved config so it survives reboot; `immediate` applies it to
  the running firewall now.
- **Why:** the server polls the agent on that port. Note this matches
  the `port: "10050"` `zabbix_host_link` puts in the Zabbix interface.

**Task: "Ensure Zabbix Agent 2 is enabled and running"**
```yaml
ansible.builtin.systemd:
  name: zabbix-agent2
  state: started
  enabled: true
```
- `started` = run it now; `enabled` = run it at every boot.
- **Relevant?** Yes — without it the agent is installed but silent.

---

## 11. `handlers/main.yml` — restart only when needed

```yaml
- name: Restart Zabbix Agent 2
  ansible.builtin.systemd:
    name: zabbix-agent2
    state: restarted

- name: Restart auditd
  ansible.builtin.command: service auditd restart
  changed_when: true
```

- A **handler** only runs when a task that `notify`-ed it reported a
  change, and it runs once at the end no matter how many tasks
  notified it. That's why a re-run with nothing changed restarts
  nothing.
- "Restart Zabbix Agent 2" is triggered by new config/UserParameter
  files (agent reads them only at start).
- "Restart auditd" uses `service auditd restart` rather than the
  systemd module because RHEL's auditd unit refuses a normal systemctl
  restart; `changed_when: true` is needed because a raw `command` can't
  tell Ansible whether anything changed.

---

## 12. Variables the tasks read

| Variable | Where it's set | Used by |
| --- | --- | --- |
| `zabbix_server_ip` | `zabbix-deploy/inventory/group_vars/zabbix_agents.yml` (role fallback in `defaults/main.yml` is the wrong subnet — see note in §4) | `server-connection.conf.j2` |
| `zabbix_agent_clusters` | inventory `group_vars/` (role default is `[]`) | every `when:` in `cluster_access.yml` |
| `ansible_distribution_major_version` | Ansible facts (gathered automatically) | repo URL and RPM file names |
| `inventory_hostname` | Ansible built-in | `Hostname=` in the agent config |

## Quick "is it really needed?" summary

| Piece | Needed? | Why |
| --- | --- | --- |
| Repo setup + install | Yes | No agent without them (internet install only) |
| Drop-in config | Yes | Server address + host name; agent silent without it |
| Cluster switchboard | Yes | Gives each host only the access its templates need |
| ACL support task | Yes for host_health/audit | Provides `setfacl` (missing on fresh RHEL 10.1) |
| LVM/KVM/Podman files | Only for hosts in that cluster | Backs the custom items those templates use |
| Firewall + service | Yes | Server must reach the agent, and it must be running |
