#!/bin/bash
# Sets up CaaS agent infrastructure: InfraEnv + agent VM + label + approve.
# Runs after setup.sh (MCE + AgentServiceConfig must be ready).
# In CI, runs inside the installer container with SSH access to the bare metal host.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

AGENT_NAMESPACE=${AGENT_NAMESPACE:-"hardware-inventory"}
AGENT_RESOURCE_CLASS=${AGENT_RESOURCE_CLASS:-"ci-worker"}
AGENT_VM_NAME=${AGENT_VM_NAME:-"agent-worker-01"}
AGENT_VM_MEMORY=${AGENT_VM_MEMORY:-"16384"}
AGENT_VM_VCPUS=${AGENT_VM_VCPUS:-"4"}
AGENT_VM_DISK_SIZE=${AGENT_VM_DISK_SIZE:-"120G"}
AGENT_VM_STORAGE_DIR=${AGENT_VM_STORAGE_DIR:-"/data/osac-storage"}
LIBVIRT_NETWORK=${LIBVIRT_NETWORK:?"LIBVIRT_NETWORK must be set"}
SSH_CONFIG=${SSH_CONFIG:-"${SHARED_DIR}/ssh_config"}

echo "=== Setting up CaaS agent infrastructure ==="
echo "Agent namespace: ${AGENT_NAMESPACE}"
echo "Resource class: ${AGENT_RESOURCE_CLASS}"
echo ""

# Create agent namespace
oc create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Copy pull secret to agent namespace
oc get secret pull-secret -n openshift-config -o json \
  | python3 -c "import json,sys; s=json.load(sys.stdin); s['metadata']={'name':'pull-secret','namespace':'${AGENT_NAMESPACE}'}; json.dump(s,sys.stdout)" \
  | oc apply -f -

# Create InfraEnv
cat <<EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${AGENT_NAMESPACE}
  namespace: ${AGENT_NAMESPACE}
spec:
  pullSecretRef:
    name: pull-secret
EOF

# Wait for ISO URL
echo "Waiting for discovery ISO URL..."
retry_until 300 5 '[[ -n "$(oc get infraenv ${AGENT_NAMESPACE} -n ${AGENT_NAMESPACE} -o jsonpath="{.status.isoDownloadURL}" 2>/dev/null)" ]]' || {
    echo "Timed out waiting for ISO URL"
    exit 1
}
ISO_URL=$(oc get infraenv "${AGENT_NAMESPACE}" -n "${AGENT_NAMESPACE}" -o jsonpath='{.status.isoDownloadURL}')
echo "ISO URL: ${ISO_URL}"

# Create and boot agent VM on the bare metal host
echo "Creating agent VM on bare metal host..."
timeout -s 9 10m ssh -F "${SSH_CONFIG}" ci_machine bash -s <<SSHEOF
set -euo pipefail

mkdir -p ${AGENT_VM_STORAGE_DIR}

# Download discovery ISO
echo "Downloading discovery ISO..."
curl -k -L --fail -o ${AGENT_VM_STORAGE_DIR}/discovery.iso '${ISO_URL}'

# Remove existing VM if present
virsh destroy ${AGENT_VM_NAME} 2>/dev/null || true
virsh undefine ${AGENT_VM_NAME} 2>/dev/null || true
rm -f ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2

# Create disk and VM
qemu-img create -f qcow2 ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2 ${AGENT_VM_DISK_SIZE}

virt-install \
  --name ${AGENT_VM_NAME} \
  --memory ${AGENT_VM_MEMORY} \
  --vcpus ${AGENT_VM_VCPUS} \
  --disk ${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2 \
  --cdrom ${AGENT_VM_STORAGE_DIR}/discovery.iso \
  --network network=${LIBVIRT_NETWORK} \
  --os-variant rhel9.0 \
  --boot hd,cdrom \
  --noautoconsole

echo "Agent VM created and booting"
SSHEOF

# Wait for agent to register
echo "Waiting for agent to register..."
retry_until 300 15 '[[ $(oc get agent -n ${AGENT_NAMESPACE} --no-headers 2>/dev/null | wc -l) -gt 0 ]]' || {
    echo "Timed out waiting for agent to register"
    exit 1
}

# Label and approve the agent
AGENT_NAME=$(oc get agent -n "${AGENT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "Agent registered: ${AGENT_NAME}"

oc label agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" "osac.openshift.io/resource_class=${AGENT_RESOURCE_CLASS}" --overwrite
oc patch agent/"${AGENT_NAME}" -n "${AGENT_NAMESPACE}" --type=merge -p '{"spec":{"approved":true}}'

echo ""
echo "=== CaaS agent setup complete ==="
echo "Agent: ${AGENT_NAME}"
echo "Resource class: ${AGENT_RESOURCE_CLASS}"
echo "Namespace: ${AGENT_NAMESPACE}"
