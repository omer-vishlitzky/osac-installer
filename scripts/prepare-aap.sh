#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
if [[ -z "${INSTALLER_NAMESPACE:-}" ]]; then
    INSTALLER_NAMESPACE=$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')
    [[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: INSTALLER_NAMESPACE not set and could not determine from overlay" && exit 1
fi

# Get the AAP gateway route URL
AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
AAP_URL="https://${AAP_ROUTE_HOST}"

# Get the AAP admin password
AAP_ADMIN_PASSWORD=$(oc get secret osac-aap-admin-password -n ${INSTALLER_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d)

AAP_TOKEN=$(http_json "Failed to create AAP API token (gateway may be rolling out)" 30 10 \
    '.token // empty' \
    -X POST -u "admin:${AAP_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"description": "osac-operator", "scope": "write"}' \
    "${AAP_URL}/api/gateway/v1/tokens/")

if [[ -z "${AAP_TOKEN}" || "${AAP_TOKEN}" == "null" ]]; then
    echo "ERROR: AAP API token was empty"
    exit 1
fi

# Store the token in a Kubernetes secret
oc create secret generic osac-aap-api-token \
    --from-literal=token="${AAP_TOKEN}" \
    -n ${INSTALLER_NAMESPACE} \
    --dry-run=client -o yaml | oc apply -f -

# Set the AAP URL and token on the operator deployment (triggers rollout).
# Helm names it "osac-operator", kustomize names it "osac-operator-controller-manager".
OPERATOR_DEPLOY=$(oc get deploy -n "${INSTALLER_NAMESPACE}" -o name | grep osac-operator)
[[ -z "${OPERATOR_DEPLOY}" ]] && { echo "ERROR: osac-operator deployment not found in ${INSTALLER_NAMESPACE}"; exit 1; }
oc set env "${OPERATOR_DEPLOY}" \
    -n ${INSTALLER_NAMESPACE} \
    OSAC_AAP_URL="${AAP_URL}/api/controller" \
    OSAC_AAP_TOKEN="${AAP_TOKEN}"

echo "AAP API token created and stored in secret osac-aap-api-token"
