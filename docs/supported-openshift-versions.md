# Supported OpenShift versions

**Minimum supported version: OpenShift 4.22.**
**Status as of 2026-11-05 (revised)** — this page is the authoritative summary of which
OpenShift minor versions the Confidential Containers validated pattern is
supported on, and why.

## Support matrix

| OpenShift | Status | Notes |
|---|---|---|
| **5.0** | ❌ **Not supportable on Intel TDX (yet)** | Installs cleanly (5.0.0, k8s 1.36.5) and the Kyverno gate passes (MAP API is GA `v1`), **but the Intel device/attestation operators are absent from every 5.0 catalog** — no SGX/TDX device plugin, no DCAP/QGS, so attestation is impossible on Intel TDX. Tracked in [#167](https://github.com/validatedpatterns/coco-pattern/issues/167). |
| **4.22** | **Validated** | Full connected + disconnected lifecycles passed (4.22.17), including attestation and confidential workload image pulls. |
| **4.21** | ❌ **Not supported** | Below the floor. Installs cleanly (k8s 1.34.9) but the admissionregistration group serves only `v1` — no MutatingAdmissionPolicy resource — so Kyverno cannot start. Measured, not assumed. |
| 4.20 | ❌ **Not supported** | Below the floor, same cause (API absent on k8s 1.33). |
| 4.19 | ❌ **Not supported** | Below the floor, same cause (API absent on k8s 1.32; crashloop observed). |
| 4.23 | — | **Never released.** There is no OpenShift 4.23; the upgrade path goes 4.22 → 5.0. |

```
4.19        4.20        4.21        4.22        4.23        5.0
 ✗───────────✗───────────✗───────────✓───────────✗───────────✗
                                    floor                 catalog gap
                                    supported             (Intel TDX)
```

"Validated" means the gate set in [What validated means](#what-validated-means)
passed on a clean install. "In validation" means not every gate has been
demonstrated yet on that version, and no support claim is made.

## Why 4.22 is the minimum

The pattern's policy engine is Kyverno (vendored chart `3.7.2`, application
version `v1.17.2`). Its admission controller **unconditionally watches** the
`admissionregistration.k8s.io/v1alpha1` **MutatingAdmissionPolicy** and
**MutatingAdmissionPolicyBinding** APIs.

That API is not served on older Kubernetes versions used by OpenShift:

| OpenShift | Kubernetes | `v1alpha1 MutatingAdmissionPolicy` | Vendored Kyverno 1.17.2 |
|---|---|---|---|
| 4.19 | 1.32 | absent | `CrashLoopBackOff` (observed) |
| 4.20 | 1.33 | absent (verified via `oc api-resources`) | same failure |
| 4.21 | 1.34 | **absent** (group serves only `v1`) | same failure |
| 4.22 | 1.35 | present | runs (validated) |

On 4.19, 4.20 and 4.21 the result is:

- `kyverno-admission-controller` cannot sync its informer caches
  (`failed to list *v1alpha1.MutatingAdmissionPolicy: the server could not find
  the requested resource`) and enters `CrashLoopBackOff`
- the `kyverno` Argo CD application reports **Degraded**
- `kyverno` is a sync-wave 0 application, so the app-of-apps health gate never
  releases the later waves — the pattern cannot converge, however long it runs

There is **no configuration-only workaround**: the chart's own switches
(`generateMutatingAdmissionPolicy`, `mutatingAdmissionPolicyReports`) are already
`false`, and the informer is unconditional in that build (compiled against
`k8s.io/client-go v0.35.1`). The vendored chart also declares
`kubeVersion: '>=1.25.0-0'`, so this is an **upstream Kyverno defect** relative
to its own claimed support, not a property of older OpenShift.

This is tracked upstream as
[validatedpatterns/coco-pattern#166](https://github.com/validatedpatterns/coco-pattern/issues/166).

## Why 5.0 is not supportable on Intel TDX

OpenShift 5.0.0 installs cleanly (Kubernetes 1.36.5), the Kyverno gate is
satisfied (MutatingAdmissionPolicy is GA as `admissionregistration.k8s.io/v1`),
and the confidential-containers stack is otherwise present — `sandboxed-containers-operator` 1.13.1, `trustee-operator` 1.2.1, GitOps 1.22.3, ACM/MCE 2.17.3,
ESO 1.2.1, cert-manager 1.20.1, LVMS `stable-5.0` 5.0.0, CNV 5.0.0, NFD 5.0.0.

What is missing is the Intel hardware-attestation chain. Across all 499
packages in the 5.0 catalogs there is **no** `intel-device-plugins-operator` and
**no** `intel-tdx-dcap-operator` (both present on 4.x, `certified-operators`):

- no device plugin ⇒ no SGX/TDX device exposure for quoting workloads
- no DCAP operator ⇒ no QGS/PCCS ⇒ no TDX quote for attestation

So on Intel TDX hardware, 5.0 cannot attest. Other TEE profiles use different
components and are not covered by this finding. Tracked in
[#167](https://github.com/validatedpatterns/coco-pattern/issues/167).

## Restoring support for 4.19 / 4.20 / 4.21

A single Kyverno pin would restore **three** minor versions. Both routes require
a repository change; neither is implemented:

1. **Per-version Kyverno pin** — select a Kyverno release that does not watch the
   absent alpha API, chosen by `global.clusterVersion` (vendored second chart or
   a versioned Helm-repo chart), plus the matching image in the airgap imageset.
2. **Upstream Kyverno fix** — make the MutatingAdmissionPolicy informer
   conditional on API discovery, which would restore 4.19/4.20 with no pin.

## Checking a new version before deploying

Two checks answer in minutes whether a version is viable. Run them on a freshly
installed cluster of that version, before deploying the pattern.

1. **Policy engine API availability** — this is the gate that sets the floor:

   ```bash
   oc api-resources | grep -i mutatingadmissionpolic
   ```

   Output present → the vendored Kyverno can start. Empty → the pattern will not
   converge on that version.

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

   Any `MISSING` among the confidential-runtime, attestation, GitOps, or secrets
   operators means the pattern is not supportable on that version.

## What "validated" means

A version is only called validated when, on a clean install, all of the following
hold for both a connected deployment and a disconnected deployment from that
version's own mirror:

- every pattern application reaches `Synced` + `Healthy`
- app-of-apps sync-wave ordering is observed (workloads are not created before
  the attestation service is serving)
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
