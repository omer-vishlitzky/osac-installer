#!/usr/bin/env python3
"""Refresh a Helm-deployed OSAC cluster after booting from a cold snapshot.

All pods are at zero replicas. This script:
  1. Fixes cluster identity (routes, certs, MetalLB)
  2. Prepares the environment (Keycloak, secrets, CA bundle)
  3. Scales up operators and starts pods via helm upgrade
  4. Runs post-flight configuration (AAP token, hub, tenants)

Fail fast: any error aborts immediately with full output.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


# ─── Config ──────────────────────────────────────────────────────────────────


@dataclass
class RefreshConfig:
    values_file: str
    namespace: str
    cluster_domain: str
    vm_template: str = ""
    cluster_template: str = ""
    keycloak_ns: str = "keycloak"
    realm_json: str = "prerequisites/keycloak/service/files/realm.json"

    @property
    def values_dir(self) -> str:
        return str(Path(self.values_file).parent)


# ─── Shell helpers ───────────────────────────────────────────────────────────


def run(args: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    """Run a command. Always captures output so errors include full context.

    When capture=False (default), output is printed to stderr in real time AND
    stored in the result. When capture=True, output is only stored (for parsing).
    On failure, CalledProcessError always contains stdout+stderr.
    """
    result = subprocess.run(
        args, text=True, capture_output=True, cwd=str(REPO_ROOT),
    )
    if not capture:
        if result.stdout:
            sys.stderr.write(result.stdout)
        if result.stderr:
            sys.stderr.write(result.stderr)
    if check and result.returncode != 0:
        print(f"ERROR: command failed (exit {result.returncode}): {' '.join(args)}", file=sys.stderr)
        if result.stdout:
            print(f"  stdout: {result.stdout.rstrip()}", file=sys.stderr)
        if result.stderr:
            print(f"  stderr: {result.stderr.rstrip()}", file=sys.stderr)
        raise subprocess.CalledProcessError(
            result.returncode, args, output=result.stdout, stderr=result.stderr)
    return result


def oc(*args: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return run(["oc", *args], check=check, capture=capture)


def oc_json(*args: str) -> dict:
    result = oc(*args, "-o", "json", capture=True)
    return json.loads(result.stdout)


def retry_until(*, description: str, timeout: int, interval: int, condition: Callable[[], bool]) -> None:
    deadline = time.time() + timeout
    while not condition():
        if time.time() >= deadline:
            raise TimeoutError(f"{description}: timed out after {timeout}s")
        time.sleep(interval)


def oc_exists(resource: str, namespace: str | None = None) -> bool:
    ns_args = ["-n", namespace] if namespace else []
    result = oc("get", resource, *ns_args, "--no-headers", check=False, capture=True)
    return result.returncode == 0


def oc_apply_secret(name: str, namespace: str, *literal_or_file_args: str) -> None:
    """Create a secret with --dry-run=client and pipe to oc apply."""
    result = run(
        ["oc", "create", "secret", "generic", name,
         *literal_or_file_args,
         "-n", namespace, "--dry-run=client", "-o", "yaml"],
        capture=True,
    )
    apply_result = subprocess.run(
        ["oc", "apply", "-f", "-"],
        input=result.stdout, text=True, capture_output=True, cwd=str(REPO_ROOT),
    )
    if apply_result.returncode != 0:
        print(f"ERROR: oc apply secret/{name} failed", file=sys.stderr)
        if apply_result.stderr:
            print(f"  stderr: {apply_result.stderr.rstrip()}", file=sys.stderr)
        raise subprocess.CalledProcessError(
            apply_result.returncode, ["oc", "apply", "-f", "-"],
            output=apply_result.stdout, stderr=apply_result.stderr)


# ─── Parallel execution ─────────────────────────────────────────────────────


def run_parallel(tasks: list[tuple[str, Callable[[], None]]]) -> None:
    """Run named tasks in parallel. On any failure, print the task name + error and abort."""
    with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        futures = {pool.submit(fn): name for name, fn in tasks}
        errors: list[str] = []
        for future in as_completed(futures):
            name = futures[future]
            try:
                future.result()
            except subprocess.CalledProcessError as e:
                msg = f"{name}: command failed: {e.cmd}\n"
                if e.stdout:
                    msg += f"  stdout: {e.stdout.strip()}\n"
                if e.stderr:
                    msg += f"  stderr: {e.stderr.strip()}\n"
                errors.append(msg)
            except Exception as e:
                errors.append(f"{name}: {e}")
        if errors:
            print("ERROR: parallel tasks failed:", file=sys.stderr)
            for err in errors:
                print(f"  {err}", file=sys.stderr)
            sys.exit(1)


# ─── Phase 1: Fix cluster identity ──────────────────────────────────────────


def patch_stale_routes(config: RefreshConfig) -> None:
    for ns in [config.namespace, config.keycloak_ns, "multicluster-engine"]:
        if not oc_exists(f"namespace/{ns}"):
            continue
        routes_data = oc_json("get", "routes", "-n", ns)
        for route in routes_data.get("items", []):
            name: str = route["metadata"]["name"]
            old_host: str = route["spec"]["host"]
            route_domain = old_host.split(".", 1)[1] if "." in old_host else ""
            if route_domain != config.cluster_domain:
                route_name = old_host.split(".", 1)[0]
                new_host = f"{route_name}.{config.cluster_domain}"
                print(f"  {ns}/{name}: {old_host} -> {new_host}")
                oc("patch", "route", name, "-n", ns, "--type=merge",
                   "-p", json.dumps({"spec": {"host": new_host}}))


def refresh_cdi_certificates() -> None:
    if not oc_exists("namespace/openshift-cnv"):
        return
    print("  Refreshing CDI certificates...")
    for secret in [
        "cdi-apiserver-signer", "cdi-uploadproxy-signer",
        "cdi-uploadserver-client-signer", "cdi-uploadserver-signer",
        "cdi-apiserver-server-cert", "cdi-uploadproxy-server-cert",
        "cdi-uploadserver-client-cert",
    ]:
        if oc_exists(f"secret/{secret}", "openshift-cnv"):
            oc("delete", "secret", secret, "-n", "openshift-cnv")
    if oc_exists("pod", "openshift-cnv"):
        oc("delete", "pod", "-n", "openshift-cnv", "-l", "app=cdi-operator")
    oc("rollout", "status", "deploy/cdi-operator", "-n", "openshift-cnv", "--timeout=300s")
    for deploy in ["cdi-deployment", "cdi-apiserver", "cdi-uploadproxy"]:
        if oc_exists(f"deploy/{deploy}", "openshift-cnv"):
            oc("rollout", "restart", f"deploy/{deploy}", "-n", "openshift-cnv")
    oc("rollout", "status", "deploy/cdi-deployment", "-n", "openshift-cnv", "--timeout=300s")
    print("  CDI certificates refreshed")


def refresh_metallb_and_subnet() -> None:
    if not oc_exists("crd/ipaddresspools.metallb.io"):
        return
    print("  Refreshing MetalLB webhook certificates...")
    if oc_exists("secret/metallb-operator-webhook-server-cert", "metallb-system"):
        oc("delete", "secret", "metallb-operator-webhook-server-cert", "-n", "metallb-system")
    for label in ["control-plane=controller-manager", "component=webhook-server"]:
        oc("delete", "pod", "-n", "metallb-system", "-l", label,
           "--ignore-not-found", check=False)

    retry_until(
        description="MetalLB webhook endpoints",
        timeout=120, interval=5,
        condition=lambda: bool(
            oc("get", "endpoints", "metallb-operator-webhook-server-service",
               "-n", "metallb-system",
               "-o", "jsonpath={.subsets[*].addresses[*].ip}",
               capture=True, check=False).stdout.strip()
        ),
    )

    node_ip = oc("get", "nodes", "-o",
                 "jsonpath={.items[0].status.addresses[?(@.type==\"InternalIP\")].address}",
                 capture=True).stdout.strip()
    subnet_prefix = ".".join(node_ip.split(".")[:3])
    print(f"  MetalLB: {subnet_prefix}.240-{subnet_prefix}.250")

    pool_yaml = json.dumps({
        "apiVersion": "metallb.io/v1beta1",
        "kind": "IPAddressPool",
        "metadata": {"name": "caas-address-pool", "namespace": "metallb-system"},
        "spec": {"addresses": [f"{subnet_prefix}.240-{subnet_prefix}.250"], "autoAssign": True},
    })
    retry_until(
        description="MetalLB IPAddressPool apply",
        timeout=120, interval=10,
        condition=lambda: subprocess.run(
            ["oc", "apply", "-f", "-"],
            input=pool_yaml, text=True, check=False, capture_output=True,
            cwd=str(REPO_ROOT),
        ).returncode == 0,
    )
    print("  MetalLB configured")


def wait_keycloak_cert(config: RefreshConfig) -> None:
    print("  Waiting for Keycloak TLS certificate...")
    oc("wait", "--for=condition=Ready", f"certificate/keycloak-tls",
       "-n", config.keycloak_ns, "--timeout=300s")
    print("  Keycloak TLS ready")


# ─── Phase 2: Prepare environment ───────────────────────────────────────────


def keycloak_sync(config: RefreshConfig) -> None:
    print("  Syncing Keycloak realm...")
    kc_host = oc("get", "route", "keycloak", "-n", config.keycloak_ns,
                 "-o", "jsonpath={.spec.host}", capture=True).stdout.strip()
    kc_url = f"https://{kc_host}"

    retry_until(
        description="Keycloak realm responding",
        timeout=300, interval=5,
        condition=lambda: subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}",
             f"{kc_url}/realms/osac"],
            capture_output=True, text=True, check=False,
        ).stdout.strip() == "200",
    )

    token_resp = run(
        ["curl", "-sk", f"{kc_url}/realms/master/protocol/openid-connect/token",
         "-d", "client_id=admin-cli", "-d", "username=admin",
         "-d", "password=admin", "-d", "grant_type=password"],
        capture=True,
    )
    token_data = json.loads(token_resp.stdout)
    kc_token = token_data.get("access_token", "")
    if not kc_token:
        raise RuntimeError(f"Could not get Keycloak admin token: {token_resp.stdout}")

    realm = json.loads(Path(config.realm_json).read_text())
    auth_header = f"Bearer {kc_token}"

    for client in realm.get("clients", []):
        if client.get("protocol") != "openid-connect":
            continue
        if client.get("publicClient") or client.get("bearerOnly"):
            continue
        uuid: str = client["id"]
        resp = subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}",
             "-H", f"Authorization: {auth_header}",
             f"{kc_url}/admin/realms/osac/clients/{uuid}"],
            capture_output=True, text=True, check=False,
        )
        method = "PUT" if resp.stdout.strip() == "200" else "POST"
        url = f"{kc_url}/admin/realms/osac/clients/{uuid}" if method == "PUT" else f"{kc_url}/admin/realms/osac/clients"
        subprocess.run(
            ["curl", "-sk", "-X", method,
             "-H", f"Authorization: {auth_header}",
             "-H", "Content-Type: application/json",
             url, "-d", json.dumps(client)],
            capture_output=True, text=True, check=False,
        )

    for user in realm.get("users", []):
        uuid = user["id"]
        resp = subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}",
             "-H", f"Authorization: {auth_header}",
             f"{kc_url}/admin/realms/osac/users/{uuid}"],
            capture_output=True, text=True, check=False,
        )
        method = "PUT" if resp.stdout.strip() == "200" else "POST"
        url = f"{kc_url}/admin/realms/osac/users/{uuid}" if method == "PUT" else f"{kc_url}/admin/realms/osac/users"
        subprocess.run(
            ["curl", "-sk", "-X", method,
             "-H", f"Authorization: {auth_header}",
             "-H", "Content-Type: application/json",
             url, "-d", json.dumps(user)],
            capture_output=True, text=True, check=False,
        )

    pw_job = Path("prerequisites/keycloak/service/password-setup-job.yaml")
    if pw_job.exists():
        if oc_exists("job/keycloak-set-passwords", config.keycloak_ns):
            oc("delete", "job", "keycloak-set-passwords", "-n", config.keycloak_ns)
        oc("apply", "-f", str(pw_job), "-n", config.keycloak_ns)
        oc("wait", "--for=condition=Complete", "job/keycloak-set-passwords",
           "-n", config.keycloak_ns, "--timeout=300s")
    print("  Keycloak sync complete")


def create_secrets(config: RefreshConfig) -> None:
    print("  Creating secrets...")
    realm = json.loads(Path(config.realm_json).read_text())

    fc_client = next(c for c in realm["clients"] if c.get("serviceAccountsEnabled"))
    fc_id: str = fc_client["clientId"]
    fc_secret: str = fc_client.get("secret", "")
    if not fc_secret:
        raise RuntimeError(f"No secret for client {fc_id} in realm.json")

    oc_apply_secret("fulfillment-controller-credentials", config.namespace,
                    f"--from-literal=client-id={fc_id}",
                    f"--from-literal=client-secret={fc_secret}")

    license_path = Path(config.values_dir) / "license.zip"
    if not license_path.exists():
        raise FileNotFoundError(f"AAP license not found: {license_path}")
    oc_apply_secret("config-as-code-manifest-ig", config.namespace,
                    f"--from-file=license.zip={license_path}")

    print("  Secrets created")


def ensure_ca_bundle(config: RefreshConfig) -> None:
    run([str(SCRIPT_DIR / "ensure-ca-bundle.sh"), config.namespace])


def wait_tls_certs(config: RefreshConfig) -> None:
    print("  Waiting for TLS certificates...")
    certs_data = oc_json("get", "certificates.cert-manager.io", "-n", config.namespace)
    for cert in certs_data.get("items", []):
        name: str = cert["metadata"]["name"]
        oc("wait", "--for=condition=Ready", f"certificate.cert-manager.io/{name}",
           "-n", config.namespace, "--timeout=300s")
    print("  All TLS certificates ready")


# ─── Phase 3: Scale up operators and start pods ─────────────────────────────


def scale_csv_to(*, csv_name: str, namespace: str, replicas: int) -> None:
    csv_data = oc_json("get", "csv", csv_name, "-n", namespace)
    deploys: list[dict] = csv_data["spec"]["install"]["spec"]["deployments"]
    patch = [
        {"op": "replace",
         "path": f"/spec/install/spec/deployments/{i}/spec/replicas",
         "value": replicas}
        for i in range(len(deploys))
    ]
    oc("patch", "csv", csv_name, "-n", namespace, "--type=json", "-p", json.dumps(patch))
    for d in deploys:
        target = f"{replicas}"
        oc("wait", f"deploy/{d['name']}", "-n", namespace,
           f"--for=jsonpath={{.spec.replicas}}={target}", "--timeout=120s")


def find_csv(*, namespace: str, deploy_name: str) -> str:
    data = oc_json("get", "csv", "-n", namespace)
    for item in data["items"]:
        deploys = item.get("spec", {}).get("install", {}).get("spec", {}).get("deployments", [])
        if any(d["name"] == deploy_name for d in deploys):
            return item["metadata"]["name"]
    raise RuntimeError(f"CSV not found for deployment {deploy_name} in {namespace}")


def scale_authorino_operator() -> None:
    print("  Scaling Authorino operator to 1...")
    csv = find_csv(namespace="openshift-operators", deploy_name="authorino-operator")
    scale_csv_to(csv_name=csv, namespace="openshift-operators", replicas=1)
    print(f"  Authorino operator scaled via CSV {csv}")


def wait_authorino(config: RefreshConfig) -> None:
    print("  Waiting for Authorino...")
    retry_until(
        description="Authorino deployment replicas > 0",
        timeout=120, interval=5,
        condition=lambda: int(
            oc("get", "deploy", "authorino", "-n", config.namespace,
               "-o", "jsonpath={.spec.replicas}", capture=True, check=False
               ).stdout.strip() or "0"
        ) > 0,
    )
    oc("rollout", "status", "deploy/authorino", "-n", config.namespace, "--timeout=120s")
    print("  Authorino running")


def upgrade_fulfillment_db(config: RefreshConfig) -> None:
    print("  Upgrading fulfillment-db...")
    run(["helm", "upgrade", "--install", "fulfillment-db",
         "base/osac-fulfillment-service/it/charts/postgres/",
         "--namespace", config.namespace,
         "--set", "certs.issuerRef.name=default-ca",
         "--set", "certs.caBundle.configMap=ca-bundle",
         "--set", "databases[0].name=service",
         "--set", "databases[0].user=service",
         "--timeout", "5m", "--wait"])


def upgrade_osac(config: RefreshConfig) -> None:
    print("  Upgrading osac chart...")
    oc("delete", "secret", "config-as-code-ig", "-n", config.namespace,
       "--ignore-not-found")
    base_domain = "hosted." + config.cluster_domain.removeprefix("apps.")
    run(["helm", "upgrade", "osac", "charts/osac/",
         "--namespace", config.namespace,
         "--values", config.values_file,
         "--set", "aap.bootstrap.enabled=false",
         "--set", f"clusterFulfillment.config.HOSTED_CLUSTER_BASE_DOMAIN={base_domain}",
         "--timeout", "15m"])


def wait_fulfillment(config: RefreshConfig) -> None:
    print("  Waiting for fulfillment deployments...")
    deploys = oc_json("get", "deploy", "-n", config.namespace,
                      "-l", "app=fulfillment-service")
    for d in deploys.get("items", []):
        name: str = d["metadata"]["name"]
        oc("rollout", "status", f"deploy/{name}", "-n", config.namespace, "--timeout=300s")
    oc("rollout", "status", "deploy/osac-operator", "-n", config.namespace, "--timeout=300s")
    print("  Fulfillment + operator running")


def _aap_controller_reconciled(config: RefreshConfig, stale_ts: str) -> bool:
    result = oc(
        "get", "automationcontroller", "osac-aap-controller",
        "-n", config.namespace,
        "-o", "jsonpath="
              "{.status.conditions[?(@.type==\"Running\")].status}"
              " "
              "{.status.conditions[?(@.type==\"Successful\")].lastTransitionTime}",
        capture=True, check=False,
    ).stdout.strip().split()
    if len(result) != 2:
        return False
    running, current_ts = result
    return running == "True" and current_ts != stale_ts


def start_aap(config: RefreshConfig) -> None:
    print("  Scaling AAP operators to 1...")
    stale_ts = oc(
        "get", "automationcontroller", "osac-aap-controller",
        "-n", config.namespace,
        "-o", 'jsonpath={.status.conditions[?(@.type=="Successful")].lastTransitionTime}',
        capture=True, check=False,
    ).stdout.strip()
    csv = find_csv(namespace="ansible-aap",
                   deploy_name="automation-controller-operator-controller-manager")
    scale_csv_to(csv_name=csv, namespace="ansible-aap", replicas=1)

    print("  Waiting for AAP controller...")
    retry_until(
        description="AAP controller reconciliation",
        timeout=600, interval=10,
        condition=lambda: _aap_controller_reconciled(config, stale_ts),
    )

    aap_host = oc("get", "route", "osac-aap", "-n", config.namespace,
                  "-o", "jsonpath={.spec.host}", capture=True).stdout.strip()
    run_parallel([
        ("AAP gateway responding", lambda: retry_until(
            description="AAP gateway responding",
            timeout=600, interval=10,
            condition=lambda: subprocess.run(
                ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}",
                 f"https://{aap_host}/api/gateway/v1/"],
                capture_output=True, text=True, check=False,
            ).stdout.strip() == "200",
        )),
        ("AAP controller-task rollout", lambda: oc(
            "rollout", "status", "deploy/osac-aap-controller-task",
            "-n", config.namespace, "--timeout=600s",
        )),
    ])
    print("  AAP running")


def fix_assisted_service() -> None:
    if oc_exists("secret/assisted-servicelocal-auth", "multicluster-engine"):
        print("  Deleting stale assisted-service auth keypair...")
        oc("delete", "secret", "assisted-servicelocal-auth", "-n", "multicluster-engine")
    if oc_exists("deploy/assisted-service", "multicluster-engine"):
        oc("rollout", "restart", "deploy/assisted-service", "-n", "multicluster-engine")
        oc("rollout", "restart", "statefulset/assisted-image-service", "-n", "multicluster-engine")


# ─── Phase 4: Post-flight ───────────────────────────────────────────────────


def post_flight(config: RefreshConfig) -> None:
    oc("config", "set-context", "--current", f"--namespace={config.namespace}")

    # Set env vars for sub-scripts (they read from environment)
    os.environ["INSTALLER_NAMESPACE"] = config.namespace
    if config.vm_template:
        os.environ["INSTALLER_VM_TEMPLATE"] = config.vm_template
    if config.cluster_template:
        os.environ["INSTALLER_CLUSTER_TEMPLATE"] = config.cluster_template

    print("  Running prepare-aap.sh...")
    run([str(SCRIPT_DIR / "prepare-aap.sh")])

    # publish-templates must run because the fulfillment database is recreated
    # on every refresh (bare Pod with emptyDir — data lost on scale-to-zero).
    print("  Running prepare-fulfillment-service.sh...")
    run([str(SCRIPT_DIR / "prepare-fulfillment-service.sh")])

    print("  Waiting for fulfillment rollouts...")
    deploys = oc_json("get", "deploy", "-n", config.namespace,
                      "-l", "app=fulfillment-service")
    for d in deploys.get("items", []):
        name: str = d["metadata"]["name"]
        oc("rollout", "status", f"deploy/{name}", "-n", config.namespace, "--timeout=300s")

    print("  Running prepare-tenant.sh...")
    run([str(SCRIPT_DIR / "prepare-tenant.sh")])

    # Clean up env vars we set (don't leak to caller)
    for key in ["INSTALLER_NAMESPACE", "INSTALLER_VM_TEMPLATE", "INSTALLER_CLUSTER_TEMPLATE"]:
        os.environ.pop(key, None)


# ─── Main ────────────────────────────────────────────────────────────────────


def main() -> None:
    values_file = os.environ.get("VALUES_FILE")
    if not values_file:
        print("ERROR: VALUES_FILE must be set (e.g. values/vmaas-ci/values.yaml)", file=sys.stderr)
        sys.exit(1)

    namespace = os.environ.get("INSTALLER_NAMESPACE", "osac-e2e-ci")
    cluster_domain = oc("get", "ingresses.config/cluster", "-o",
                        "jsonpath={.spec.domain}", capture=True).stdout.strip()

    config = RefreshConfig(
        values_file=values_file,
        namespace=namespace,
        cluster_domain=cluster_domain,
        vm_template=os.environ.get("INSTALLER_VM_TEMPLATE", ""),
        cluster_template=os.environ.get("INSTALLER_CLUSTER_TEMPLATE", ""),
    )

    print("=== Refreshing OSAC after snapshot boot (Helm) ===")
    print(f"Namespace: {config.namespace}")
    print(f"Values: {config.values_file}")
    print(f"Cluster domain: {config.cluster_domain}")
    print()

    # Phase 1: Fix cluster identity (all parallel)
    print("[Phase 1] Fixing cluster identity...")
    run_parallel([
        ("patch routes", lambda: patch_stale_routes(config)),
        ("refresh CDI certs", refresh_cdi_certificates),
        ("refresh MetalLB", refresh_metallb_and_subnet),
        ("wait Keycloak cert", lambda: wait_keycloak_cert(config)),
    ])
    print("[Phase 1] Done\n")

    # Phase 2: Prepare environment (all parallel)
    print("[Phase 2] Preparing environment...")
    run_parallel([
        ("Keycloak sync", lambda: keycloak_sync(config)),
        ("create secrets", lambda: create_secrets(config)),
        ("ensure CA bundle", lambda: ensure_ca_bundle(config)),
        ("wait TLS certs", lambda: wait_tls_certs(config)),
    ])
    print("[Phase 2] Done\n")

    # Phase 3: Scale up operators and start pods
    print("[Phase 3] Starting pods...")
    scale_authorino_operator()
    wait_authorino(config)
    upgrade_fulfillment_db(config)
    upgrade_osac(config)
    run_parallel([
        ("wait fulfillment", lambda: wait_fulfillment(config)),
        ("start AAP", lambda: start_aap(config)),
    ])
    fix_assisted_service()
    print("[Phase 3] Done\n")

    # Phase 4: Post-flight (sequential)
    print("[Phase 4] Post-flight configuration...")
    post_flight(config)

    print()
    print("=== Refresh complete ===")
    print(f"Cluster domain: {config.cluster_domain}")
    print(f"Namespace: {config.namespace}")


if __name__ == "__main__":
    main()
