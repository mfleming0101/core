#!/bin/sh

set -eu
cd "$(dirname "$0")"
out=probe/out
sh ./mkelf.sh arm

qemu-system-arm -M mps2-an385 -cpu cortex-m3 -kernel "$out/probe_arm.elf" -nographic \
    -monitor none -serial none -semihosting -semihosting-config target=native 2>&1 >/dev/null |
    grep -E '^[a-z][a-z0-9_.]*=[0-9a-f]{8}$' > "$out/qemu.txt"
{ echo "# qemu-system-arm $(qemu-system-arm --version | head -1)"; cat "$out/qemu.txt"; } > probe_arm.txt

(cd .. && zig build build-machine-arm -Doptimize=ReleaseFast)
../zig-out/bin/machine-arm run probe/probe.zon "$out/probe_arm.elf" --semihosting |
    grep -E '^[a-z][a-z0-9_.]*=[0-9a-f]{8}$' > "$out/core.txt"

sh ./probecmp.sh arm "$out/core.txt"
