#!/usr/bin/env bash
# DCAP Offline PCK Provisioning via podman + pck-cert-tool
#
# The jump host bridges the disconnected cluster and Intel PCS API.
# podman runs pck-cert-tool (from the QGS image) which:
#   1. Reads platform-data secrets from the cluster (via kubeconfig)
#   2. Contacts Intel PCS API to register and get PCK certificates
#   3. Creates -pck secrets directly on the cluster
#
# All secrets are cached locally in ~/.coco-pattern/dcap-offline/ for
# backup, inspection, and re-application.
#
# Usage: ./scripts/dcap-offline-provision.sh <step>
#
#   register-pck    Run pck-cert-tool register via podman (creates -pck secrets on cluster)
#   cache-pck       Cache -pck secrets locally to ~/.coco-pattern/dcap-offline/
#   restore-pck     Re-apply cached -pck secrets to cluster (from local cache)
#   status          Show platform-data and PCK secret status
#   verify          Full verification of QGS pods and secrets
#   all             Run register-pck + cache-pck + verify
#
# Environment:
#   KUBECONFIG          Cluster kubeconfig (default: ~/node-02-output/421_build/auth/kubeconfig)
#   INTEL_PCS_API_KEY   Intel PCS API subscription key (required for register-pck)
#   DCAP_QGS_IMAGE      QGS image with pck-cert-tool (default: auto-detect from operator CSV)
#   REGISTER_TIMEOUT    Seconds to let pck-cert-tool run before stopping (default: 120)

set -euo pipefail

DCAP_NS="${DCAP_NS:-intel-dcap-operator-system}"
DCAP_CACHE="${DCAP_CACHE:-$HOME/.coco-pattern/dcap-offline}"
KUBECONFIG="${KUBECONFIG:-$HOME/node-02-output/421_build/auth/kubeconfig}"
INTEL_PCS_API_KEY="${INTEL_PCS_API_KEY:-}"
DCAP_QGS_IMAGE="${DCAP_QGS_IMAGE:-}"
REGISTER_TIMEOUT="${REGISTER_TIMEOUT:-120}"

export KUBECONFIG

usage() {
    cat <<EOF
Usage: $0 <step>

Steps:
  register-pck    Run pck-cert-tool register via podman (needs INTEL_PCS_API_KEY)
  cache-pck       Cache cluster -pck secrets locally to ~/.coco-pattern/dcap-offline/
  restore-pck     Re-apply cached -pck secrets to cluster
  status          Show platform-data and PCK secret status
  verify          Full QGS pod and secret verification
  all             register-pck + cache-pck + verify

Environment:
  KUBECONFIG          Default: ~/node-02-output/421_build/auth/kubeconfig
  INTEL_PCS_API_KEY   Intel PCS API key (get from https://api.portal.trustedservices.intel.com/)
  DCAP_QGS_IMAGE      Override QGS image (default: auto-detect from operator CSV)
  REGISTER_TIMEOUT    Seconds for pck-cert-tool to run (default: 120)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
    [ -f "$KUBECONFIG" ] || die "kubeconfig not found: ${KUBECONFIG}"
    command -v podman >/dev/null 2>&1 || die "podman is required"
    command -v oc >/dev/null 2>&1 || die "oc CLI is required"
}

# Auto-detect the QGS image from the installed operator's CSV relatedImages.
# Falls back to the certified catalog image if the operator is not installed.
resolve_qgs_image() {
    if [ -n "$DCAP_QGS_IMAGE" ]; then
        echo "$DCAP_QGS_IMAGE"
        return
    fi

    local img
    img=$(oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.relatedImages[*]}{.name}{"\t"}{.image}{"\n"}{end}{end}' 2>/dev/null \
        | grep -i "qgs\|pck-cert" | head -1 | awk '{print $NF}')

    if [ -n "$img" ]; then
        echo "$img"
    else
        echo "registry.connect.redhat.com/intel/intel-tdx-qgs:latest"
    fi
}

step_register_pck() {
    echo "=== Register platforms with Intel PCS via podman ==="
    check_prereqs
    [ -n "$INTEL_PCS_API_KEY" ] || die "INTEL_PCS_API_KEY is required. Get one from https://api.portal.trustedservices.intel.com/"
    mkdir -p "$DCAP_CACHE"

    # Check platform-data secrets exist
    local pd_count
    pd_count=$(oc get secrets -n "$DCAP_NS" -l type=platform-data --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$pd_count" -gt 0 ] || die "No platform-data secrets in ${DCAP_NS}. Is the DCAP operator deployed with a TdxQuoteGenerationService CR?"

    echo "Found ${pd_count} platform-data secret(s) in ${DCAP_NS}."

    # Check existing -pck secrets
    local pck_before
    pck_before=$(oc get secrets -n "$DCAP_NS" -l fmspc --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "Existing PCK secrets: ${pck_before}"

    # Resolve QGS image
    local qgs_image
    qgs_image=$(resolve_qgs_image)
    echo "QGS image: ${qgs_image}"
    echo ""

    # Pull image if needed
    echo "Pulling QGS image (if not cached)..."
    podman pull "$qgs_image" 2>&1 | tail -1

    # Run pck-cert-tool register via podman.
    # --network=host: jump host routes to both cluster API and Intel PCS.
    # Mount kubeconfig read-only so the tool can access the cluster.
    # The tool is a continuous watcher; we run it with a timeout.
    echo ""
    echo "Running pck-cert-tool register (timeout: ${REGISTER_TIMEOUT}s)..."
    echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    echo "  Namespace: ${DCAP_NS}"
    echo ""

    # Resolve real kubeconfig path (podman needs absolute path)
    local kc_real
    kc_real=$(realpath "$KUBECONFIG")

    # Run with timeout — the tool watches continuously, so we stop it
    # after it has had time to process existing platform-data secrets.
    set +e
    timeout "${REGISTER_TIMEOUT}" podman run --rm \
        --network=host \
        -v "${kc_real}:/kubeconfig:ro,Z" \
        -e KUBECONFIG=/kubeconfig \
        "$qgs_image" \
        pck-cert-tool register \
            --api-key "$INTEL_PCS_API_KEY" \
            --namespace "$DCAP_NS" \
        2>&1 | tee "${DCAP_CACHE}/register.log"
    local rc=$?
    set -e

    # Exit code 124 = timeout killed it (expected — the tool is a watcher)
    if [ "$rc" -eq 124 ]; then
        echo ""
        echo "pck-cert-tool stopped after ${REGISTER_TIMEOUT}s (expected — it runs as a watcher)."
    elif [ "$rc" -ne 0 ]; then
        echo ""
        echo "WARNING: pck-cert-tool exited with code ${rc}. Check ${DCAP_CACHE}/register.log"
    fi

    # Verify new -pck secrets were created
    local pck_after
    pck_after=$(oc get secrets -n "$DCAP_NS" -l fmspc --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pck_new=$((pck_after - pck_before))

    echo ""
    if [ "$pck_new" -gt 0 ]; then
        echo "Created ${pck_new} new PCK secret(s)."
        echo ""
        oc get secrets -n "$DCAP_NS" -l fmspc --no-headers \
            -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc
    elif [ "$pck_after" -gt 0 ]; then
        echo "No new PCK secrets (${pck_after} already existed — may have been previously provisioned)."
    else
        echo "WARNING: No PCK secrets found after registration."
        echo "Check the log: ${DCAP_CACHE}/register.log"
        echo ""
        echo "Common issues:"
        echo "  - Invalid Intel PCS API key"
        echo "  - Platform-data secrets have invalid format"
        echo "  - Network connectivity (jump host must reach api.trustedservices.intel.com)"
    fi
    echo ""
}

step_cache_pck() {
    echo "=== Cache PCK secrets locally ==="
    check_prereqs
    mkdir -p "$DCAP_CACHE"

    local count
    count=$(oc get secrets -n "$DCAP_NS" -l fmspc --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] || die "No PCK secrets (labeled fmspc) in ${DCAP_NS}. Run register-pck first."

    # Export -pck secrets
    oc get secrets -n "$DCAP_NS" -l fmspc -o yaml \
        | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /selfLink:/d' \
        > "${DCAP_CACHE}/pck-secrets.yaml"

    # Also export platform-data for reference
    oc get secrets -n "$DCAP_NS" -l type=platform-data -o yaml \
        | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /selfLink:/d' \
        > "${DCAP_CACHE}/platform-data-secrets.yaml"

    echo "Cached to ${DCAP_CACHE}/:"
    ls -lh "${DCAP_CACHE}/"*.yaml 2>/dev/null
    echo ""
    echo "PCK secrets (${count}):"
    oc get secrets -n "$DCAP_NS" -l fmspc --no-headers \
        -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc
    echo ""
}

step_restore_pck() {
    echo "=== Restore cached PCK secrets to cluster ==="
    check_prereqs

    [ -f "${DCAP_CACHE}/pck-secrets.yaml" ] || die "No cached secrets at ${DCAP_CACHE}/pck-secrets.yaml. Run cache-pck first."

    echo "Applying cached PCK secrets..."
    oc apply -f "${DCAP_CACHE}/pck-secrets.yaml" -n "$DCAP_NS"
    echo ""
    echo "Restored. QGS pods will detect and mount them."
    echo ""
}

step_status() {
    echo "=== DCAP Status ==="
    check_prereqs

    echo "Namespace: ${DCAP_NS}"
    echo ""

    echo "Platform-data secrets:"
    oc get secrets -n "$DCAP_NS" -l type=platform-data --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null \
        || echo "  (none)"
    echo ""

    echo "PCK secrets:"
    oc get secrets -n "$DCAP_NS" -l fmspc --no-headers \
        -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc 2>/dev/null \
        || echo "  (none)"
    echo ""

    echo "Local cache:"
    ls -lh "${DCAP_CACHE}/"*.yaml 2>/dev/null || echo "  (empty)"
    echo ""
}

step_verify() {
    echo "=== DCAP Verification ==="
    check_prereqs

    echo "--- TdxQuoteGenerationService CR ---"
    oc get tdxquotegenerationservice -A -o wide 2>/dev/null \
        || echo "  (no CR found or CRD not installed)"
    echo ""

    echo "--- QGS pods ---"
    oc get pods -n "$DCAP_NS" -o wide 2>/dev/null || echo "  (no pods)"
    echo ""

    echo "--- Platform-data secrets ---"
    oc get secrets -n "$DCAP_NS" -l type=platform-data --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null \
        || echo "  (none)"
    echo ""

    echo "--- PCK secrets ---"
    oc get secrets -n "$DCAP_NS" -l fmspc --no-headers \
        -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc 2>/dev/null \
        || echo "  (none)"
    echo ""

    echo "--- Operator pods ---"
    oc get pods -n "$DCAP_NS" -l control-plane=controller-manager --no-headers 2>/dev/null \
        || echo "  (no operator pods)"
    echo ""

    # Check if QGS pods have cert files mounted
    local qgs_pod
    qgs_pod=$(oc get pod -n "$DCAP_NS" -l app=intel-tdx-qgs -o name 2>/dev/null | head -1)
    if [ -n "$qgs_pod" ]; then
        echo "--- QGS certificate cache ---"
        oc exec -n "$DCAP_NS" "$qgs_pod" -- ls -la /run/dcap/cache/.dcap-qcnl/ 2>/dev/null \
            || echo "  (no cert cache or container not ready)"
        echo ""
    fi
}

# Dispatch
case "${1:-}" in
    register-pck)   step_register_pck ;;
    cache-pck)      step_cache_pck ;;
    restore-pck)    step_restore_pck ;;
    status)         step_status ;;
    verify)         step_verify ;;
    all)
        step_register_pck
        step_cache_pck
        step_verify
        echo "=== DCAP offline provisioning complete ==="
        echo "PCK certificates cached at: ${DCAP_CACHE}/"
        ;;
    -h|--help|"")   usage ;;
    *)              die "Unknown step: $1" ;;
esac
