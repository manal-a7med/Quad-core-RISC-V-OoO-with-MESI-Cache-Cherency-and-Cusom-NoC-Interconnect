#!/bin/sh
# setup_ubuntu.sh - install every tool this repository needs on Ubuntu 22.04
# or 24.04 (also inside WSL). Run it from the repository: sh scripts/setup_ubuntu.sh
#
#   Ubuntu 24.04: everything comes from apt (Verilator 5.020).
#   Ubuntu 22.04: apt has Verilator 4.038, which is too old for the benchmarks
#                 (they need Verilator 5 for --binary and --timing), so
#                 Verilator 5.020 is built from source into /usr/local
#                 (about 10 to 20 minutes, once).
#
# Options (environment variables):
#   VERILATOR_VERSION=v5.020   the Verilator release to build when apt's is older than 5
#   SKIP_VERILATOR=1           do not build Verilator (everything except the
#                              benchmarks, lint and scaling still works)
set -e
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
. /etc/os-release
echo "setup: $PRETTY_NAME"

$SUDO apt-get update
$SUDO apt-get install -y git make python3 python3-matplotlib iverilog yosys \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf

# Verilator 5 from apt when it has one, else from source
apt_vl=$(apt-cache policy verilator | sed -n 's/^ *Candidate: *//p')
have_vl=$(verilator --version 2>/dev/null | awk '{print $2}')
case "$have_vl" in
  5.*|6.*) echo "setup: Verilator $have_vl already installed" ;;
  *)
    case "$apt_vl" in
      5.*|6.*) $SUDO apt-get install -y verilator ;;
      *)
        if [ -n "$SKIP_VERILATOR" ]; then
            echo "setup: SKIP_VERILATOR set; make bench, lint and scaling need Verilator 5"
        else
            V=${VERILATOR_VERSION:-v5.020}
            echo "setup: apt has Verilator $apt_vl; building Verilator $V from source"
            $SUDO apt-get install -y g++ autoconf flex bison help2man perl libfl-dev zlib1g-dev ccache
            src=$(mktemp -d)
            git clone --depth 1 -b "$V" https://github.com/verilator/verilator "$src/verilator"
            (cd "$src/verilator" && autoconf && ./configure --prefix=/usr/local && make -j"$(nproc)" && $SUDO make install)
            rm -rf "$src"
            hash -r 2>/dev/null || true
        fi ;;
    esac ;;
esac

# riscv-tests (git submodule) if this is a clone made without --recurse-submodules
if [ -d .git ] && [ ! -e third_party/riscv-tests/isa ]; then
    git submodule update --init --recursive
fi

echo
echo "setup: installed versions"
iverilog -V 2>&1 | head -1
verilator --version 2>/dev/null || echo "Verilator: not installed"
yosys -V
riscv64-unknown-elf-gcc --version | head -1
python3 --version
echo
echo "Next: make regress   (all correctness checks, about an hour)"
