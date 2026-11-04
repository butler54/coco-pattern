# Supported OpenShift versions

**Minimum supported version: OpenShift 4.20.**
**Status as of 2026-11-04** — this page is the authoritative summary of which
OpenShift minor versions the Confidential Containers validated pattern is
supported on, and why.

## Support matrix

| OpenShift | Status | Notes |
|---|---|---|
| **5.0** | In validation | Initially GA (5.0.0). Full connected + disconnected lifecycles under test. |
| **4.22** | **Validated** | Full connected + disconnected lifecycles passed (4.22.17), including attestation and confidential workload image pulls. Latest z-stream is newer than the validated pin. |
| **4.21** | In validation | Full connected + disconnected lifecycles under test. |
| **4.20** | **Minimum supported** | Floor of the support range. Full connected + disconnected lifecycles under test. |
| **4.19** | ❌ **Not supported** | Below the floor — see [Why 4.20 is the minimum](#why-420-is-the-minimum). |
| 4.23 | — | **Never released.** There is no OpenShift 4.23; the upgrade path goes 4.22 → 5.0. |

"Validated" means the gate set in [What validated means](#what-validated-means)
passed on a clean install. "In validation" means the gates have not all been
demonstrated yet on that version and no support claim is made.

## Supported version range

```
4.19         4.20        4.21        4.22        4.23        5.0
 ✗      ──────✓───────────✓───────────✓───────────✗───────────◐
        floor                                        never       in
        supported                                    shipped     validation
```

## Why 4.20 is the minimum

OpenShift **4.19 ships Kubernetes 1.32**, and the pattern's policy engine
(Kyverno, vendored chart `3.7.2`, application version `v1.17.2`) unconditionally
watches the `admissionregistration.k8s.io/v1alpha1` **MutatingAdmissionPolicy**
and **MutatingAdmissionPolicyBinding** APIs.

Those APIs do not exist in Kubernetes 1.32. On 4.19 the result is:

- `kyverno-admission-controller` fails to sync its informer caches
  (`failed to list *v1alpha1.MutatingAdmissionPolicy: the server could not find
  the requested resource`) and enters `CrashLoopBackOff`
- the `kyverno` Argo CD application therefore reports **Degraded**
- `kyverno` is a sync-wave 0 application, so the app-of-apps health gate never
  releases the later waves — the pattern cannot converge, regardless of how long
  it is left running

There is **no configuration-only workaround**. The chart's own feature switches
(`generateMutatingAdmissionPolicy`, `mutatingAdmissionPolicyReports`) are already
`false`; the informer is unconditional in that build (compiled against
`k8s.io/client-go v0.35.1`). Restoring 4.19 support would require pinning an
older Kyverno release for that version (a vendored-chart selection or a
per-version chart pin), which is not currently planned.

Everything else about 4.19 works: the cluster installs, every CoCo-relevant
operator is present in its catalogs (confidential runtime, attestation service,
GitOps, ACM/MCE, external secrets, cert-manager, LVMS, Intel device/DCAP
plugins, NFD), and version-specific values resolve. The single blocker is the
policy engine.

## Checking a new version before deploying

Two checks tell you in minutes whether a version is viable. Run them on a freshly
installed cluster of that version, before deploying the pattern.

1. **Policy engine API availability** (this is the gate that sets the floor):

   ```bash
   oc api-resources | grep -i mutatingadmissionpolic
   ```

   Output present → the vendored Kyverno can start. Empty output → the pattern
   will not converge on that version (see above).

2. **Operator catalog coverage** — confirm the confidential-containers stack is
   offered for that version:

   ```bash
   for p in sandboxed-containers-operator trustee-operator openshift-gitops-operator \
            advanced-cluster-management multicluster-engine \
            openshift-external-secrets-operator openshift-cert-manager-operator \
            lvms-operator intel-device-plugins-operator node-feature-discovery; do
     printf '%-40s ' "$p"
     oc get packagemanifest -n openshift-marketplace "$p" \
       -o jsonpath='{.status.defaultChannel}{" "}{.status.channels[0].currentCSVDesc.version}{"\n"}' 2>/dev/null \
       || echo "MISSING"
   done
   ```

   Any `MISSING` in the confidential-runtime, attestation, GitOps, or secrets
   operators means the pattern is not supportable on that version.

## What "validated" means

A version is only called validated when, on a clean install, all of the following
hold for both a connected deployment and a disconnected deployment from that
version's own mirror:

- every pattern application reaches `Synced` + `Healthy`
- the app-of-apps sync-wave ordering is observed (workloads are not created
  before the attestation service is serving)
- the attestation service returns success and the appraisal is **Affirming**
- confidential workloads run with no restarts
- workload images resolve per mode (public registries when connected, the mirror
  when disconnected)
- the attestation collateral backend matches the mode (online service when
  connected, offline collateral when disconnected)
- the pattern install completes without manual intervention (any exception is
  documented)

## Related

- Airgap/disconnected deployment: [disconnected-deployment.md](disconnected-deployment.md)
- Firmware reference values: [firmware-reference-values.md](firmware-reference-values.md)
- Container signing: [CONTAINER-SIGNING-BLOCKER.md](CONTAINER-SIGNING-BLOCKER.md)
