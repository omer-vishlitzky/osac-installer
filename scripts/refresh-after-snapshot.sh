#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEYCLOAK_NS="keycloak"
REALM_JSON="prerequisites/keycloak/service/files/realm.json"

echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

# -----------------------------------------------------------------------------
# PHASE 1: The Great Scale Down
# -----------------------------------------------------------------------------
echo "[Phase 1] Scaling down operators and operands to prevent rollout races..."

# 1A. Scale down AAP Operator via OLM CSV
echo "  Waiting for AAP CSV to be ready..."
retry_until 120 5 '[[ -n "$(oc get csv -n ansible-aap -o json 2>/dev/null | jq -r '\''.items[] | select(.status.phase == "Succeeded") | select(.spec.install.spec.deployments[]? | .name == "automation-controller-operator-controller-manager") | .metadata.name'\'' | head -n 1)" ]]' || {
    echo "WARNING: AAP CSV not found or not Succeeded"
}

AAP_CSV=$(oc get csv -n ansible-aap -o json 2>/dev/null | jq -r '.items[] | select(.status.phase == "Succeeded") | select(.spec.install.spec.deployments[]? | .name == "automation-controller-operator-controller-manager") | .metadata.name' | head -n 1 || true)
if [[ -n "${AAP_CSV}" && "${AAP_CSV}" != "null" ]]; then
    AAP_DEPLOY_INDEX=$(oc get csv "$AAP_CSV" -n ansible-aap -o json | jq '.spec.install.spec.deployments | to_entries[] | select(.value.name == "automation-controller-operator-controller-manager") | .key')
    oc patch csv "$AAP_CSV" -n ansible-aap --type=json -p '[{"op":"replace","path":"/spec/install/spec/deployments/'"$AAP_DEPLOY_INDEX"'/spec/replicas","value":0}]'
else
    echo "WARNING: Could not scale down AAP operator via CSV"
fi

# 1B. Scale down AAP operands explicitly
if oc get deploy -n "${INSTALLER_NAMESPACE}" -l app.kubernetes.io/managed-by=automationcontroller-operator >/dev/null 2>&1; then
    oc scale deploy -n "${INSTALLER_NAMESPACE}" -l app.kubernetes.io/managed-by=automationcontroller-operator --replicas=0
fi

# Wait for AAP operator to actually scale down
oc wait deploy/automation-controller-operator-controller-manager -n ansible-aap --for=jsonpath='{.spec.replicas}'=0 --timeout=60s || true

# -----------------------------------------------------------------------------
# PHASE 2: Reconfiguration (Parallel)
# -----------------------------------------------------------------------------
echo "[Phase 2] Reconfiguring cluster (Domain, Certs, Keycloak, Subnets)..."

patch_stale_routes() {
    echo "  Patching stale routes with new domain..."
    for ns in "${INSTALLER_NAMESPACE}" "${KEYCLOAK_NS}" "multicluster-engine"; do
        if ! oc get namespace "${ns}" >/dev/null 2>&1; then continue; fi
        for route in $(oc get routes -n "${ns}" -o jsonpath='{.items[*].metadata.name}'); do
            OLD_HOST=$(oc get route "${route}" -n "${ns}" -o jsonpath='{.spec.host}')
            ROUTE_DOMAIN=$(echo "${OLD_HOST}" | sed "s/^[^.]*\.//")
            if [[ "${ROUTE_DOMAIN}" != "${CLUSTER_DOMAIN}" ]]; then
                ROUTE_NAME=$(echo "${OLD_HOST}" | sed "s/\.${ROUTE_DOMAIN}$//")
                NEW_HOST="${ROUTE_NAME}.${CLUSTER_DOMAIN}"
                echo "  ${ns}/${route}: ${OLD_HOST} -> ${NEW_HOST}"
                retry_command 300 10 oc patch route "${route}" -n "${ns}" --type=merge -p "{\"spec\":{\"host\":\"${NEW_HOST}\"}}"
            fi
        done
    done
}

refresh_cdi_certificates() {
    if ! oc get namespace openshift-cnv >/dev/null 2>&1; then return 0; fi
    echo "  Refreshing CDI certificates..."
    for secret in cdi-apiserver-signer cdi-uploadproxy-signer \
                  cdi-uploadserver-client-signer cdi-uploadserver-signer \
                  cdi-apiserver-server-cert cdi-uploadproxy-server-cert \
                  cdi-uploadserver-client-cert; do
        if oc get secret "${secret}" -n openshift-cnv >/dev/null 2>&1; then
            oc delete secret "${secret}" -n openshift-cnv
        fi
    done
    if oc get pod -n openshift-cnv -l app=cdi-operator >/dev/null 2>&1; then
        oc delete pod -n openshift-cnv -l app=cdi-operator
    fi
    retry_command 300 10 oc rollout status deploy/cdi-operator -n openshift-cnv --timeout=120s
    for deploy in cdi-deployment cdi-apiserver cdi-uploadproxy; do
        if oc get deploy "${deploy}" -n openshift-cnv >/dev/null 2>&1; then
            oc rollout restart "deploy/${deploy}" -n openshift-cnv
        fi
    done
    retry_command 300 10 oc rollout status deploy/cdi-deployment -n openshift-cnv --timeout=120s &
    local pid_cdi_deploy=$!
    retry_command 300 10 oc rollout status deploy/cdi-apiserver -n openshift-cnv --timeout=120s &
    local pid_cdi_api=$!
    wait ${pid_cdi_deploy}
    wait ${pid_cdi_api}
    echo "  CDI certificates refreshed"
}

refresh_metallb_certificates() {
    if ! oc get crd ipaddresspools.metallb.io >/dev/null 2>&1; then return 0; fi
    echo "  Refreshing MetalLB webhook certificates..."
    if oc get secret metallb-operator-webhook-server-cert -n metallb-system >/dev/null 2>&1; then
        oc delete secret metallb-operator-webhook-server-cert -n metallb-system
    fi
    if oc get pod -n metallb-system -l control-plane=controller-manager >/dev/null 2>&1; then
        oc delete pod -n metallb-system -l control-plane=controller-manager
    fi
    if oc get pod -n metallb-system -l component=webhook-server >/dev/null 2>&1; then
        oc delete pod -n metallb-system -l component=webhook-server
    fi
    
    retry_until 120 5 '[[ -n "$(oc get endpoints metallb-operator-webhook-server-service -n metallb-system -o jsonpath='"'"'{.subsets[*].addresses[*].ip}'"'"')" ]]' || {
        echo "ERROR: MetalLB webhook service failed to get endpoints"
        exit 1
    }
    echo "  MetalLB webhook certificates refreshed"
}

keycloak_sync() {
    echo "  Syncing Keycloak realm..."
    oc wait --for=condition=Ready certificate/keycloak-tls -n "${KEYCLOAK_NS}" --timeout=300s

    NEW_HASH=$(md5sum "${REALM_JSON}" | awk '{print $1}')
    OLD_HASH="missing"
    if oc get configmap keycloak-realm -n "${KEYCLOAK_NS}" >/dev/null 2>&1; then
        OLD_HASH=$(oc get configmap keycloak-realm -n "${KEYCLOAK_NS}" -o jsonpath='{.data.realm\.json}' | md5sum | awk '{print $1}')
    fi
    
    if [[ "${NEW_HASH}" != "${OLD_HASH}" ]]; then
        echo "  ConfigMap changed, restarting Keycloak..."
        oc create configmap keycloak-realm \
            --from-file=realm.json="${REALM_JSON}" \
            -n "${KEYCLOAK_NS}" --dry-run=client -o yaml | oc apply -f -
        oc rollout restart deploy/keycloak-service -n "${KEYCLOAK_NS}"
        oc rollout status deploy/keycloak-service -n "${KEYCLOAK_NS}" --timeout=300s
    fi

    KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
    retry_until 300 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} '"${KC_URL}"'/realms/osac)" == "200" ]]' || {
        echo "ERROR: Timed out waiting for Keycloak"
        exit 1
    }
    KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
    [[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token"; exit 1; }

    echo "  Syncing clients and users via admin API..."
    jq -c '.clients[] | select(.protocol == "openid-connect" and .publicClient != true and .bearerOnly != true)' "${REALM_JSON}" | while IFS= read -r CLIENT_JSON; do
        CID=$(echo "${CLIENT_JSON}" | jq -r '.clientId')
        CLIENT_UUID=$(echo "${CLIENT_JSON}" | jq -r '.id')
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}" -d "${CLIENT_JSON}" >/dev/null
            echo "  Updated client: ${CID}"
        else
            curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/clients" -d "${CLIENT_JSON}" >/dev/null
            echo "  Created client: ${CID}"
        fi
    done

    jq -c '.users[]?' "${REALM_JSON}" | while IFS= read -r USER_JSON; do
        USERNAME=$(echo "${USER_JSON}" | jq -r '.username')
        USER_UUID=$(echo "${USER_JSON}" | jq -r '.id')
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/users/${USER_UUID}")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/users/${USER_UUID}" -d "${USER_JSON}" >/dev/null
            echo "  Updated user: ${USERNAME}"
        else
            curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/users" -d "${USER_JSON}" >/dev/null
            echo "  Created user: ${USERNAME}"
        fi
    done

    if [[ -f prerequisites/keycloak/service/password-setup-job.yaml ]]; then
        if oc get job keycloak-set-passwords -n "${KEYCLOAK_NS}" >/dev/null 2>&1; then
            oc delete job keycloak-set-passwords -n "${KEYCLOAK_NS}"
        fi
        oc apply -f prerequisites/keycloak/service/password-setup-job.yaml -n "${KEYCLOAK_NS}"
        oc wait --for=condition=Complete job/keycloak-set-passwords -n "${KEYCLOAK_NS}" --timeout=300s
    fi
    echo "  Keycloak sync complete"
}

create_fulfillment_credentials() {
    echo "  Recreating fulfillment controller credentials..."
    FC_CLIENT_ID=$(jq -er '.clients[] | select(.serviceAccountsEnabled == true) | .clientId' "${REALM_JSON}")
    FC_CLIENT_SECRET=$(jq -er ".clients[] | select(.clientId == \"${FC_CLIENT_ID}\") | .secret // empty" "${REALM_JSON}")
    [[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for ${FC_CLIENT_ID} in realm.json"; exit 1; }
    if oc get secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}" >/dev/null 2>&1; then
        oc delete secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}"
    fi
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id="${FC_CLIENT_ID}" \
        --from-literal=client-secret="${FC_CLIENT_SECRET}" \
        -n "${INSTALLER_NAMESPACE}"
    echo "  Credentials created for client: ${FC_CLIENT_ID}"
}

metallb_reconfigure() {
    if ! oc get crd ipaddresspools.metallb.io >/dev/null 2>&1; then return 0; fi
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    SUBNET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
    echo "  Node IP: ${NODE_IP}, configuring pool: ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250"
    METALLB_YAML=$(mktemp)
    cat > "${METALLB_YAML}" <<METALLBEOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: caas-address-pool
  namespace: metallb-system
spec:
  addresses:
    - ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250
  autoAssign: true
METALLBEOF
    retry_command 120 10 oc apply -f "${METALLB_YAML}"
}

# Wait for basic pre-reqs to stabilize first
oc rollout status deploy/trust-manager -n cert-manager --timeout=300s &
pid_tm=$!

patch_stale_routes

refresh_cdi_certificates &
pid_cdi=$!

refresh_metallb_certificates &
pid_mlb=$!

keycloak_sync &
pid_kc=$!

create_fulfillment_credentials &
pid_creds=$!

# Wait for basic pre-reqs before kustomize apply
wait ${pid_creds} || { echo "ERROR: Create credentials failed"; exit 1; }
wait ${pid_mlb} || { echo "ERROR: MetalLB certs failed"; exit 1; }

metallb_reconfigure

echo "  Applying kustomize overlay..."
if oc get job -n "${INSTALLER_NAMESPACE}" >/dev/null 2>&1; then
    oc delete job -n "${INSTALLER_NAMESPACE}" --all
fi
sed '/job\.yaml/d' base/osac-aap/config/base/kustomization.yaml > base/osac-aap/config/base/kustomization.yaml.tmp \
    && mv base/osac-aap/config/base/kustomization.yaml.tmp base/osac-aap/config/base/kustomization.yaml

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PULL_SECRET="${REPO_ROOT}/overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json"
[[ -f "${PULL_SECRET}" ]] || { echo "ERROR: Pull secret not found: ${PULL_SECRET}" >&2; exit 1; }
img_check_pids=()
img_check_imgs=()
img_check_logs=()
while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    img_check_imgs+=("${img}")
    log_file="$(mktemp)"
    img_check_logs+=("${log_file}")
    oc image info "${img}" -a "${PULL_SECRET}" >"${log_file}" 2>&1 &
    img_check_pids+=($!)
done < <(oc get deploy,statefulset -n "${INSTALLER_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    | sort -u | grep 'ghcr\.io/osac-project' || true)

# Edit replicas to 0 in kustomize so apply doesn't wake them up immediately
( cd "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}" && kustomize edit set replicas fulfillment-controller=0 fulfillment-grpc-server=0 fulfillment-ingress-proxy=0 )
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"

echo "  Waiting for TLS certificates..."
pids=()
read -ra fs_certs <<< "$(oc get certificates.cert-manager.io -n "${INSTALLER_NAMESPACE}" -l app=fulfillment-service -o jsonpath='{.items[*].metadata.name}' || true)"
for cert in "${fs_certs[@]}"; do
    if [[ -z "${cert}" ]]; then continue; fi
    oc wait --for=condition=Ready "certificate.cert-manager.io/${cert}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "${pid}" || { echo "ERROR: TLS cert failed"; exit 1; }; done

for i in "${!img_check_pids[@]}"; do
    if ! wait "${img_check_pids[$i]}"; then
        echo "ERROR: Image preflight failed for: ${img_check_imgs[$i]}"
        tail -5 "${img_check_logs[$i]}" || true
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# PHASE 3: The Great Scale Up
# -----------------------------------------------------------------------------
echo "[Phase 3] Scaling up and final configuration..."

# 3A. Fulfillment DB and Pods
oc rollout status statefulset/fulfillment-database -n "${INSTALLER_NAMESPACE}" --timeout=300s

oc scale deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --replicas=1
oc scale deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}" --replicas=1
oc scale deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}" --replicas=1

read -ra FULFILLMENT_DEPLOYS <<< "$(oc get deploy -n "${INSTALLER_NAMESPACE}" -l app=fulfillment-service -o jsonpath='{.items[*].metadata.name}')"
if [[ ${#FULFILLMENT_DEPLOYS[@]} -eq 0 || -z "${FULFILLMENT_DEPLOYS[0]}" ]]; then
    echo "ERROR: No deployments found with label app=fulfillment-service in namespace ${INSTALLER_NAMESPACE}"
    exit 1
fi

pids=()
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
    if [[ -z "${deploy}" ]]; then continue; fi
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "${pid}" || { echo "ERROR: Fulfillment rollout failed"; exit 1; }; done

# 3B. AAP Configuration & Operator Scale Up
echo "  Applying AAP configuration..."
hcbd=""
if oc get configmap cluster-fulfillment-ig -n "${INSTALLER_NAMESPACE}" >/dev/null 2>&1; then
    hcbd="${HOSTED_CLUSTER_BASE_DOMAIN:-${CLUSTER_DOMAIN}}"
fi
HOSTED_CLUSTER_BASE_DOMAIN="${hcbd}" \
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

echo "  Scaling AAP operator back up..."
NEW_AAP_CSV=$(oc get csv -n ansible-aap -o json | jq -r '.items[] | select(.status.phase == "Succeeded") | select(.spec.install.spec.deployments[]? | .name == "automation-controller-operator-controller-manager") | .metadata.name')
if [[ -n "${NEW_AAP_CSV}" && "${NEW_AAP_CSV}" != "null" ]]; then
    NEW_AAP_DEPLOY_INDEX=$(oc get csv "${NEW_AAP_CSV}" -n ansible-aap -o json | jq '.spec.install.spec.deployments | to_entries[] | select(.value.name == "automation-controller-operator-controller-manager") | .key')
    oc patch csv "${NEW_AAP_CSV}" -n ansible-aap --type=json -p '[{"op":"replace","path":"/spec/install/spec/deployments/'"${NEW_AAP_DEPLOY_INDEX}"'/spec/replicas","value":1}]'
else
    echo "WARNING: AAP CSV not found, scaling deployment directly..."
    oc scale deploy/automation-controller-operator-controller-manager -n ansible-aap --replicas=1
fi
oc wait deploy/automation-controller-operator-controller-manager -n ansible-aap --for=jsonpath='{.spec.replicas}'=1 --timeout=60s

echo "  Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"')" == "True" ]]' || {
    echo "ERROR: Timed out waiting for AAP controller to be Running"
    exit 1
}

# Ensure Keycloak and CDI are finished from Phase 2
wait ${pid_tm} || { echo "ERROR: Trust-manager failed"; exit 1; }
wait ${pid_kc} || { echo "ERROR: Keycloak sync failed"; exit 1; }
wait ${pid_cdi} || { echo "ERROR: CDI certs failed"; exit 1; }

AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "ERROR: Timed out waiting for AAP gateway API to respond"
    exit 1
}

# Delete stale assisted-service auth keypair before restarting it
if oc get secret assisted-servicelocal-auth -n multicluster-engine >/dev/null 2>&1; then
    echo "  Deleting stale assisted-service auth keypair..."
    oc delete secret assisted-servicelocal-auth -n multicluster-engine
fi

if oc get deploy assisted-service -n multicluster-engine >/dev/null 2>&1; then
    oc rollout restart deploy/assisted-service -n multicluster-engine
    oc rollout restart statefulset/assisted-image-service -n multicluster-engine
fi

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[Phase 4] Post-flight configurations..."
./scripts/prepare-aap.sh
./scripts/prepare-fulfillment-service.sh

# prepare-fulfillment-service patches fulfillment deployments. Wait for rollouts again.
pids=()
for deploy in "${FULFILLMENT_DEPLOYS[@]}"; do
    if [[ -z "${deploy}" ]]; then continue; fi
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "${pid}" || { echo "ERROR: Fulfillment rollout failed after prepare"; exit 1; }; done

./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"