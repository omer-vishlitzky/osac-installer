#!/usr/bin/env bash
#
# Refresh a Helm-deployed OSAC cluster after booting from a cold snapshot.
# All pods are at zero replicas. This script:
#   1. Fixes cluster identity (routes, certs, MetalLB)
#   2. Prepares the environment (Keycloak, secrets, CA bundle)
#   3. Scales up operators and starts pods via helm upgrade
#   4. Runs post-flight configuration (AAP token, hub, tenants)
#
# Fail fast: any error aborts immediately.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

VALUES_FILE=${VALUES_FILE:?"VALUES_FILE must be set (e.g. values/vmaas-ci/values.yaml)"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-"osac-e2e-ci"}
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEYCLOAK_NS="keycloak"
REALM_JSON="prerequisites/keycloak/service/files/realm.json"
VALUES_DIR="$(dirname "${VALUES_FILE}")"

echo "=== Refreshing OSAC after snapshot boot (Helm) ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Values: ${VALUES_FILE}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

# ─── Phase 1: Fix cluster identity (everything at zero, all parallel) ────────
echo "[Phase 1] Fixing cluster identity..."

patch_stale_routes() {
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
    retry_command 300 10 oc rollout status deploy/cdi-deployment -n openshift-cnv --timeout=120s
    echo "  CDI certificates refreshed"
}

refresh_metallb_and_subnet() {
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
    echo "  MetalLB webhook ready, reconfiguring subnet..."
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    SUBNET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
    echo "  Node IP: ${NODE_IP}, pool: ${SUBNET_PREFIX}.240-${SUBNET_PREFIX}.250"
    retry_command 120 10 oc apply -f - <<METALLBEOF
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
    echo "  MetalLB configured"
}

wait_keycloak_cert() {
    echo "  Waiting for Keycloak TLS certificate..."
    oc wait --for=condition=Ready certificate/keycloak-tls -n "${KEYCLOAK_NS}" --timeout=300s
    echo "  Keycloak TLS ready"
}

# Run all phase 1 tasks in parallel
patch_stale_routes &
pid_routes=$!
refresh_cdi_certificates &
pid_cdi=$!
refresh_metallb_and_subnet &
pid_metallb=$!
wait_keycloak_cert &
pid_kc_cert=$!

wait ${pid_routes} || { echo "ERROR: Route patching failed"; exit 1; }
wait ${pid_cdi} || { echo "ERROR: CDI cert refresh failed"; exit 1; }
wait ${pid_metallb} || { echo "ERROR: MetalLB refresh failed"; exit 1; }
wait ${pid_kc_cert} || { echo "ERROR: Keycloak cert wait failed"; exit 1; }
echo "[Phase 1] Done"
echo ""

# ─── Phase 2: Prepare environment (everything still at zero, parallel) ───────
echo "[Phase 2] Preparing environment..."

keycloak_sync() {
    echo "  Syncing Keycloak realm..."
    KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
    retry_until 300 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} '"${KC_URL}"'/realms/osac)" == "200" ]]' || {
        echo "ERROR: Timed out waiting for Keycloak"
        exit 1
    }
    KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
    [[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token"; exit 1; }

    jq -c '.clients[] | select(.protocol == "openid-connect" and .publicClient != true and .bearerOnly != true)' "${REALM_JSON}" | while IFS= read -r CLIENT_JSON; do
        CID=$(echo "${CLIENT_JSON}" | jq -r '.clientId')
        CLIENT_UUID=$(echo "${CLIENT_JSON}" | jq -r '.id')
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}" -d "${CLIENT_JSON}" >/dev/null
        else
            curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/clients" -d "${CLIENT_JSON}" >/dev/null
        fi
    done

    jq -c '.users[]?' "${REALM_JSON}" | while IFS= read -r USER_JSON; do
        USERNAME=$(echo "${USER_JSON}" | jq -r '.username')
        USER_UUID=$(echo "${USER_JSON}" | jq -r '.id')
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/users/${USER_UUID}")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/users/${USER_UUID}" -d "${USER_JSON}" >/dev/null
        else
            curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/osac/users" -d "${USER_JSON}" >/dev/null
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

create_secrets() {
    echo "  Creating fulfillment-controller-credentials..."
    FC_CLIENT_ID=$(jq -er '.clients[] | select(.serviceAccountsEnabled == true) | .clientId' "${REALM_JSON}")
    FC_CLIENT_SECRET=$(jq -er ".clients[] | select(.clientId == \"${FC_CLIENT_ID}\") | .secret // empty" "${REALM_JSON}")
    [[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for ${FC_CLIENT_ID} in realm.json"; exit 1; }
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id="${FC_CLIENT_ID}" \
        --from-literal=client-secret="${FC_CLIENT_SECRET}" \
        -n "${INSTALLER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    echo "  Creating config-as-code secrets..."
    AAP_COMMIT=$(git submodule status base/osac-aap | awk '{print $1}' | tr -d ' +-')
    AAP_SHORT="${AAP_COMMIT:0:7}"
    oc create secret generic config-as-code-ig \
        --from-literal=AAP_EE_IMAGE="ghcr.io/osac-project/osac-aap:sha-${AAP_SHORT}" \
        --from-literal=AAP_PROJECT_GIT_URI="https://github.com/osac-project/osac-aap" \
        --from-literal=AAP_PROJECT_GIT_BRANCH="${AAP_COMMIT}" \
        -n "${INSTALLER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    AAP_LICENSE="${VALUES_DIR}/license.zip"
    [[ -f "${AAP_LICENSE}" ]] || { echo "ERROR: AAP license not found: ${AAP_LICENSE}"; exit 1; }
    oc create secret generic config-as-code-manifest-ig \
        --from-file=license.zip="${AAP_LICENSE}" \
        -n "${INSTALLER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    echo "  Secrets created"
}

ensure_ca_bundle() {
    "${SCRIPT_DIR}/ensure-ca-bundle.sh" "${INSTALLER_NAMESPACE}"
}

wait_tls_certs() {
    echo "  Waiting for TLS certificates..."
    pids=()
    for cert in $(oc get certificates.cert-manager.io -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
        oc wait --for=condition=Ready "certificate.cert-manager.io/${cert}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "${pid}" || { echo "ERROR: TLS certificate not ready"; exit 1; }
    done
    echo "  All TLS certificates ready"
}

keycloak_sync &
pid_kc=$!
create_secrets &
pid_secrets=$!
ensure_ca_bundle &
pid_ca=$!
wait_tls_certs &
pid_tls=$!

wait ${pid_kc} || { echo "ERROR: Keycloak sync failed"; exit 1; }
wait ${pid_secrets} || { echo "ERROR: Secret creation failed"; exit 1; }
wait ${pid_ca} || { echo "ERROR: CA bundle failed"; exit 1; }
wait ${pid_tls} || { echo "ERROR: TLS certificates failed"; exit 1; }
echo "[Phase 2] Done"
echo ""

# ─── Phase 3: Scale up operators and start pods (sequential) ─────────────────
echo "[Phase 3] Starting pods..."

# 3a. Scale Authorino operator back to 1 (it manages the Authorino deployment
#     via the Authorino CR — Helm only creates the CR, not the deployment).
echo "  Scaling Authorino operator to 1..."
AUTHORINO_CSV=$(oc get csv -n openshift-operators -o json \
    | jq -r '.items[] | select(.spec.install.spec.deployments[]?.name == "authorino-operator") | .metadata.name')
[[ -n "${AUTHORINO_CSV}" ]] || { echo "ERROR: Authorino CSV not found"; exit 1; }
AUTHORINO_DEPLOY_COUNT=$(oc get csv "${AUTHORINO_CSV}" -n openshift-operators -o json \
    | jq '.spec.install.spec.deployments | length')
AUTHORINO_PATCH=$(jq -n --argjson n "${AUTHORINO_DEPLOY_COUNT}" \
    '[range($n)] | map({"op":"replace","path":"/spec/install/spec/deployments/\(.)/spec/replicas","value":1})')
oc patch csv "${AUTHORINO_CSV}" -n openshift-operators --type=json -p "${AUTHORINO_PATCH}"
oc rollout status deploy/authorino-operator -n openshift-operators --timeout=120s

# 3b. Wait for Authorino deployment (operator reconciles it from the CR)
echo "  Waiting for Authorino..."
retry_until 120 5 '[[ "$(oc get deploy authorino -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.spec.replicas}'"'"' 2>/dev/null)" -gt 0 ]]'
oc rollout status deploy/authorino -n "${INSTALLER_NAMESPACE}" --timeout=120s
echo "  Authorino running"

# 3c. Recreate fulfillment database (bare pod, lost during scale-to-zero)
echo "  Upgrading fulfillment-db..."
helm upgrade --install fulfillment-db \
    base/osac-fulfillment-service/it/charts/postgres/ \
    --namespace "${INSTALLER_NAMESPACE}" \
    --set certs.issuerRef.name=default-ca \
    --set certs.caBundle.configMap=ca-bundle \
    --set 'databases[0].name=service' \
    --set 'databases[0].user=service' \
    --timeout 5m \
    --wait

# 3d. Helm upgrade (starts all Helm-managed pods — fulfillment-*, osac-operator).
#     No --wait: pods start in the background. We wait ourselves, in parallel
#     with AAP startup.
echo "  Upgrading osac chart..."
helm upgrade osac charts/osac/ \
    --namespace "${INSTALLER_NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --set aap.bootstrap.enabled=false \
    --timeout 15m

# 3e. Two parallel branches: fulfillment pods + AAP startup.
#     Both must complete before post-flight.

wait_fulfillment() {
    echo "  Waiting for fulfillment deployments..."
    local deploy
    for deploy in $(oc get deploy -n "${INSTALLER_NAMESPACE}" -l app=fulfillment-service -o jsonpath='{.items[*].metadata.name}'); do
        oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s
    done
    oc rollout status deploy/osac-operator -n "${INSTALLER_NAMESPACE}" --timeout=300s
    echo "  Fulfillment + operator running"
}

start_aap() {
    echo "  Scaling AAP operators to 1..."
    AAP_CSV=$(oc get csv -n ansible-aap -o json \
        | jq -r '.items[] | select(.spec.install.spec.deployments[]?.name == "automation-controller-operator-controller-manager") | .metadata.name')
    [[ -n "${AAP_CSV}" ]] || { echo "ERROR: AAP CSV not found"; exit 1; }
    AAP_DEPLOY_COUNT=$(oc get csv "${AAP_CSV}" -n ansible-aap -o json \
        | jq '.spec.install.spec.deployments | length')
    AAP_PATCH=$(jq -n --argjson n "${AAP_DEPLOY_COUNT}" \
        '[range($n)] | map({"op":"replace","path":"/spec/install/spec/deployments/\(.)/spec/replicas","value":1})')
    oc patch csv "${AAP_CSV}" -n ansible-aap --type=json -p "${AAP_PATCH}"

    echo "  Waiting for AAP controller..."
    retry_until 600 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
        echo "ERROR: AAP controller not Running after 600s"
        exit 1
    }
    AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
    retry_until 300 10 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
        echo "ERROR: AAP gateway not responding after 300s"
        exit 1
    }
    echo "  AAP running"
}

wait_fulfillment &
pid_fulfill=$!
start_aap &
pid_aap=$!

wait ${pid_fulfill} || { echo "ERROR: Fulfillment startup failed"; exit 1; }
wait ${pid_aap} || { echo "ERROR: AAP startup failed"; exit 1; }

# Delete stale assisted-service auth keypair (not rotated by recert)
if oc get secret assisted-servicelocal-auth -n multicluster-engine >/dev/null 2>&1; then
    echo "  Deleting stale assisted-service auth keypair..."
    oc delete secret assisted-servicelocal-auth -n multicluster-engine
fi
if oc get deploy assisted-service -n multicluster-engine >/dev/null 2>&1; then
    oc rollout restart deploy/assisted-service -n multicluster-engine
    oc rollout restart statefulset/assisted-image-service -n multicluster-engine
fi

echo "[Phase 3] Done"
echo ""

# ─── Phase 4: Post-flight configuration (sequential) ─────────────────────────
echo "[Phase 4] Post-flight configuration..."

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

# 4a. Create AAP API token
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-aap.sh

# 4b. Register hub, sync AAP project, patch token config.
#     Do NOT pass INSTALLER_VM_TEMPLATE / INSTALLER_CLUSTER_TEMPLATE — templates
#     are already published in the snapshot. Re-publishing adds ~2 min for no benefit.
#     TODO: osac-aap PRs that change template definitions won't be picked up
#     until publish-templates runs. Need a PR to handle this — either detect
#     template changes and re-publish, or always publish (costs ~2 min).
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-fulfillment-service.sh

# 4c. Wait for fulfillment rollouts after prepare patches
pids=()
for deploy in $(oc get deploy -n "${INSTALLER_NAMESPACE}" -l app=fulfillment-service -o jsonpath='{.items[*].metadata.name}'); do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "${pid}" || { echo "ERROR: Fulfillment rollout failed after prepare"; exit 1; }
done

# 4d. Create tenants
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" ./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
