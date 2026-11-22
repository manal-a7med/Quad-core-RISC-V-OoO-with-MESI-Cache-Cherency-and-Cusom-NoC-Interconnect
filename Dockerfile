# The exact tool versions the committed results were made with (Ubuntu 24.04:
# Icarus Verilog 12.0, Verilator 5.020, Yosys 0.33, riscv64-unknown-elf-gcc 13.2).
# Use it on any Linux (Ubuntu 22.04 included), macOS or Windows with Docker:
#   docker build -t quadcore .
#   docker run --rm -it -v "$PWD":/work -u "$(id -u):$(id -g)" quadcore make regress
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make python3 python3-matplotlib iverilog verilator yosys g++ \
        gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*'
WORKDIR /work
CMD ["bash"]
