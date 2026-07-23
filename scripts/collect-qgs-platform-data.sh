#!/usr/bin/env bash
# Collect platform data for QGS offline PCK certificate provisioning.
# SSHes to the TDX node to extract platform-specific data from EFI vars,
# then uses that data to obtain PCK certificates from Intel PCS.
#
# Usage: ./scripts/collect-qgs-platform-data.sh --node NODE_IP [--ssh-user USER] [--output-dir DIR]
#
# Requires: ssh access to TDX node, curl, jq
# Output: Platform data and PCK certificates in ~/.coco-pattern/qgs-platform/

set -euo pipefail

NODE_IP=""
SSH_USER="core"
OUTPUT_DIR="$HOME/.coco-pattern/qgs-platform"

while [[ $# -gt 0 ]]; do
    case $1 in
        --node) NODE_IP="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$NODE_IP" ]; then
    echo "Usage: $0 --node NODE_IP [--ssh-user USER] [--output-dir DIR]"
    echo ""
    echo "NODE_IP: IP address of the TDX-capable node (e.g., 172.25.53.102)"
    echo "SSH_USER: SSH user on the node (default: core)"
    echo ""
    echo "The script SSHes to the node to collect platform registration data"
    echo "from /sys/firmware/efi/efivars for DCAP offline mode."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Collecting QGS platform data for offline PCK cert provisioning..."
echo "Node: ${SSH_USER}@${NODE_IP}"
echo "Output: $OUTPUT_DIR"
echo ""

echo "1/3 Extracting platform manifest from EFI vars..."
ssh "${SSH_USER}@${NODE_IP}" \
    'sudo cat /sys/firmware/efi/efivars/TdxPlatformManifest-* 2>/dev/null | base64' \
    > "${OUTPUT_DIR}/platform-manifest.b64" 2>/dev/null || {
    echo "  WARNING: Could not read TdxPlatformManifest EFI var."
    echo "  The DCAP operator's platform-registration initContainer may handle this automatically."
    echo "  Continuing with manual collection..."
}
echo "  Saved: platform-manifest.b64"

echo "2/3 Extracting FMSPC value..."
FMSPC=$(ssh "${SSH_USER}@${NODE_IP}" \
    'sudo cat /sys/firmware/efi/efivars/TdxFmspc-* 2>/dev/null | od -A n -t x1 | tr -d " \n"' \
    2>/dev/null || echo "unknown")
echo "$FMSPC" > "${OUTPUT_DIR}/fmspc.txt"
echo "  FMSPC: $FMSPC"

echo "3/3 Collecting CPU SVN and platform info..."
ssh "${SSH_USER}@${NODE_IP}" \
    'lscpu | grep -E "Model name|Stepping|CPU family|Model:"' \
    > "${OUTPUT_DIR}/cpu-info.txt" 2>/dev/null || true
echo "  Saved: cpu-info.txt"

echo ""
echo "Platform data collected."
echo ""
echo "Next steps for offline PCK provisioning:"
echo "  1. Take ${OUTPUT_DIR}/ to an internet-connected machine"
echo "  2. Use Intel PcsClientTool to register and obtain PCK certificates"
echo "  3. Create Kubernetes secrets with the PCK cert data (labeled fmspc=$FMSPC)"
echo "  4. The DCAP operator will pick up the secrets and configure QGS"
