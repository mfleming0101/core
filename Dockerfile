FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS zig
ARG TARGETARCH
RUN sed -i 's|^URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/20260920T000000Z|; \
            s|^URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/20260920T000000Z|' \
        /etc/apt/sources.list.d/debian.sources \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/snapshot \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git perl xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
        amd64) arch=x86_64;  sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
        arm64) arch=aarch64; sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
    esac \
    && curl -sSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-$arch-linux-0.16.0.tar.xz" \
    && echo "$sum  /tmp/zig.tar.xz" | sha256sum -c \
    && tar -C /opt -xJf /tmp/zig.tar.xz && rm /tmp/zig.tar.xz \
    && ln -s "/opt/zig-$arch-linux-0.16.0/zig" /usr/local/bin/zig

FROM zig AS tier1
RUN git clone --depth 1 --branch v0.3.1 https://github.com/mfleming0101/isa.git /isa \
    && test "$(git -C /isa rev-parse HEAD)" = b574ea9e8aefab3922dc49b73b3b7564dee714db \
    && sh /isa/corpus/build.sh

FROM zig
WORKDIR /core
COPY build.zig build.zig.zon ./
COPY bench/run.zig bench/
COPY bench/harness/ bench/harness/
COPY bench/arm/ bench/arm/
COPY bench/riscv/ bench/riscv/
COPY bench/nullisa/ bench/nullisa/
COPY corpus/ corpus/
COPY oracle/ oracle/
COPY src/ src/
COPY --from=tier1 /isa/corpus/out/ corpus/fw/
RUN sh corpus/build.sh
CMD ["sh", "-ec", "zig build harness && zig build metrics"]
