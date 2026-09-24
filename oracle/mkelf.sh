#!/bin/sh

set -eu
cd "$(dirname "$0")"
mkdir -p probe/out

case ${1:?arm or riscv} in
arm)
    zig cc --target=thumb-freestanding-eabi -mcpu=cortex_m3 -Os -g0 -nostdlib \
        -fno-sanitize=undefined -T probe/link.ld -o probe/out/probe_arm.elf \
        probe/start.S probe/probe_arm.c
    ;;
riscv)
    zig cc --target=riscv32-freestanding-none -mcpu=generic_rv32+m+c -Os -g0 -nostdlib \
        -fno-sanitize=undefined -T probe/link_riscv.ld -o probe/out/probe_riscv.elf \
        probe/start_riscv.S probe/probe_riscv.c
    ;;
*)
    echo "mkelf.sh: $1 is not an architecture" >&2
    exit 2
    ;;
esac
