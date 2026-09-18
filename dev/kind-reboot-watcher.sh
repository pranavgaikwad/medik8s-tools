#!/bin/bash
# kind-reboot-watcher.sh — Simulates node reboot on Kind clusters
#
# On real hardware, SNR triggers a reboot (sysrq-trigger or watchdog), which
# restarts the machine and kubelet comes back up. Kind nodes share the host
# kernel, so the Kind configs mask SysRq and watchdog paths to block real reboots.
#
# This script watches worker nodes and when one becomes NotReady (kubelet
# stopped), it waits a configurable delay then restarts the Kind container,
# which brings kubelet back — simulating what a real reboot does.
#
# Usage:
#   ./kind-reboot-watcher.sh [--name <cluster>] [--delay <seconds>] [--once]
#   MEDIK8S_CLUSTER_NAME=my-cluster ./kind-reboot-watcher.sh &
#
# The script runs in the foreground by default. Use & or dev-reboot-watcher
# to background it. It exits when the cluster is torn down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
REBOOT_DELAY="${MEDIK8S_REBOOT_DELAY:-30}"
POLL_INTERVAL=5
ONCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) CLUSTER_NAME="$2"; shift 2 ;;
        --delay) REBOOT_DELAY="$2"; shift 2 ;;
        --once) ONCE=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--name <cluster>] [--delay <seconds>] [--once]"
            echo ""
            echo "Watches Kind worker nodes and restarts their containers when"
            echo "kubelet stops (simulating hardware reboot for SNR e2e tests)."
            echo ""
            echo "Options:"
            echo "  --name <cluster>   Kind cluster name (default: medik8s-dev)"
            echo "  --delay <seconds>  Wait before restarting container (default: 30)"
            echo "  --once             Exit after first reboot (for CI)"
            echo ""
            echo "Environment variables:"
            echo "  MEDIK8S_CLUSTER_NAME    Cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_REBOOT_DELAY    Reboot delay in seconds (default: 30)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Track nodes that are currently being "rebooted" to avoid double-restart
REBOOTING=" "

echo "[reboot-watcher] Watching Kind cluster '${CLUSTER_NAME}' (delay: ${REBOOT_DELAY}s)"
echo "[reboot-watcher] Container tool: ${CONTAINER_TOOL}"

# Get list of worker node containers
get_worker_nodes() {
    KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}" \
        kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep worker || true
}

# Check if kubelet is running on a node container
is_kubelet_running() {
    local node="$1"
    ${CONTAINER_TOOL} exec "$node" systemctl is-active kubelet &>/dev/null
}

# Check if node is NotReady via kubectl
is_node_not_ready() {
    local node="$1"
    local status
    status=$(${KUBECTL} get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$status" != "True" ]]
}

while true; do
    # Check cluster still exists
    if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}" kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        echo "[reboot-watcher] Cluster '${CLUSTER_NAME}' gone, exiting."
        exit 0
    fi

    WORKERS=$(get_worker_nodes)
    if [ -z "$WORKERS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    for node in $WORKERS; do
        # Skip nodes already being rebooted
        if [[ "$REBOOTING" == *" $node "* ]]; then
            # Check if reboot completed (kubelet running again)
            if is_kubelet_running "$node"; then
                echo "[reboot-watcher] $node: kubelet is back, reboot complete."
                REBOOTING="${REBOOTING/ $node / }"
            fi
            continue
        fi

        # Detect stopped kubelet (node becoming NotReady)
        if is_node_not_ready "$node" && ! is_kubelet_running "$node"; then
            echo "[reboot-watcher] $node: kubelet stopped, NotReady detected."
            echo "[reboot-watcher] $node: waiting ${REBOOT_DELAY}s before simulated reboot..."
            REBOOTING+="$node "

            # Restart in background so we keep watching other nodes
            (
                sleep "$REBOOT_DELAY"
                echo "[reboot-watcher] $node: restarting container (simulated reboot)..."
                ${CONTAINER_TOOL} restart "$node"
                echo "[reboot-watcher] $node: container restarted, waiting for kubelet..."
            ) &

            if [ "$ONCE" = true ]; then
                wait
                echo "[reboot-watcher] --once mode, exiting after first reboot."
                exit 0
            fi
        fi
    done

    sleep "$POLL_INTERVAL"
done
