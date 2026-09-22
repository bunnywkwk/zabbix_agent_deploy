# Air-Gapped Zabbix Agent Deployment: Engineering Justification

This document provides a quick and concise justification for the deployment configurations used to install Zabbix Agent 2 on fully air-gapped, CIS-hardened RHEL 9 and 10 hypervisors.

### 1. Dynamic Environment Support (Block/Rescue Pattern)
**Architecture:** The playbook utilizes an Ansible `block` and `rescue` pattern.
**Justification:** This makes the role environment-agnostic. It attempts a fast internet installation first. If the target lacks internet access, the playbook seamlessly falls back to pushing locally staged offline RPMs (`zabbix-release` and `zabbix-agent2`) to the target's `/usr/local/src/` directory for local installation.

### 2. The Chain Reaction: Disabling Repositories and GPG Checks
During the offline local installation (`rescue` block), two explicit DNF overrides are required: `disablerepo: "*"` and `disable_gpg_check: yes`. These are inextricably linked due to the following chain reaction:

1. **The Internet Crash (EPEL):** When installing a local `.rpm` file, `dnf` automatically attempts to reach the internet to refresh metadata for all enabled repositories (e.g., EPEL). In an air-gapped environment, this causes a fatal timeout.
2. **The Repo Fix:** To prevent the crash, we must inject `disablerepo: "*"` to force DNF to strictly focus on the local `.rpm` and ignore the internet.
3. **The GPG Consequence:** By disabling all repositories, DNF ignores all local `.repo` configuration files. Because it ignores these configuration files, it loses the mapped path to the Zabbix GPG public keys stored on the hard drive. 
4. **The Final Fix:** Without the path to the GPG keys, DNF cannot validate the signature of the local `.rpm` and crashes. Therefore, using `disablerepo: "*"` forces us to also use `disable_gpg_check: yes` to successfully install the package.

**Security Note:** Bypassing the local GPG check is architecturally safe in this specific scenario because the supply chain was manually verified. The `.rpm` binaries were securely downloaded over HTTPS directly from `repo.zabbix.com` to the Ansible Control Node prior to the automated push.
