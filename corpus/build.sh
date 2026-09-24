#!/bin/sh

set -eu
cd "$(dirname "$0")"
zig=${ZIG:-zig}
out=out
mkdir -p "$out/arm" "$out/riscv" "$out/diag/arm" "$out/diag/riscv"

arm_flags="--target=thumb-freestanding-eabi -mcpu=cortex_m3"
riscv_flags="--target=riscv32-freestanding-none -mcpu=generic_rv32+m+c"
common="-Os -g0 -ffreestanding -nostdlib -fno-builtin -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Iport"

build() {
    arch=$1; into=$2; name=$3; shift 3
    case $arch in
        arm)   flags="$arm_flags";   port=port/arm ;;
        riscv) flags="$riscv_flags"; port=port/riscv ;;
    esac

    $zig cc $flags $common -T "$port/link.ld" -o "$into/$name.elf" "$port/start.S" port/port.c "$@"
}

for arch in arm riscv; do
    build "$arch" "$out/$arch" irq_storm   -DROUNDS=3200000 src/irq_storm.c
    build "$arch" "$out/$arch" ctxswitch   -DROUNDS=310000  src/ctxswitch.c
    build "$arch" "$out/$arch" sleep       -DROUNDS=310000  src/sleep.c
    build "$arch" "$out/$arch" recover     -DROUNDS=850000  src/recover.c
    build "$arch" "$out/$arch" semihost_io -DROUNDS=180000  src/semihost_io.c
    build "$arch" "$out/$arch" devpoll     -DROUNDS=550000  src/devpoll.c
    build "$arch" "$out/$arch" tickless    -DROUNDS=1050000 src/tickless.c
done
build arm   "$out/arm"   smc -DROUNDS=15000000 src/smc_arm.c
build riscv "$out/riscv" smc -DROUNDS=15000000 src/smc_riscv.c

build riscv "$out/riscv" pmp         -DROUNDS=275000 src/pmp.c
build riscv "$out/riscv" trap        -DROUNDS=85000  src/trap.c
build riscv "$out/riscv" intc_matrix -DROUNDS=180000 src/intc_matrix.c

for case in unaligned stack_overflow vector_thumb exc_return never_enabled readonly m4_on_m3; do
    build arm "$out/diag/arm" "$case" "diag/$case.c"
done
for case in readonly mtvec_loop intc_unrouted pmp_refused; do
    build riscv "$out/diag/riscv" "$case" "diag/$case.c"
done

ls -l "$out/arm" "$out/riscv" "$out/diag/arm" "$out/diag/riscv"
