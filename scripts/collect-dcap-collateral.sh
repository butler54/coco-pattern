#!/usr/bin/env bash
# Collect DCAP collateral for Trustee RVPS (quote VERIFICATION).
#
# Downloads TCB info, QE identity, and PCK cert chain from Intel PCS API v4
# for offline use by the Trustee attestation service. This collateral is used
# for VERIFICATION of TDX quotes, NOT for PCK certificate provisioning.
#
# For PCK certificate provisioning (the DCAP operator offline workflow),
# use: make dcap-offline-provision
#
# Usage: ./scripts/collect-dcap-collateral.sh --fmspc FMSPC [--output-dir DIR]
#
# Requires: curl, jq
# Output: Files in ~/.coco-pattern/dcap-collateral/ (or --output-dir)
#
# NOTE: Intel DCAP collateral expires after ~30 days. Re-run periodically.

set -euo pipefail

FMSPC=""
OUTPUT_DIR="$HOME/.coco-pattern/dcap-collateral"

while [[ $# -gt 0 ]]; do
    case $1 in
        --fmspc) FMSPC="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --fmspc FMSPC [--output-dir DIR]"
            echo ""
            echo "Collect DCAP collateral for Trustee RVPS quote verification."
            echo "This is NOT for PCK cert provisioning (use 'make dcap-offline-provision' instead)."
            echo ""
            echo "  --fmspc FMSPC       Platform FMSPC value (required, hex string)"
            echo "                      Obtain from: kubectl get secrets -n intel-dcap-operator-system -l type=platform-data"
            echo "  --output-dir DIR    Output directory (default: ~/.coco-pattern/dcap-collateral)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$FMSPC" ]; then
    echo "ERROR: --fmspc is required."
    echo ""
    echo "The FMSPC value identifies your platform's processor family."
    echo "You can find it in the operator-created platform-data secrets:"
    echo "  kubectl get secrets -n intel-dcap-operator-system -l type=platform-data -o yaml"
    echo ""
    echo "Usage: $0 --fmspc FMSPC [--output-dir DIR]"
    exit 1
fi

INTEL_PCS_BASE="https://api.trustedservices.intel.com/sgx/certification/v4"

mkdir -p "$OUTPUT_DIR"

echo "Collecting DCAP collateral for Trustee RVPS quote verification..."
echo "FMSPC:  $FMSPC"
echo "Output: $OUTPUT_DIR"
echo ""

echo "1/3 Fetching TCB info for FMSPC=${FMSPC}..."
curl -fsSL "${INTEL_PCS_BASE}/tcb?fmspc=${FMSPC}" \
    -H "Accept: application/json" \
    -o "${OUTPUT_DIR}/tcb-info.json"
echo "  Saved: tcb-info.json"

echo "2/3 Fetching QE identity..."
curl -fsSL "${INTEL_PCS_BASE}/qe/identity" \
    -H "Accept: application/json" \
    -o "${OUTPUT_DIR}/qe-identity.json"
echo "  Saved: qe-identity.json"

echo "3/3 Fetching PCK CRL (certificate revocation list)..."
curl -fsSL "${INTEL_PCS_BASE}/pckcrl?ca=platform&encoding=pem" \
    -o "${OUTPUT_DIR}/pck-crl.pem"
echo "  Saved: pck-crl.pem"

echo ""
echo "Collateral collected successfully."
echo ""
echo "These files feed into Trustee RVPS for TDX quote verification."
echo "Next: load into RVPS reference values or configure collateralService endpoint."
echo ""
echo "NOTE: Intel DCAP collateral expires after ~30 days. Re-run periodically."
