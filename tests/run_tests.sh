#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR/.."

echo "=========================================="
echo "    FrankenWP Test Suite (Incus/LXD)      "
echo "=========================================="

if ! command -v incus &>/dev/null && ! command -v lxc &>/dev/null; then
    echo "❌ Neither 'incus' nor 'lxc' command found. Please install Incus/LXD."
    exit 1
fi
CMD="incus"
command -v incus &>/dev/null || CMD="lxc"

preserve=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preserve|-p) preserve=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

targets=(
    "fwp-deb12|images:debian/12"
    "fwp-deb13|images:debian/13"
    "fwp-ubu24|images:ubuntu/24.04"
)

declare -A pids
exit_code=0
mkdir -p "$DIR/logs"

run_test_for_target() {
    local name=$1
    local image=$2
    local logfile="$DIR/logs/fwp_test_${name}.log"
    echo "[$name] Starting test with image $image..." > "$logfile"
    
    # Ensure a clean slate
    $CMD delete -f "$name" &>/dev/null || true

    # Launch container with nesting and privileges so sysctl and ufw have low-level access
    echo "[$name] Launching container..." >> "$logfile"
    if ! $CMD launch "$image" "$name" -c security.nesting=true -c security.privileged=true -c limits.cpu=4 -c limits.memory=8GB >> "$logfile" 2>&1; then
        echo "❌ [$name] Launch failed! Logs dumped below:"
        cat "$logfile"
        return 1
    fi

    # Wait for the system to boot properly
    echo "[$name] Waiting for system to boot..." >> "$logfile"
    sleep 5
    $CMD exec "$name" -- bash -c 'for i in {1..30}; do systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 1; done'

    # Push the current repository to the container safely without copying tests
    echo "[$name] Copying source code..." >> "$logfile"
    $CMD exec "$name" -- mkdir -p /opt/fwp-src
    tar -cf - --exclude='./tests' --exclude='./.git' . | $CMD exec "$name" -- tar -xf - -C /opt/fwp-src
    
    # Execute the installation
    echo "[$name] Running install.sh..." >> "$logfile"
    $CMD exec "$name" -- sed -i 's/set -euo pipefail/set -exuo pipefail/' /opt/fwp-src/install.sh
    if ! $CMD exec "$name" -- bash -c 'cd /opt/fwp-src && ./install.sh --mariadb' >> "$logfile" 2>&1; then
        echo "❌ [$name] install.sh failed! Check $logfile"
        tail -n 50 "$logfile"
        return 1
    fi

    # Test full site creation
    echo "[$name] Testing site creation..." >> "$logfile"
    if ! $CMD exec "$name" -- bash -c 'fwp site create test.local --title="Test Site" --skip-ssl --no-www' >> "$logfile" 2>&1; then
        echo "❌ [$name] fwp site create failed! Check $logfile"
        tail -n 50 "$logfile"
        return 1
    fi
    
    # Validate main services
    echo "[$name] Verifying services..." >> "$logfile"
    if ! $CMD exec "$name" -- bash -c 'systemctl is-active frankenphp && systemctl is-active mysql' >> "$logfile" 2>&1; then
        echo "❌ [$name] Essential services failed to activate!"
        tail -n 50 "$logfile"
        return 1
    fi

    echo "✅ [$name] All tests passed!"
    return 0
}

echo "=> Dispatching tests..."
for target_str in "${targets[@]}"; do
    IFS="|" read -r c_name c_image <<< "$target_str"
    run_test_for_target "$c_name" "$c_image" &
    pids[$c_name]=$!
done

# Collect exit codes
for target_str in "${targets[@]}"; do
    IFS="|" read -r c_name c_image <<< "$target_str"
    if ! wait "${pids[$c_name]}"; then
        exit_code=1
    fi
done

if [ "$preserve" = false ]; then
    echo "=> Tearing down containers..."
    for target_str in "${targets[@]}"; do
        IFS="|" read -r c_name c_image <<< "$target_str"
        $CMD delete -f "$c_name" &>/dev/null || true
    done
else
    echo "=> Preserving containers for manual inspection."
fi

echo "=========================================="
if [ $exit_code -eq 0 ]; then
    echo "🎉 SUCCESS: All environments passed!"
else
    echo "💥 FAILURE: Some environments failed the tests."
fi
echo "=========================================="

exit $exit_code
