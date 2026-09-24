#!/bin/sh

set -eu

here=$(dirname "$0")
case ${1:?arm or riscv} in
arm) register=$here/arm_divergences.txt ;;
riscv) register=$here/intc_divergences.txt ;;
*) echo "probecmp.sh: $1 is not an architecture" >&2; exit 2 ;;
esac
awk -v register="$register" -v pin="$here/probe_$1.txt" '
function value(field,   at) { at = index(field, "="); return substr(field, at + 1) }
BEGIN {
    while ((getline line < register) > 0) {
        sub(/#.*/, "", line)
        fields = split(line, field, " ")
        if (fields < 4) continue
        name = field[1]
        core[name] = value(field[3])
        for (i = 4; i < fields; i++) {
            if (field[i] ~ /^fixed=/) fix[name] = value(field[i])
            if (field[i] ~ /:$/) { side[name] = tolower(field[i + 1]); break }
        }
        sub(/,$/, "", side[name])
    }
    while ((getline line < pin) > 0)
        if (line ~ /^[a-z][a-z0-9_.]*=[0-9a-f]{8}$/) { order[++total] = substr(line, 1, index(line, "=") - 1); want[order[total]] = value(line) }
}
$0 ~ /^[a-z][a-z0-9_.]*=[0-9a-f]{8}$/ { got[substr($0, 1, index($0, "=") - 1)] = value($0) }
END {
    for (i = 1; i <= total; i++) {
        name = order[i]
        if (!(name in side)) {
            if (got[name] == want[name]) { agree++; continue }
        } else if (side[name] == "qemu") {
            if (got[name] == want[name] || ((name in fix) && got[name] == fix[name])) { fixed++; continue }
            if (got[name] == core[name]) { listed++; continue }
        } else if (got[name] == core[name]) { listed++; continue }
        printf "FAIL  %s is %s, %s pins %s and %s %s\n", name, (name in got) ? got[name] : "absent", pin, want[name], register, (name in side) ? side[name] " " core[name] : "nothing"  > "/dev/stderr"
        failed++
    }
    printf "agree=%d fixed=%d known=%d total=%d\n", agree, fixed, listed, total
    exit failed != 0
}' "${2:?the output of a machine running the probe}"
