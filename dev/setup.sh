#!/bin/bash
# Medik8s development environment setup
# Creates a Kind cluster with 1 CP + 2 worker nodes (default), installs OLM,
# and prepares the namespace for operator deployment.
#
# Usage: ./setup.sh [--skip-olm] [--skip-registry] [--name <cluster-name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-dev}"
# Shared namespace for dev resources (PSA-privileged). Operators deploy into
# their own namespaces (from kustomization.yaml), not this one.
DEV_NS="${MEDIK8S_NAMESPACE:-medik8s-system}"
INSTALL_OLM=true
SKIP_KIND=false
SKIP_INOTIFY_CHECK=false
SKIP_REGISTRY="${SKIP_REGISTRY:-false}"
REG_NAME="${MEDIK8S_REGISTRY_NAME:-kind-registry}"
REG_PORT="${MEDIK8S_REGISTRY_PORT:-5000}"
KIND_HA="${KIND_HA:-false}"
KIND_EXTRA_WORKERS="${KIND_EXTRA_WORKERS:-false}"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-kind)
            SKIP_KIND=true
            shift
            ;;
        --skip-olm)
            INSTALL_OLM=false
            shift
            ;;
        --skip-inotify-check)
            SKIP_INOTIFY_CHECK=true
            shift
            ;;
        --skip-registry)
            SKIP_REGISTRY=true
            shift
            ;;
        --ha)
            KIND_HA=true
            shift
            ;;
        --extra-workers)
            KIND_EXTRA_WORKERS=true
            shift
            ;;
        --name)
            if [[ $# -lt 2 ]]; then
                echo "Error: --name requires a cluster name argument."
                exit 1
            fi
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-kind] [--skip-olm] [--skip-inotify-check] [--ha] [--extra-workers] [--name <cluster-name>]"
            echo ""
            echo "Options:"
            echo "  --skip-kind           Skip Kind cluster creation (use existing cluster)"
            echo "  --skip-olm            Skip OLM installation"
            echo "  --skip-registry       Skip local registry creation"
            echo "  --skip-inotify-check  Skip inotify limits check"
            echo "  --ha                  Use HA config (3 CP + 3 workers, for SNR CP testing)"
            echo "  --extra-workers       Add a 3rd worker node (needed for storm simulation)"
            echo "  --name                Kind cluster name (default: medik8s-dev)"
            echo ""
            echo "Environment variables:"
            echo "  DEV_REGISTRY              Image delivery: 'registry' (local registry, default for Kind),"
            echo "                            'local' (kind load, no registry), 'ttl.sh' (ephemeral push)"
            echo "  MEDIK8S_REGISTRY_NAME     Local registry container name (default: kind-registry)"
            echo "  MEDIK8S_REGISTRY_PORT     Local registry port (default: 5000)"
            echo "  MEDIK8S_CLUSTER_NAME      Kind cluster name (default: medik8s-dev)"
            echo "  MEDIK8S_NAMESPACE         Shared dev namespace (default: medik8s-system)"
            echo "  CERT_MANAGER_VERSION      Cert-manager version (default: v1.17.2)"
            echo "  SKIP_KIND                 Set to 'true' to skip Kind cluster creation"
            echo "  SKIP_REGISTRY             Set to 'true' to skip local registry creation"
            echo "  KIND_HA                   Set to 'true' for HA config (3 CP + 3 workers)"
            echo "  KIND_EXTRA_WORKERS        Set to 'true' to add a 3rd worker node"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "${KIND_HA}" = true ]; then
    KIND_CONFIG="${SCRIPT_DIR}/kind-config-ha.yaml"
elif [ "${KIND_EXTRA_WORKERS}" = true ]; then
    # Create a temporary config with an extra worker node appended
    KIND_CONFIG_TMP=$(mktemp /tmp/kind-config-XXXXXX.yaml)
    # Insert extra worker before containerdConfigPatches
    sed '/^containerdConfigPatches:/i\  - role: worker' "${SCRIPT_DIR}/kind-config.yaml" > "${KIND_CONFIG_TMP}"
    KIND_CONFIG="${KIND_CONFIG_TMP}"
    trap 'rm -f "${KIND_CONFIG_TMP}"' EXIT
fi

# Check prerequisites
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 is required but not installed."
        echo "Install it from: $2"
        exit 1
    fi
}

echo "Using kubectl command: ${KUBECTL}"
echo "Using container tool: ${CONTAINER_TOOL}"

if [ "${SKIP_KIND}" = true ]; then
    echo "Using existing cluster (--skip-kind)."
    # Verify cluster connectivity
    if ! ${KUBECTL} cluster-info >/dev/null 2>&1; then
        echo "Error: cannot connect to cluster. Check your kubeconfig."
        exit 1
    fi
else
    check_tool kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    check_tool go "https://go.dev/doc/install"

    # Kind >= 0.22.0 defaults to K8s 1.29+, required for cert-manager CRD features (selectableFields).
    MIN_KIND_VERSION="0.22.0"
    KIND_VERSION=$(kind version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "${KIND_VERSION}" ] && printf '%s\n%s\n' "${MIN_KIND_VERSION}" "${KIND_VERSION}" | sort -V -C; then
        : # version is sufficient
    else
        echo "Error: Kind >= ${MIN_KIND_VERSION} is required (found: ${KIND_VERSION:-unknown})."
        echo "Install from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        exit 1
    fi

    export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}"

    # Pre-cluster registry setup: configure host DNS and Docker daemon BEFORE
    # creating the Kind cluster (Docker restart would kill Kind containers).
    if [ "${SKIP_REGISTRY}" != true ]; then
        echo "=== Configuring host for local registry '${REG_NAME}:${REG_PORT}' ==="

        # Make the registry hostname resolvable from the host.
        if ! getent hosts "${REG_NAME}" >/dev/null 2>&1; then
            if [ -w /etc/hosts ] || [ "$(id -u)" = "0" ]; then
                echo "127.0.0.1 ${REG_NAME}" >> /etc/hosts
                echo "  Added ${REG_NAME} to /etc/hosts."
            elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
                echo "127.0.0.1 ${REG_NAME}" | sudo tee -a /etc/hosts >/dev/null
                echo "  Added ${REG_NAME} to /etc/hosts (via sudo)."
            else
                echo "  Warning: ${REG_NAME} is not in /etc/hosts and we don't have write access."
                echo "  Run: echo '127.0.0.1 ${REG_NAME}' | sudo tee -a /etc/hosts"
            fi
        else
            echo "  ${REG_NAME} already resolvable from host."
        fi

        # Configure Docker to allow HTTP (insecure) access to the registry.
        # Must happen before Kind cluster creation since Docker restart kills containers.
        if [ "${CONTAINER_TOOL}" = "docker" ]; then
            DAEMON_JSON="/etc/docker/daemon.json"
            INSECURE_ENTRY="${REG_NAME}:${REG_PORT}"
            if [ -f "${DAEMON_JSON}" ] && grep -q "${INSECURE_ENTRY}" "${DAEMON_JSON}" 2>/dev/null; then
                echo "  Docker already configured for insecure registry ${INSECURE_ENTRY}."
            else
                _write_daemon_json() {
                    local target="$1"
                    if [ -f "${target}" ] && [ -s "${target}" ]; then
                        python3 -c "
import json,sys
d=json.load(open('${target}'))
r=d.get('insecure-registries',[])
e='${INSECURE_ENTRY}'
if e not in r: r.append(e)
d['insecure-registries']=r
json.dump(d,sys.stdout,indent=2)
" > "${target}.tmp" && mv "${target}.tmp" "${target}"
                    else
                        echo "{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}" > "${target}"
                    fi
                }
                NEED_DOCKER_RESTART=false
                if [ -w "${DAEMON_JSON}" ] || [ "$(id -u)" = "0" ]; then
                    _write_daemon_json "${DAEMON_JSON}"
                    NEED_DOCKER_RESTART=true
                elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
                    TMP_DJ=$(mktemp)
                    [ -f "${DAEMON_JSON}" ] && sudo cp "${DAEMON_JSON}" "${TMP_DJ}" && chmod 644 "${TMP_DJ}"
                    _write_daemon_json "${TMP_DJ}"
                    sudo cp "${TMP_DJ}" "${DAEMON_JSON}"
                    rm -f "${TMP_DJ}"
                    NEED_DOCKER_RESTART=true
                else
                    echo "  Warning: Cannot configure Docker insecure registries (no write access)."
                    echo "  Run: echo '{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}' | sudo tee ${DAEMON_JSON} && sudo systemctl restart docker"
                fi
                if [ "${NEED_DOCKER_RESTART}" = true ]; then
                    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
                        sudo systemctl restart docker 2>/dev/null || true
                    else
                        systemctl restart docker 2>/dev/null || true
                    fi
                    echo "  Configured Docker insecure registry for ${INSECURE_ENTRY}."
                fi
            fi
        fi
    fi

    # Check inotify limits — Kind nodes inherit host limits and operators need many watchers.
    # Skip on non-Linux (e.g. macOS) where /proc/sys/fs/inotify does not exist.
    if [ "$(uname -s)" != "Linux" ]; then
        echo "  Skipping inotify check (non-Linux host)."
    elif [ "${SKIP_INOTIFY_CHECK}" = true ]; then
        echo "Warning: inotify limits check skipped (--skip-inotify-check). Nodes may fail to start if limits are too low."
    else
        INOTIFY_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
        INOTIFY_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
        if [ "${INOTIFY_INSTANCES}" -lt 512 ] || [ "${INOTIFY_WATCHES}" -lt 524288 ]; then
            echo ""
            echo "Error: inotify limits are too low for running multiple operators in Kind."
            echo "  Current:     max_user_instances=${INOTIFY_INSTANCES}, max_user_watches=${INOTIFY_WATCHES}"
            echo "  Recommended: max_user_instances=8192, max_user_watches=524288"
            echo ""
            echo "Fix (requires sudo):"
            echo "  sudo sysctl -w fs.inotify.max_user_instances=8192"
            echo "  sudo sysctl -w fs.inotify.max_user_watches=524288"
            echo ""
            echo "To make persistent, add to /etc/sysctl.d/99-kind.conf:"
            echo "  fs.inotify.max_user_instances=8192"
            echo "  fs.inotify.max_user_watches=524288"
            echo ""
            # Try to fix automatically if running as root
            if [ "$(id -u)" = "0" ]; then
                echo "Running as root — fixing automatically."
                sysctl -w fs.inotify.max_user_instances=8192 >/dev/null
                sysctl -w fs.inotify.max_user_watches=524288 >/dev/null
            else
                echo "To skip this check: $0 --skip-inotify-check"
                exit 1
            fi
        fi
    fi

    # Check if cluster already exists.
    # Try 'kind get clusters' first, but also check kubectl connectivity —
    # the cluster may have been created with sudo (rootful podman) and won't
    # appear in rootless 'kind get clusters'.
    CLUSTER_EXISTS=false
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        CLUSTER_EXISTS=true
    elif ${KUBECTL} cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
        CLUSTER_EXISTS=true
        echo "Note: cluster '${CLUSTER_NAME}' found via kubectl (created outside current user's Kind)."
    fi

    if [ "${CLUSTER_EXISTS}" = false ]; then
        # When using rootless podman, verify cgroup delegation includes cpuset.
        # Without cpuset, kubelet inside Kind worker nodes cannot start.
        if [ "${CONTAINER_TOOL}" = "podman" ] && [ "$(id -u)" != "0" ]; then
            CGROUP_SUBTREE="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
            if [ -f "${CGROUP_SUBTREE}" ]; then
                if ! grep -q 'cpuset' "${CGROUP_SUBTREE}" 2>/dev/null; then
                    echo ""
                    echo "Error: rootless podman detected but 'cpuset' cgroup controller is not delegated."
                    echo "Kind worker nodes will fail to start without it."
                    echo ""
                    echo "Fix: create a systemd override to delegate the required controllers:"
                    echo ""
                    echo "sudo mkdir -p /etc/systemd/system/user@.service.d"
                    echo "sudo tee /etc/systemd/system/user@.service.d/delegate.conf << \"EOF\""
                    echo "[Service]"
                    echo "Delegate=cpu cpuset io memory pids"
                    echo "EOF"
                    echo "sudo systemctl daemon-reload"
                    echo ""
                    echo "IMPORTANT: You must log out and log back in for the changes to take effect."
                    echo "A simple 'systemctl --user restart' is NOT sufficient — the user@.service"
                    echo "unit must be fully restarted, which only happens at login."
                    echo ""
                    echo "Alternatively, create the cluster with sudo:"
                    echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster \\"
                    echo "    --config ${KIND_CONFIG} --name ${CLUSTER_NAME}"
                    echo "  sudo kind get kubeconfig --name ${CLUSTER_NAME} > ~/.kube/config"
                    echo "Then re-run this command — it will detect the existing cluster and configure it."
                    exit 1
                fi
            fi
        fi

        echo "=== Creating Kind cluster '${CLUSTER_NAME}' ==="
        kind create cluster --config "${KIND_CONFIG}" --name "${CLUSTER_NAME}"
    else
        echo "=== Cluster '${CLUSTER_NAME}' already exists — skipping creation, re-applying configuration ==="
    fi

    # Create local registry for OLM bundle deployment (unless skipped).
    # The registry runs as a container on the host and is connected to the Kind
    # network so that Kind nodes can pull images from it.
    if [ "${SKIP_REGISTRY}" != true ]; then
        echo "=== Setting up local registry '${REG_NAME}:${REG_PORT}' ==="
        if ${CONTAINER_TOOL} inspect "${REG_NAME}" &>/dev/null; then
            echo "  Registry container '${REG_NAME}' already exists."
        else
            ${CONTAINER_TOOL} run -d --restart=always \
                -p "127.0.0.1:${REG_PORT}:5000" \
                --network bridge \
                --name "${REG_NAME}" \
                registry:2
            echo "  Registry container '${REG_NAME}' started on port ${REG_PORT}."
        fi

        # Connect registry to the kind network so nodes can reach it by container name.
        ${CONTAINER_TOOL} network connect kind "${REG_NAME}" 2>/dev/null || true

        # Get the registry's IP on the kind network for node /etc/hosts entries.
        # Nodes inherit the host's /etc/hosts (which maps kind-registry to 127.0.0.1),
        # but inside the node 127.0.0.1 is the node itself, not the registry.
        REG_IP=$(${CONTAINER_TOOL} inspect "${REG_NAME}" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "kind"}}{{$conf.IPAddress}}{{end}}{{end}}' 2>/dev/null)
        if [ -z "${REG_IP}" ]; then
            echo "  Warning: could not determine registry IP on kind network, falling back to container name."
            REG_IP="${REG_NAME}"
        fi

        # Configure containerd on each node to use the local registry (insecure/HTTP).
        # Also fix /etc/hosts so kind-registry resolves to the registry container's
        # kind-network IP, not 127.0.0.1 (which is inherited from the host).
        NODES_FOR_REG=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null)
        for node in ${NODES_FOR_REG}; do
            ${CONTAINER_TOOL} exec "$node" mkdir -p "/etc/containerd/certs.d/${REG_NAME}:${REG_PORT}"
            ${CONTAINER_TOOL} exec "$node" bash -c "cat <<EOF >/etc/containerd/certs.d/${REG_NAME}:${REG_PORT}/hosts.toml
[host.\"http://${REG_NAME}:${REG_PORT}\"]
EOF"
            # Fix /etc/hosts: remove any 127.0.0.1 entry for the registry and add the correct IP.
            # Use cp instead of sed -i because /etc/hosts is a mount and can't be renamed.
            ${CONTAINER_TOOL} exec "$node" bash -c "grep -v '127.0.0.1.*${REG_NAME}' /etc/hosts > /tmp/hosts.new && echo '${REG_IP} ${REG_NAME}' >> /tmp/hosts.new && cp /tmp/hosts.new /etc/hosts && rm /tmp/hosts.new"
        done
        echo "  Containerd configured on all nodes to use ${REG_NAME}:${REG_PORT} (IP: ${REG_IP})."
    fi

    echo "=== Waiting for all nodes to be Ready ==="
    ${KUBECTL} wait --for=condition=Ready node --all --timeout=120s

    echo "=== Labeling worker nodes ==="
    # Label any non-CP nodes with the worker role (idempotent)
    LABELED=0
    for node in $(${KUBECTL} get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        if ! ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/control-plane'; then
            if ${KUBECTL} get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'node-role.kubernetes.io/worker'; then
                continue
            fi
            ${KUBECTL} label node "$node" node-role.kubernetes.io/worker="" 2>/dev/null || true
            echo "  labeled $node"
            LABELED=$((LABELED + 1))
        fi
    done
    if [ "${LABELED}" -eq 0 ]; then
        echo "  All worker nodes already labeled."
    fi


fi

echo "=== Ensuring namespace '${DEV_NS}' ==="
if ${KUBECTL} get namespace "${DEV_NS}" &>/dev/null; then
    echo "  Namespace '${DEV_NS}' already exists."
else
    ${KUBECTL} create namespace "${DEV_NS}"
fi
${KUBECTL} label --overwrite ns "${DEV_NS}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged 2>&1 | grep -v 'not labeled' || true

# Also create the medik8s-leases namespace (used by common lease manager)
if ! ${KUBECTL} get namespace medik8s-leases &>/dev/null; then
    ${KUBECTL} create namespace medik8s-leases
else
    echo "  Namespace 'medik8s-leases' already exists."
fi

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
if ! [[ "${CERT_MANAGER_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: CERT_MANAGER_VERSION must be a semver tag (e.g. v1.17.2), got: '${CERT_MANAGER_VERSION}'"
    exit 1
fi
echo "=== Installing cert-manager ${CERT_MANAGER_VERSION} ==="
if ${KUBECTL} get crd certificates.cert-manager.io &>/dev/null; then
    echo "  cert-manager already installed (CRDs found)."
else
    ${KUBECTL} apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    echo "  Waiting for cert-manager to be ready..."
    ${KUBECTL} wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    # --- ADDED: Webhook buffer to prevent OLM deadlock ---
    echo "  Waiting for Cert-Manager webhook to stabilize in the API server..."
    sleep 15
    ${KUBECTL} wait --for=condition=Ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=120s
    # -----------------------------------------------------
fi

if [ "$INSTALL_OLM" = true ]; then
    if command -v operator-sdk &>/dev/null; then
        echo "=== Installing OLM ==="
        # --- ADDED: 5m timeout so it fails gracefully instead of hanging forever ---
        operator-sdk olm install --timeout 5m 2>/dev/null || {
            echo "  OLM may already be installed or operator-sdk olm install failed."
            echo "  Continuing without OLM. Use 'make deploy' instead of 'make bundle-run'."
        }
    else
        echo "=== Skipping OLM (operator-sdk not found) ==="
        echo "  Install operator-sdk for OLM bundle testing, or use 'make deploy' for direct deployment."
    fi
fi

echo ""
echo "=== Medik8s dev environment ready ==="
echo ""
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Namespace: ${DEV_NS}"
echo "  Nodes:     $(${KUBECTL} get nodes --no-headers 2>/dev/null | wc -l) ($(${KUBECTL} get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l) CP + $(${KUBECTL} get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l) workers)"
echo "  Registry:  $(${CONTAINER_TOOL} inspect "${REG_NAME}" >/dev/null 2>&1 && echo "${REG_NAME}:${REG_PORT}" || echo 'not running')"
echo "  OLM:       $(${KUBECTL} get deployment -n olm olm-operator --no-headers >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"
echo ""
echo "  Next steps:"
echo "    cd <operator-directory>"
echo "    make dev-deploy              # Build and deploy operator"
echo "    make dev-simulate-failure    # Trigger node failure"
echo "    make dev-logs                # Watch operator logs"
echo "    make dev-describe            # Check cluster state"
echo ""
