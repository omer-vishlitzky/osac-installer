#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

HUB_KUBECONFIG=${HUB_KUBECONFIG:?"HUB_KUBECONFIG must be set"}
REMOTE_KUBECONFIG=${REMOTE_KUBECONFIG:?"REMOTE_KUBECONFIG must be set"}
REMOTE_API_ADDRESS=${REMOTE_API_ADDRESS:?"REMOTE_API_ADDRESS must be set (e.g. https://192.168.128.10:6443)"}
INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')

hub="--kubeconfig ${HUB_KUBECONFIG}"
remote="--kubeconfig ${REMOTE_KUBECONFIG}"

# --- Remote cluster: install prerequisites ---

cat <<EOF | oc ${remote} apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: default
  namespace: openshift-ovn-kubernetes
spec:
  config: '{"cniVersion": "0.4.0", "name": "ovn-kubernetes", "type": "ovn-k8s-cni-overlay"}'
EOF

# LVMS
cat <<EOF | oc ${remote} apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: lvms-operator
  channel: stable-4.19
  installPlanApproval: Automatic
EOF
echo "Waiting for LVMS CRD..."
until oc ${remote} get crd lvmclusters.lvm.topolvm.io 2>/dev/null; do sleep 5; done

cat <<EOF | oc ${remote} apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
EOF
echo "Waiting for LVMS StorageClass..."
until oc ${remote} get sc lvms-vg1 2>/dev/null; do sleep 5; done
oc ${remote} annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

# CNV operator
cat <<EOF | oc ${remote} apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF
echo "Waiting for CNV CRD..."
until oc ${remote} get crd hyperconvergeds.hco.kubevirt.io 2>/dev/null; do sleep 10; done

# HyperConverged instance
cat <<EOF | oc ${remote} apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF
echo "Waiting for CNV to be available..."
until oc ${remote} get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; do
    sleep 15
done
echo "CNV ready"

# --- Remote cluster: prepare for OSAC ---

oc ${remote} create namespace ${INSTALLER_NAMESPACE}
oc ${remote} label sc lvms-vg1 "osac.openshift.io/tenant=${INSTALLER_NAMESPACE}" --overwrite
oc ${remote} create serviceaccount osac-remote-access -n ${INSTALLER_NAMESPACE}
oc ${remote} adm policy add-cluster-role-to-user cluster-admin \
    "system:serviceaccount:${INSTALLER_NAMESPACE}:osac-remote-access"

REMOTE_TOKEN=$(oc ${remote} create token osac-remote-access -n ${INSTALLER_NAMESPACE} --duration=8760h)

REMOTE_KUBECONFIG_FILE=$(mktemp)
cat > "${REMOTE_KUBECONFIG_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: ${REMOTE_API_ADDRESS}
  name: remote
contexts:
- context:
    cluster: remote
    user: osac-remote-access
    namespace: ${INSTALLER_NAMESPACE}
  name: remote
current-context: remote
users:
- name: osac-remote-access
  user:
    token: ${REMOTE_TOKEN}
EOF

# --- Hub cluster: configure operator for remote cluster ---

oc ${hub} create secret generic osac-remote-kubeconfig \
    --from-file=kubeconfig="${REMOTE_KUBECONFIG_FILE}" \
    -n ${INSTALLER_NAMESPACE}

rm -f "${REMOTE_KUBECONFIG_FILE}"

oc ${hub} patch deployment osac-operator-controller-manager -n ${INSTALLER_NAMESPACE} --type=strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [{"name": "remote-kubeconfig", "secret": {"secretName": "osac-remote-kubeconfig"}}],
    "containers": [{"name": "manager",
      "volumeMounts": [{"name": "remote-kubeconfig", "mountPath": "/var/run/secrets/remote", "readOnly": true}],
      "env": [{"name": "OSAC_REMOTE_CLUSTER_KUBECONFIG", "value": "/var/run/secrets/remote/kubeconfig"}]
    }]
  }}}
}'

oc ${hub} patch secret config-as-code-ig -n ${INSTALLER_NAMESPACE} --type=strategic -p "{
  \"stringData\": {
    \"REMOTE_CLUSTER_KUBECONFIG_SECRET_NAME\": \"osac-remote-kubeconfig\",
    \"REMOTE_CLUSTER_KUBECONFIG_SECRET_KEY\": \"kubeconfig\"
  }
}"

# Re-run AAP config-as-code to pick up the remote cluster kubeconfig
AAP_PASSWORD=$(oc ${hub} get secret osac-aap-admin-password -n ${INSTALLER_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d)
AAP_TOKEN=$(oc ${hub} exec deployment/fulfillment-grpc-server -n ${INSTALLER_NAMESPACE} -- \
    sh -c "curl -sk -X POST http://osac-aap:80/api/controller/v2/tokens/ \
    -u admin:${AAP_PASSWORD} -H 'Content-Type: application/json' -d '{}'" | jq -r '.token')

JOB_ID=$(oc ${hub} exec deployment/fulfillment-grpc-server -n ${INSTALLER_NAMESPACE} -- \
    sh -c "curl -sk -X POST http://osac-aap:80/api/controller/v2/job_templates/osac-config-as-code/launch/ \
    -H 'Authorization: Bearer ${AAP_TOKEN}' -H 'Content-Type: application/json' -d '{}'" | jq -r '.id')

echo "Waiting for config-as-code job ${JOB_ID}..."
until STATUS=$(oc ${hub} exec deployment/fulfillment-grpc-server -n ${INSTALLER_NAMESPACE} -- \
    sh -c "curl -sk http://osac-aap:80/api/controller/v2/jobs/${JOB_ID}/ \
    -H 'Authorization: Bearer ${AAP_TOKEN}'" 2>/dev/null | jq -r '.status') && \
    [[ "${STATUS}" == "successful" || "${STATUS}" == "failed" ]]; do
    sleep 10
done

if [[ "${STATUS}" != "successful" ]]; then
    echo "AAP config-as-code job failed"
    exit 1
fi

echo "Remote cluster setup complete"
