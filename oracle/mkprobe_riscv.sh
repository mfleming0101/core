#!/bin/sh

set -eu
cd "$(dirname "$0")"
out=probe/out
qemu=${QEMU_RISCV32:-/opt/esp-qemu/bin/qemu-system-riscv32}
sh ./mkelf.sh riscv

env -u LD_LIBRARY_PATH "$qemu" -M esp32c3 -nographic -semihosting-config enable=on,target=native \
    -kernel "$out/probe_riscv.elf" </dev/null >/dev/null 2>"$out/qemu-raw.txt"
grep -v -e '^Not initializing SPI Flash$' -e '^Loading kernel at address ' "$out/qemu-raw.txt" > "$out/qemu.txt"
{ echo "# qemu-system-riscv32 $(env -u LD_LIBRARY_PATH "$qemu" --version | head -1), tag esp-develop-9.2.2-20260417"
  cat "$out/qemu.txt"; } > probe_riscv.txt

(cd .. && zig build build-machine-riscv -Doptimize=ReleaseFast)
../zig-out/bin/machine-riscv run probe/probe_riscv.zon "$out/probe_riscv.elf" --semihosting |
    grep -E '^[a-z][a-z0-9_.]*=[0-9a-f]{8}$' > "$out/core.txt"

sh ./probecmp.sh riscv "$out/core.txt"
