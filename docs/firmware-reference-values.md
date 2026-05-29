# Firmware Reference Values for Bare Metal Attestation

This guide explains how to collect firmware reference values for bare metal confidential computing deployments (Intel TDX / AMD SEV-SNP) using the veritas container tool.

## Overview

Firmware reference values are cryptographic measurements of the Trusted Computing Base (TCB) components:

- **Intel TDX**: `mr_td` (OVMF firmware hash), `rtmr_1` (kernel/initrd), `rtmr_2` (cmdline variants), `xfam` (CPU features)
- **AMD SEV-SNP**: `snp_launch_measurement` (firmware/kernel/initrd hash), plus other SNP-specific measurements

These values are used by the KBS attestation policy to verify that confidential workloads are running on approved firmware with expected security properties.

## How Veritas Works

Veritas **computes** firmware reference values from OCP release artifacts (kata RPMs, edk2 firmware) - it does **not** collect from running hardware. This means:

- **No cluster pods needed** - runs entirely locally via podman
- **No bootstrap problem** - can run before deploying the pattern
- **Reproducible** - same OCP version produces same firmware values
- **No TEE hardware required** - just downloads and processes artifacts

## Prerequisites

### 1. Local Tools

You need these tools on your local machine or bastion host:

```bash
# Check prerequisites
command -v podman && echo "✓ podman installed"
command -v yq && echo "✓ yq installed"
command -v jq && echo "✓ jq installed"
command -v oc && echo "✓ oc CLI installed (optional, for auto-version detection)"
```

### 2. Red Hat Pull Secret

You need a Red Hat pull secret to download OCP release artifacts:

```bash
# Download from https://console.redhat.com/openshift/downloads#tool-pull-secret
# Save to ~/pull-secret.json
ls -la ~/pull-secret.json
```

### 3. OCP Version

Either:
- Be logged into an OCP cluster (auto-detect version), OR
- Specify the OCP version manually with `--ocp-version`

## Workflow

The firmware collection workflow runs entirely locally:

### Step 1: Collect Firmware Reference Values

```bash
# From the coco-pattern repository root:
make collect-firmware-refvals

# Or manually with options:
./scripts/collect-firmware-refvals.sh \
  --pull-secret ~/pull-secret.json \
  --ocp-version 4.20.15 \
  --tee tdx
```

This command:

1. Runs veritas via podman container (`quay.io/openshift_sandboxed_containers/coco-tools:1.12`)
2. Downloads OCP release artifacts (kata-containers RPM, edk2-ovmf firmware)
3. Computes firmware measurements from artifacts
4. Transforms output to object format for RVPS
5. Saves to `~/.coco-pattern/firmware-reference-values.json`

**Output format** (`~/.coco-pattern/firmware-reference-values.json`):

```json
{
  "mr_td": ["27fb849fb05653add8be4b8c5b2793e6..."],
  "rtmr_1": ["bc875efe0e9f991c6072e3e1422e5e66..."],
  "rtmr_2": ["3c764645b39c6402b5c9f2df3d32eedf...", "..."],
  "xfam": ["0700000000000000"]
}
```

**Key points:**

- Each field is an **array** of strings (supports multiple valid values)
- Hash values are lowercase hex strings (SHA-384 = 96 hex chars for TDX firmware)
- Empty arrays `[]` mean "not available" - attestation will skip that check
- `rtmr_2` has multiple values (one per CPU count variant, max 32 by default)

### Step 2: Enable in values-secret.yaml

Uncomment the `firmwareReferenceValues` section in `~/values-secret-coco-pattern.yaml`:

```yaml
- name: firmwareReferenceValues
  vaultPrefixes:
  - hub
  fields:
  - name: json
    path: ~/.coco-pattern/firmware-reference-values.json
```

### Step 3: Load Secrets to Vault

```bash
make load-secrets
```

The validated patterns framework reads `values-secret-coco-pattern.yaml` and pushes firmware values to Vault at `secret/data/hub/firmwareReferenceValues`.

### Step 4: Verify Upload

```bash
# Check the secret was written to Vault
vault kv get secret/hub/firmwareReferenceValues
```

Expected output shows a single `json` key containing the full JSON object.

### Step 5: Deploy/Sync KBS

If the KBS cluster is already running:

```bash
# Force ExternalSecret to re-sync from Vault
oc delete externalsecret firmware-refvals-eso -n trustee-operator-system

# Verify the secret synced
oc get secret firmware-reference-values -n trustee-operator-system -o jsonpath='{.data.json}' | base64 -d | jq .

# Check RVPS ConfigMap contains firmware entries
oc get configmap rvps-reference-values -n trustee-operator-system -o jsonpath='{.data.reference-values\.json}' | jq '.[] | select(.name | startswith("mr_td") or startswith("rtmr"))'
```

If deploying fresh:

```bash
make install
```

The RVPS will automatically load reference values from the `rvps-reference-values` ConfigMap.

## Multi-OCP-Version Support

Different OpenShift versions may have different firmware measurements due to kernel/firmware updates. To support multiple versions:

1. **Collect from each version:**

   ```bash
   # On OCP 4.20.15 cluster or with manual version
   ./scripts/collect-firmware-refvals.sh --ocp-version 4.20.15
   cat ~/.coco-pattern/firmware-reference-values.json

   # Manually merge additional versions by adding to arrays
   # Or use veritas directly with multiple --ocp-version flags
   ```

2. **The firmware values contain multiple CPU count variants:**

   Veritas automatically generates `rtmr_2` values for CPU counts 1-32 (configurable with `--max-cpu-count`). This covers pods with different `nr_cpus` settings.

3. **Load merged values to Vault:**

   ```bash
   make load-secrets
   ```

The attestation policy uses `in` checks - a pod passes if its measurement matches **any** value in the array.

## Advanced Options

The collection script supports several options:

```bash
# Specify OCP version manually
./scripts/collect-firmware-refvals.sh --ocp-version 4.20.15

# Use different pull secret location
./scripts/collect-firmware-refvals.sh --pull-secret /path/to/pull-secret.json

# Override output file
./scripts/collect-firmware-refvals.sh --output /custom/path/firmware.json

# Use SNP instead of TDX
./scripts/collect-firmware-refvals.sh --tee snp

# Show all options
./scripts/collect-firmware-refvals.sh --help
```

## Troubleshooting

### Podman permission denied errors

**Symptom:** `permission denied` when mounting pull secret

**Fix:** Add SELinux relabeling flag (automatically handled in script):

```bash
podman run -v ~/pull-secret.json:/pull-secret.json:ro,z ...
```

### Auto-detection fails

**Symptom:** `Could not auto-detect OCP version`

**Fix:** Either log into a cluster first, or specify manually:

```bash
./scripts/collect-firmware-refvals.sh --ocp-version 4.20.15
```

### RVPS policy failure: can't evaluate field mr_td in type []interface {}

**Symptom:** ConfigurationPolicy `rvps-policy-cp` shows NonCompliant

**Cause:** Firmware reference values secret has wrong format (array instead of object)

**Fix:** The collection script now automatically transforms the output. If you collected values manually, re-run:

```bash
make collect-firmware-refvals
make load-secrets
```

### Hash mismatch during attestation

**Cause:** Firmware updated between collection and deployment, or different OCP version

**Fix:** Re-collect firmware values for the actual deployed OCP version:

```bash
# Detect version from cluster
oc version -o json | yq -r '.openshiftVersion'

# Re-collect
make collect-firmware-refvals
make load-secrets

# Force RVPS refresh
oc delete configurationpolicy rvps-policy-cp -n local-cluster
```

## SHA-256 vs SHA-384

You may notice different hash algorithms in different contexts:

- **init_data TOML**: SHA-256 (CoCo initdata spec, used for PCR8 extend)
- **Bare metal TDX firmware**: SHA-384 (Intel TDX architecture requirement)
- **Bare metal SNP firmware**: SHA-384 (AMD SEV-SNP architecture requirement)
- **Azure vTPM PCRs**: SHA-256

These are **correct** - they're different mechanisms at different layers. The attestation policy checks these independently.

## Security Considerations

### Threat Model

Firmware reference values protect against:

- Unauthorized firmware modifications (malicious OVMF, compromised bootloader)
- Kernel tampering (different kernel than expected)
- Debug mode enabled (allows memory inspection via hypervisor)

### Debug Mode

The attestation policy enforces `debug == false` for both TDX and SNP. Debug mode allows:

- Memory inspection via hypervisor
- Single-stepping the guest
- Extracting secrets from guest memory

**Production workloads must run with debug disabled.** If attestation fails due to debug mode, do not disable the check - fix the KataConfig to disable debug.

## References

- [Veritas GitHub Repository](https://github.com/confidential-devhub/veritas)
- [Red Hat OpenShift Sandboxed Containers Documentation](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12)
- [Intel TDX Attestation Spec](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
- [AMD SEV-SNP Attestation Spec](https://www.amd.com/en/developer/sev.html)
- [Trustee Attestation Policy Reference](https://github.com/openshift/trustee-operator/tree/main/config/templates)
