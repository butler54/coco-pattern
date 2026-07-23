#!/usr/bin/env bash
# Collect DCAP collateral for Trustee RVPS (quote VERIFICATION).
# Downloads TCB info, QE identity, and PCK cert chain from Intel PCS
# for offline use by the Trustee attestation service.
#
# Usage: ./scripts/collect-dcap-collateral.sh [--output-dir DIR]
#
# Requires: curl, jq
# Output: Files in ~/.coco-pattern/dcap-collateral/ (or --output-dir)

set -euo pipefail

OUTPUT_DIR="${1:---output-dir}"
if [ "$OUTPUT_DIR" = "--output-dir" ]; then
    shift 2>/dev/null || true
    OUTPUT_DIR="${1:-$HOME/.coco-pattern/dcap-collateral}"
fi

INTEL_PCS_BASE="https://api.trustedservices.intel.com/sgx/certification/v4"

mkdir -p "$OUTPUT_DIR"

echo "Collecting DCAP collateral for Trustee RVPS verification..."
echo "Output: $OUTPUT_DIR"
echo ""

echo "1/3 Fetching TCB info..."
curl -fsSL "${INTEL_PCS_BASE}/tcb?fmspc=00906ED50000" \
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
echo "Collateral collected. These files feed into Trustee RVPS for quote verification."
echo "Next: load into RVPS reference values or configure collateralService endpoint."
echo ""
echo "NOTE: Intel DCAP collateral expires after ~30 days. Re-run periodically."
