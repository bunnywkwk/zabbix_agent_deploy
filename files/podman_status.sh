#!/bin/bash
# /etc/zabbix/scripts/podman_status.sh
#
# Emits ONE JSON document describing this host's Podman state.
# The Zabbix agent calls this once per interval; every item in the
# "Scope Containers" template is a dependent item derived from this output,
# so the host is touched once per minute no matter how many containers exist.
#
# Read-only by construction: /etc/sudoers.d/zabbix_podman permits exactly the
# three commands below and nothing else. No wildcards, no container mutation.

set -o pipefail

# Hosts without a container runtime return a valid, empty document.
# Discovery then finds nothing and no item prototype is ever instantiated.
if ! command -v podman >/dev/null 2>&1; then
    echo '{"present":0,"runtime_ok":0,"containers":[],"stats":[],"df":[]}'
    exit 0
fi

# Container inventory and lifecycle state. Also our runtime liveness probe:
# if this does not answer, Podman is not servicing management operations.
containers=$(sudo -n /usr/bin/podman ps -a --format json 2>/dev/null)

if [ -z "$containers" ]; then
    echo '{"present":1,"runtime_ok":0,"containers":[],"stats":[],"df":[]}'
    exit 0
fi

# Per-container CPU and memory. Empty when nothing is running, which is fine.
# The sed guard strips terminal control sequences podman emits before the JSON.
stats=$(sudo -n /usr/bin/podman stats --no-stream --format json 2>/dev/null | sed -n '/^\[/,$p')

# Image, container and volume storage consumption, plus reclaimable bytes.
df=$(sudo -n /usr/bin/podman system df --format json 2>/dev/null)

printf '{"present":1,"runtime_ok":1,"containers":%s,"stats":%s,"df":%s}\n' \
    "$containers" "${stats:-[]}" "${df:-[]}"
