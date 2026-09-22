# Future Improvements: Automated Host Registration

**The Goal:** Eliminate manual GUI administration by fully automating the end-to-end monitoring lifecycle, allowing new hypervisors to automatically register themselves with the Zabbix Server and attach their required templates immediately after Ansible deployment.

### Current State of this Role
Currently, this Ansible role strictly handles the OS-level deployment. It successfully installs the Zabbix Agent 2, injects the dynamic configuration, and points the agent to the Zabbix Server. However, **an administrator must still manually log into the Zabbix Web GUI to create the host** and link the templates before monitoring officially begins.

### Proposed Architecture: Active Auto-Registration
To fully automate this process, we recommend implementing Zabbix Active Auto-Registration. 

**How to implement:**
1. **Ansible Role Update:** Inject a `HostMetadata` variable into the `server-connection.conf.j2` drop-in file (e.g., `HostMetadata=linux-hypervisor`).
2. **Zabbix Server Update:** In the Zabbix GUI, navigate to *Alerts -> Actions -> Autoregistration actions* and configure a rule that automatically adds the host and links the templates whenever it detects that specific metadata.

### Security Options for Auto-Registration
Because accepting automated connections from any device on the network is an architectural risk, this improvement must be paired with a security tier:

* **Option 1: Default (Not Recommended):** The Zabbix server blindly accepts any connection. This allows rogue network devices to spoof hosts.
* **Option 2: Secret Token (Good):** The `HostMetadata` string acts as a password (e.g., `HostMetadata=DeployToken_884x`). Zabbix only auto-registers agents possessing this exact string.
* **Option 3: TLS Pre-Shared Keys (Enterprise/CIS Standard):** Ansible is configured to generate and deploy cryptographic keys (TLS PSK) to the agent. The Zabbix Server is configured to reject any auto-registration attempt that is not completely encrypted and cryptographically signed by that specific PSK.
