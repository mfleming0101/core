#!/usr/bin/env python3
"""Pin an oracle's architectural state, one hash per window of retired instructions, so that
`bench` can run the layer-4 lockstep without Sail or QEMU installed. Sail is the oracle for RV32,
QEMU `-M mps2-an385` for ARMv7-M.

The trace itself is not storable -- the corpus retires 49M RISC-V instructions, and a state record
per instruction is gigabytes -- which is the same problem `consumer sweep` solves for the decode
space, and the same answer: hash a window, and any disagreement localises to one window you then
replay in full.

The record hashed is `consumer trace`'s own line without its leading retired count: the program
counter, the flag word, then x0 to x31. Sail reports register *writes*, so the file is
reconstructed here. Both oracles name the program counter of the instruction they are about to run
where `trace` reports the one it arrives at, so record i takes the oracle's registers after step i
and its program counter from step i+1.

The system images add a field. Run with `--arch arm_sys`, QEMU is given `-d cpu,int` and its
exception events are folded into the record stream as one more column, so that a window hash covers
the exception model and not only the registers it leaves behind:

    <pc> <xpsr> <r0..r15> <sixteen zero words> <x>

`x` is four hex digits. Bit 15 is set where the instruction returned from an exception, which is
QEMU's `Exception return:` line. Bits 8 to 0 are the number of the exception the core entered
after it, zero where it entered none, which is QEMU's `...taking pending <state> exception N` line;
where entry chains within the one instruction -- a tail-chain after a return, or a fault derived
from the entry itself -- the number is the last one, because that is the handler the core runs.
Both events sit between the register dump of the instruction that caused them and the dump of the
instruction that follows, so they belong to the record the second dump completes.

Two of the eight ARM system images are pinned that way, and the other six cannot be. `irq_storm`,
`sleep`, `devpoll` and `tickless` drive the harness's `probe-timer`, which `mps2-an385` does not
map, so QEMU never runs them. `ctxswitch` runs, but its control flow is SysTick-driven and QEMU
counts SysTick off the host clock where this layer counts retired cycles, so two QEMU runs of it
disagree with each other -- 29312 exception events against 25358 over the same prefix -- and there
is nothing there to pin. `-icount shift=0` makes QEMU reproducible but pegs its tick to one
instruction a nanosecond, which is not this layer's cycle model either, so it would pin a file that
can only fail. `semihost_io` runs too, and QEMU retires its `bkpt 0xab` as an instruction of its own
and leaves r0 = 0xdeadbeef after SYS_WRITE0, where the serviced call retires nothing here and
answers zero. Semihosting 6.5 gives SYS_WRITE0 no return value, so neither side is wrong, and the
image adds what it got to a running total: dropping the extra record and rewriting r0 would still
leave the total, and every record after the first call carries the difference in a register.

`--arch riscv_sys` is the same idea on Sail: `--trace-csr --trace-exception` are added and the
record grows the three registers a trap writes and the same `x` column:

    <pc> <flags> <x0..x31> <mcause> <mepc> <mtval> <x>

The three are the CSR file as it stands after the instruction, so a handler's own write to mepc is
in them as much as the trap's is. `x` is four hex digits: bit 15 is set where the instruction
returned from a trap, which is Sail's `ret-ing from` line, and bit 14 where the core took one,
which is its `handling exc#` line. Nothing holds the code of the trap, because mcause is a column
of its own and an exception code of zero is a code like any other on this family.

`oracle/sail_rv32.json` faults a misaligned scalar load or store rather than performing it, because
the data bus of this part reaches memory single-byte, double-byte and 4-byte aligned, TRM 3.3.1. The
fault is the access fault of code 5 or 7, which is what the part's mcause table has, TRM Register
1.10 holding neither code 4 nor code 6; Zicclsm is off in the same file, since the misaligned
support it names is support this part does not have and Sail refuses the access fault while it is
on."""
import argparse, functools, pathlib, re, subprocess, sys

WINDOW = 1 << 16
PRIME = 0x100000001B3
SEED = 0xCBF29CE484222325
MASK = (1 << 64) - 1


def fold(hash, record):
    """FNV-1a over the record and a separator, which is how oracle/sweep_*.txt hashes a bucket."""
    for byte in record.encode():
        hash = ((hash ^ byte) * PRIME) & MASK
    return ((hash ^ 0xFF) * PRIME) & MASK
ENTRY = re.compile(r"^\.\.\.taking pending (?:\w+ )?exception (\d+)")
STEP = re.compile(r"^\[(\d+)\] \[[A-Z]+\]: 0x([0-9A-Fa-f]{8}) \(0x[0-9A-Fa-f]+\)")
WRITE = re.compile(r"^x(\d+) <- 0x([0-9A-Fa-f]+)")
CSR = re.compile(r"^CSR (mcause|mepc|mtval) \(0x[0-9A-F]+\) <- 0x([0-9A-Fa-f]+)")


def records(elf, limit, config, system=False):
    """Sail's steps, as `consumer trace` would have written them."""
    child = subprocess.Popen(
        ["sail_riscv_sim", "--rv32", "--config-override", config, "--inst-limit", str(limit + 1),
         "--trace-instr", "--trace-gpr"] + (["--trace-csr", "--trace-exception"] if system else []) +
        ["--trace-output", "/dev/stdout", str(elf)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1 << 20)
    regs = [0] * 32
    csrs = {"mcause": 0, "mepc": 0, "mtval": 0}
    pending = None
    event = 0
    for line in child.stdout:
        step = STEP.match(line)
        if step:
            # The previous step's record is only complete once the next program counter is known.
            if pending is not None:
                yield "%08x %08x %s%s" % (
                    int(step.group(2), 16), 0, " ".join("%08x" % r for r in regs),
                    " %08x %08x %08x %04x" % (csrs["mcause"], csrs["mepc"], csrs["mtval"], event)
                    if system else "")
            pending = True
            event = 0
            continue
        write = WRITE.match(line)
        if write and pending is not None:
            regs[int(write.group(1))] = int(write.group(2), 16) & 0xFFFFFFFF
        elif system:
            written = CSR.match(line)
            if written:
                csrs[written.group(1)] = int(written.group(2), 16) & 0xFFFFFFFF
            elif line.startswith("handling exc#"):
                event |= 0x4000
            elif line.startswith("ret-ing from"):
                event |= 0x8000
    child.stdout.close()
    child.wait()


def arm_records(elf, limit, _config, interrupts=False):
    """QEMU's per-instruction dump: four fixed-width register lines then XPSR, in that order. The
    dump precedes the instruction it belongs to, so the first is the reset state and is dropped.
    The semihosting a system image writes goes to a null chardev, because the log shares its
    stream."""
    child = subprocess.Popen(
        ["qemu-system-arm", "-M", "mps2-an385", "-cpu", "cortex-m3", "-kernel", str(elf),
         "-nographic", "-monitor", "none", "-serial", "none",
         "-accel", "tcg,one-insn-per-tb=on", "-d", "cpu,int" if interrupts else "cpu",
         "-D", "/dev/stdout"] +
        (["-semihosting", "-chardev", "null,id=semihosting",
          "-semihosting-config", "target=native,chardev=semihosting"] if interrupts else []),
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1 << 20)
    regs = [0] * 16
    tail = " ".join(["00000000"] * 16)
    emitted = 0
    seen = False
    event = 0
    for line in child.stdout:
        if line[0] == "R":
            for at in (0, 13, 26, 39):
                regs[int(line[at + 1:at + 3])] = int(line[at + 4:at + 12], 16)
            continue
        if interrupts and not line.startswith("XPSR="):
            entry = ENTRY.match(line)
            if entry:
                event = (event & 0x8000) | int(entry.group(1))
            elif line.startswith("Exception return:"):
                event |= 0x8000
            continue
        if not line.startswith("XPSR="):
            continue
        if seen:
            yield "%08x %08x %s %s%s" % (regs[15], int(line[5:13], 16),
                                         " ".join("%08x" % r for r in regs), tail,
                                         " %04x" % event if interrupts else "")
            emitted += 1
            if emitted >= limit:
                break
        seen = True
        event = 0
    child.kill()
    child.stdout.close()


ORACLES = {
    "riscv": ("sail_riscv_sim", records, "fw/riscv"),
    "riscv_sys": ("sail_riscv_sim", functools.partial(records, system=True), "out/riscv"),
    "arm": ("qemu-system-arm", arm_records, "fw/arm"),
    "arm_sys": ("qemu-system-arm", functools.partial(arm_records, interrupts=True), "out/arm"),
}


def version(tool):
    return subprocess.run([tool, "--version"], capture_output=True, text=True).stdout.splitlines()[0].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=sorted(ORACLES), action="append", help="default: both")
    ap.add_argument("--records", type=int, default=0, help="print raw records instead of hashes")
    ap.add_argument("--limit", type=int, default=20_000_000, help="cap retired instructions per image")
    ap.add_argument("--image", action="append", help="name from the manifest; default: every one of the arch")
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    config = str(root / "oracle/sail_rv32.json")
    manifest = (root / "corpus/manifest.zon").read_text()

    for arch in args.arch or ["arm", "riscv"]:
        tool, source, directory = ORACLES[arch]
        entries = re.findall(
            r'\.name = "([\w-]+)", \.arch = "\w+", \.path = "(%s/[^"]+)", \.retired = (\d+)' % directory, manifest)
        if args.image:
            entries = [e for e in entries if e[0] in args.image]
        if args.records:
            for record in source(root / "corpus" / entries[0][1], args.records, config):
                print(record)
            continue

        out = [f"# {tool} {version(tool)}"]
        for name, path, retired in entries:
            retired = min(int(retired), args.limit) if args.limit else int(retired)
            digest, windows, count = SEED, [], 0
            for record in source(root / "corpus" / path, retired, config):
                digest = fold(digest, record)
                count += 1
                if count % WINDOW == 0:
                    windows.append("%016x" % digest)
                    digest = SEED
            if count % WINDOW:
                windows.append("%016x" % digest)
            out.append(f"# {name} {count}")
            out += [f"{name} {i} {h}" for i, h in enumerate(windows)]
            print(f"{arch} {name}: {count} records, {len(windows)} windows", file=sys.stderr)
        (root / f"oracle/trace_{arch}.txt").write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    sys.exit(main())
