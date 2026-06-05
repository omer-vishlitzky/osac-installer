#!/usr/bin/env python3
"""Sync overlay AuthConfig Rego policies with the base manifest.

The base Rego lives in the fulfillment-service submodule. Each overlay
replaces the entire Rego because kustomize can't patch inside a YAML
string. This script detects drift and can auto-fix it.

Usage:
    python3 scripts/sync-authconfig-rego.py          # Check (CI mode)
    python3 scripts/sync-authconfig-rego.py --fix    # Auto-fix
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE_AUTHCONFIG = REPO_ROOT / "base/osac-fulfillment-service/manifests/base/grpc-server/authconfig.yaml"

OVERLAYS = {
    "vmaas-ci": "osac-e2e-ci",
    "caas-ci": "osac-e2e-ci",
    "development": "osac-devel",
    "osac-integration": "osac-integration",
}

EXTRA_EMERGENCY_SAS = [
    "template-publisher",
    "osac-operator-controller-manager",
]


def extract_rego(path: Path) -> str:
    doc = yaml.safe_load(path.read_text())
    return doc["spec"]["authorization"]["default"]["opa"]["rego"]


def extract_overlay_rego(path: Path) -> str | None:
    doc = yaml.safe_load(path.read_text())
    for patch in doc.get("patches", []):
        patch_content = patch.get("patch") if isinstance(patch, dict) else patch if isinstance(patch, str) else None
        if patch_content is None:
            continue
        patch_doc = yaml.safe_load(patch_content)
        if not isinstance(patch_doc, dict) or patch_doc.get("kind") != "AuthConfig":
            continue
        rego = (patch_doc.get("spec", {}).get("authorization", {}).get("default", {}).get("opa", {}).get("rego"))
        if rego:
            return rego
    return None


def normalize(rego: str) -> str:
    lines = rego.splitlines()
    out = []
    skip = False
    for line in lines:
        if "emergency_service_accounts := {" in line:
            skip = True
            continue
        if skip:
            if line.strip() == "}":
                skip = False
            continue
        stripped = line.rstrip()
        if stripped:
            out.append(stripped)
    return "\n".join(out)


def build_overlay_rego(base_rego: str, namespace: str) -> str:
    rego = base_rego.replace("system:serviceaccount:osac:", f"system:serviceaccount:{namespace}:")

    extra = "\n".join(f'  "system:serviceaccount:{namespace}:{sa}",' for sa in EXTRA_EMERGENCY_SAS)
    pattern = f'"system:serviceaccount:{namespace}:admin",\n}}'
    if pattern not in rego:
        print(f"ERROR: injection point not found in base Rego. Base format may have changed.", file=sys.stderr)
        sys.exit(1)
    rego = rego.replace(pattern, f'"system:serviceaccount:{namespace}:admin",\n{extra}\n}}')
    return rego


def write_overlay_rego(path: Path, new_rego: str) -> None:
    content = path.read_text()

    indented = []
    for line in new_rego.splitlines():
        indented.append(f"                {line}" if line.strip() else "")
    indented_rego = "\n".join(indented)

    match = re.search(r"(              rego: \|\n)", content)
    if not match:
        print(f"  ERROR: could not find 'rego: |' in {path}", file=sys.stderr)
        sys.exit(1)

    start = match.end()

    for i, line in enumerate(content[start:].split("\n")):
        if line.strip() and (len(line) - len(line.lstrip())) <= 14:
            end = start + sum(len(part) + 1 for part in content[start:].split("\n")[:i])
            break
    else:
        end = len(content)

    path.write_text(content[:start] + indented_rego + "\n" + content[end:])


def main() -> None:
    fix = "--fix" in sys.argv

    if not BASE_AUTHCONFIG.exists():
        print(f"ERROR: {BASE_AUTHCONFIG} not found. Run: git submodule update --init --recursive")
        sys.exit(1)

    base_rego = extract_rego(BASE_AUTHCONFIG)
    base_normalized = normalize(base_rego)
    errors = 0

    for overlay, ns in OVERLAYS.items():
        overlay_path = REPO_ROOT / f"overlays/{overlay}/kustomization.yaml"
        if not overlay_path.exists():
            print(f"{overlay}: SKIP (not found)")
            continue

        overlay_rego = extract_overlay_rego(overlay_path)
        if overlay_rego is None:
            print(f"{overlay}: SKIP (no AuthConfig Rego patch)")
            continue

        overlay_normalized = normalize(overlay_rego)

        if base_normalized == overlay_normalized:
            print(f"{overlay}: OK")
        elif fix:
            write_overlay_rego(overlay_path, build_overlay_rego(base_rego, ns))
            print(f"{overlay}: FIXED")
        else:
            print(f"{overlay}: MISMATCH")
            base_lines = base_normalized.splitlines()
            overlay_lines = overlay_normalized.splitlines()
            for i, (b, o) in enumerate(zip(base_lines, overlay_lines)):
                if b != o:
                    print(f"  First diff at line {i + 1}:")
                    print(f"    base:    {b}")
                    print(f"    overlay: {o}")
                    break
            else:
                longer = "base" if len(base_lines) > len(overlay_lines) else "overlay"
                print(f"  {longer} has {abs(len(base_lines) - len(overlay_lines))} extra line(s)")
            errors += 1

    if errors:
        print(f"\n{errors} overlay(s) drifted. Run: python3 scripts/sync-authconfig-rego.py --fix")
        sys.exit(1)
    else:
        print("\nAll overlay AuthConfig Rego policies are in sync with the base.")


if __name__ == "__main__":
    main()
