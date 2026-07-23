#!/usr/bin/env bash
# DCAP Offline PCK Certificate Provisioning
#
# Provisions PCK certificates for a disconnected (offline) TDX cluster by
# using an internet-connected Azure cluster as an intermediary.
#
# Workflow:
#   1. Extract platform-data secrets from the disconnected cluster (node-02)
#      -- these are created automatically by the DCAP operator's initContainer
#   2. Apply platform-data secrets to the Azure cluster (internet-connected)
#   3. The Azure DCAP operator (Online mode) contacts Intel PCS to register
#      the platforms and obtain PCK certificates, creating -pck secrets
#   4. Extract the -pck secrets from the Azure cluster
#   5. Apply the -pck secrets back to the disconnected cluster
#
# Prerequisites:
#   - DCAP operator deployed on both clusters
#   - Disconnected cluster: Offline mode (operator creates platform-data secrets)
#   - Azure cluster: Online mode (operator contacts Intel PCS for PCK certs)
#   - KUBECONFIG_DISCONNECTED pointing to the disconnected cluster
#   - KUBECONFIG_CONNECTED pointing to the Azure cluster
#
# Usage: ./scripts/dcap-offline-provision.sh [step] [options]
#
#   Steps (run individually or use 'all' for full workflow):
#     extract-platform-data   Step 1: Extract platform-data from disconnected cluster
#     apply-platform-data     Step 2: Apply platform-data to Azure cluster
#     wait-for-pck            Step 3: Wait for Azure operator to create PCK secrets
#     extract-pck             Step 4: Extract PCK secrets from Azure cluster
#     apply-pck               Step 5: Apply PCK secrets to disconnected cluster
#     verify                  Verify: Check QGS pods and secrets on disconnected cluster
#     all                     Run full workflow (steps 1-5 + verify)
#
# Environment:
#   KUBECONFIG_DISCONNECTED  Kubeconfig for disconnected cluster (default: ~/node-02-output/421_build/auth/kubeconfig)
#   KUBECONFIG_CONNECTED     Kubeconfig for Azure cluster (default: ~/azure/kubeconfig)
#   DCAP_WORK_DIR            Working directory for intermediate files (default: ~/.coco-pattern/dcap-offline)

set -euo pipefail

DCAP_NS="intel-dcap-operator-system"
DCAP_WORK_DIR="${DCAP_WORK_DIR:-$HOME/.coco-pattern/dcap-offline}"
KUBECONFIG_DISCONNECTED="${KUBECONFIG_DISCONNECTED:-$HOME/node-02-output/421_build/auth/kubeconfig}"
KUBECONFIG_CONNECTED="${KUBECONFIG_CONNECTED:-$HOME/azure/kubeconfig}"
PCK_WAIT_TIMEOUT="${PCK_WAIT_TIMEOUT:-300}"

usage() {
    echo "Usage: $0 <step> [options]"
    echo ""
    echo "Steps:"
    echo "  extract-platform-data   Extract platform-data secrets from disconnected cluster"
    echo "  apply-platform-data     Apply platform-data secrets to Azure (connected) cluster"
    echo "  wait-for-pck            Wait for Azure operator to create PCK secrets"
    echo "  extract-pck             Extract PCK secrets from Azure cluster"
    echo "  apply-pck               Apply PCK secrets to disconnected cluster"
    echo "  verify                  Verify QGS pods and secrets on disconnected cluster"
    echo "  all                     Run full workflow (steps 1-5 + verify)"
    echo ""
    echo "Environment variables:"
    echo "  KUBECONFIG_DISCONNECTED  Default: ~/node-02-output/421_build/auth/kubeconfig"
    echo "  KUBECONFIG_CONNECTED     Default: ~/azure/kubeconfig"
    echo "  DCAP_WORK_DIR            Default: ~/.coco-pattern/dcap-offline"
    echo "  PCK_WAIT_TIMEOUT         Seconds to wait for PCK secrets (default: 300)"
}

check_kubeconfig() {
    local label="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "ERROR: ${label} kubeconfig not found: ${path}"
        exit 1
    fi
}

step_extract_platform_data() {
    echo "=== Step 1: Extract platform-data secrets from disconnected cluster ==="
    echo "Kubeconfig: $KUBECONFIG_DISCONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo ""

    check_kubeconfig "Disconnected" "$KUBECONFIG_DISCONNECTED"
    mkdir -p "$DCAP_WORK_DIR"

    echo "Checking for platform-data secrets..."
    local count
    count=$(KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l type=platform-data --no-headers 2>/dev/null | wc -l)

    if [ "$count" -eq 0 ]; then
        echo "ERROR: No platform-data secrets found in ${DCAP_NS}."
        echo ""
        echo "The DCAP operator's platform-registration initContainer creates these"
        echo "automatically when QGS pods start on TDX nodes."
        echo ""
        echo "Check that:"
        echo "  1. The DCAP operator is installed and the TdxQuoteGenerationService CR exists"
        echo "  2. QGS pods are running (or have run) on TDX-capable nodes"
        echo "  3. The namespace is correct: ${DCAP_NS}"
        echo ""
        echo "Debug: kubectl --kubeconfig=${KUBECONFIG_DISCONNECTED} get pods -n ${DCAP_NS}"
        exit 1
    fi

    echo "Found ${count} platform-data secret(s)."

    # Export secrets, stripping cluster-specific metadata for portability
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l type=platform-data -o yaml \
        | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /selfLink:/d' \
        > "${DCAP_WORK_DIR}/platform-data-secrets.yaml"

    echo "Extracted to: ${DCAP_WORK_DIR}/platform-data-secrets.yaml"
    echo ""
    echo "Secrets extracted:"
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l type=platform-data --no-headers \
        -o custom-columns=NAME:.metadata.name
    echo ""
}

step_apply_platform_data() {
    echo "=== Step 2: Apply platform-data secrets to Azure (connected) cluster ==="
    echo "Kubeconfig: $KUBECONFIG_CONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo ""

    check_kubeconfig "Connected" "$KUBECONFIG_CONNECTED"

    if [ ! -f "${DCAP_WORK_DIR}/platform-data-secrets.yaml" ]; then
        echo "ERROR: No platform-data file found at ${DCAP_WORK_DIR}/platform-data-secrets.yaml"
        echo "Run step 'extract-platform-data' first."
        exit 1
    fi

    # Ensure the namespace exists on the connected cluster
    KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl create namespace "$DCAP_NS" \
        --dry-run=client -o yaml | KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl apply -f -

    echo "Applying platform-data secrets..."
    KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl apply \
        -f "${DCAP_WORK_DIR}/platform-data-secrets.yaml" -n "$DCAP_NS"
    echo ""
    echo "Platform-data secrets applied to Azure cluster."
    echo "The DCAP operator (Online mode) will now contact Intel PCS to register"
    echo "these platforms and obtain PCK certificates."
    echo ""
}

step_wait_for_pck() {
    echo "=== Step 3: Wait for Azure DCAP operator to create PCK secrets ==="
    echo "Kubeconfig: $KUBECONFIG_CONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo "Timeout:    ${PCK_WAIT_TIMEOUT}s"
    echo ""

    check_kubeconfig "Connected" "$KUBECONFIG_CONNECTED"

    local elapsed=0
    local interval=10

    while [ "$elapsed" -lt "$PCK_WAIT_TIMEOUT" ]; do
        local count
        count=$(KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl get secrets \
            -n "$DCAP_NS" -l fmspc --no-headers 2>/dev/null | wc -l)

        if [ "$count" -gt 0 ]; then
            echo ""
            echo "Found ${count} PCK secret(s):"
            KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl get secrets \
                -n "$DCAP_NS" -l fmspc --no-headers \
                -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc
            echo ""
            return 0
        fi

        printf "\rWaiting for PCK secrets... (%ds/%ds)" "$elapsed" "$PCK_WAIT_TIMEOUT"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    echo "ERROR: Timed out waiting for PCK secrets after ${PCK_WAIT_TIMEOUT}s."
    echo ""
    echo "Check the DCAP operator logs on the Azure cluster:"
    echo "  KUBECONFIG=${KUBECONFIG_CONNECTED} kubectl logs -n ${DCAP_NS} -l app=dcap-operator --tail=50"
    echo ""
    echo "Common issues:"
    echo "  - Azure DCAP operator is not in Online mode"
    echo "  - Intel PCS API is unreachable"
    echo "  - Platform-data secrets have invalid format"
    exit 1
}

step_extract_pck() {
    echo "=== Step 4: Extract PCK secrets from Azure cluster ==="
    echo "Kubeconfig: $KUBECONFIG_CONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo ""

    check_kubeconfig "Connected" "$KUBECONFIG_CONNECTED"
    mkdir -p "${DCAP_WORK_DIR}/pck-secrets"

    local count
    count=$(KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l fmspc --no-headers 2>/dev/null | wc -l)

    if [ "$count" -eq 0 ]; then
        echo "ERROR: No PCK secrets (labeled fmspc=*) found in ${DCAP_NS} on Azure cluster."
        echo "Run step 'wait-for-pck' first, or check the DCAP operator logs."
        exit 1
    fi

    echo "Found ${count} PCK secret(s). Extracting..."

    # Export each PCK secret individually, stripping cluster-specific metadata
    KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l fmspc -o yaml \
        | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /selfLink:/d' \
        > "${DCAP_WORK_DIR}/pck-secrets/pck-secrets.yaml"

    echo "Extracted to: ${DCAP_WORK_DIR}/pck-secrets/"
    echo ""
    echo "PCK secrets extracted:"
    KUBECONFIG="$KUBECONFIG_CONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l fmspc --no-headers \
        -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc
    echo ""
}

step_apply_pck() {
    echo "=== Step 5: Apply PCK secrets to disconnected cluster ==="
    echo "Kubeconfig: $KUBECONFIG_DISCONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo ""

    check_kubeconfig "Disconnected" "$KUBECONFIG_DISCONNECTED"

    if [ ! -d "${DCAP_WORK_DIR}/pck-secrets" ] || \
       [ -z "$(ls -A "${DCAP_WORK_DIR}/pck-secrets" 2>/dev/null)" ]; then
        echo "ERROR: No PCK secret files found in ${DCAP_WORK_DIR}/pck-secrets/"
        echo "Run step 'extract-pck' first."
        exit 1
    fi

    echo "Applying PCK secrets..."
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl apply \
        -f "${DCAP_WORK_DIR}/pck-secrets/" -n "$DCAP_NS"
    echo ""
    echo "PCK secrets applied to disconnected cluster."
    echo "QGS pods will detect and mount them automatically."
    echo ""
}

step_verify() {
    echo "=== Verify: DCAP provisioning status on disconnected cluster ==="
    echo "Kubeconfig: $KUBECONFIG_DISCONNECTED"
    echo "Namespace:  $DCAP_NS"
    echo ""

    check_kubeconfig "Disconnected" "$KUBECONFIG_DISCONNECTED"

    echo "--- QGS DaemonSet pods ---"
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get pods \
        -n "$DCAP_NS" -o wide 2>/dev/null || echo "  (no pods found)"
    echo ""

    echo "--- PCK secrets (labeled fmspc) ---"
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l fmspc --no-headers \
        -o custom-columns=NAME:.metadata.name,FMSPC:.metadata.labels.fmspc 2>/dev/null \
        || echo "  (no PCK secrets found)"
    echo ""

    echo "--- Platform-data secrets ---"
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get secrets \
        -n "$DCAP_NS" -l type=platform-data --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null \
        || echo "  (no platform-data secrets found)"
    echo ""

    echo "--- TdxQuoteGenerationService CR status ---"
    KUBECONFIG="$KUBECONFIG_DISCONNECTED" kubectl get tdxquotegenerationservice \
        -A -o wide 2>/dev/null || echo "  (no CR found or CRD not installed)"
    echo ""
}

# Main dispatch
STEP="${1:-}"

if [ -z "$STEP" ]; then
    usage
    exit 1
fi

case "$STEP" in
    extract-platform-data)
        step_extract_platform_data
        ;;
    apply-platform-data)
        step_apply_platform_data
        ;;
    wait-for-pck)
        step_wait_for_pck
        ;;
    extract-pck)
        step_extract_pck
        ;;
    apply-pck)
        step_apply_pck
        ;;
    verify)
        step_verify
        ;;
    all)
        step_extract_platform_data
        step_apply_platform_data
        step_wait_for_pck
        step_extract_pck
        step_apply_pck
        step_verify
        echo "=== DCAP offline provisioning complete ==="
        echo ""
        echo "PCK certificates have been provisioned on the disconnected cluster."
        echo "The QGS DaemonSet should now be able to serve TDX quotes."
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown step: $STEP"
        echo ""
        usage
        exit 1
        ;;
esac
