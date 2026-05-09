#!/bin/bash
# All-in-one build script for rvoffload emulator stack
# Builds: rvoffload (runtime + device), buildroot, linux-private, sifive_xm_accel, IREE
#
# Usage:
#   ./build.sh            -- build everything
#   ./build.sh --clean    -- remove all build artifacts (keeps cloned repos)
#   ./build.sh --cleanall -- remove build artifacts AND cloned repos
set -euo pipefail

# ─── Module system ─────────────────────────────────────────────────────────────
# Source the module init script so 'module' is available in non-interactive shells
source /etc/profile.d/modules.sh

# ─── Configuration ─────────────────────────────────────────────────────────────
BASE_DIR=$(pwd)
SHARE_DIR=$BASE_DIR/share

TOOLCHAIN_ROOT=/sifive/tools/freedom-tools/toolsuite-linux/riscv64-unknown-linux-gnu-toolsuite-5.0.0-x86_64-linux-redhat8
CROSS_COMPILE=riscv64-unknown-linux-gnu-

PATCHES_DIR=$BASE_DIR/patches

NPROC=$(nproc)

# ─── Helpers ───────────────────────────────────────────────────────────────────
step() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }
info() { echo "  → $*"; }

# ─── Clean ─────────────────────────────────────────────────────────────────────
do_clean() {
    local remove_repos="${1:-no}"
    step "Cleaning build artifacts"

    info "Removing share/..."
    rm -rf "$SHARE_DIR"

    info "Removing rvoffload build dirs..."
    rm -rf "$BASE_DIR/rvoffload/runtime/build-runtime-riscv"
    rm -rf "$BASE_DIR/rvoffload/device/build-device-riscv"

    info "Removing buildroot output/..."
    [ -d "$BASE_DIR/buildroot" ] && make -C "$BASE_DIR/buildroot" clean 2>/dev/null || true
    rm -rf "$BASE_DIR/buildroot/output"

    info "Removing linux-private build/..."
    rm -rf "$BASE_DIR/linux-private/build"

    info "Removing sifive_xm_accel bins/..."
    rm -rf "$BASE_DIR/sifive_xm_accel/bins"
    # Also clean kernel module objects inside each subdir
    for d in dev/sifive_service dev/sifive_service_emulator_sock \
              host/sifive_xm host/sifive_xm_emulator_sock; do
        rm -f "$BASE_DIR/sifive_xm_accel/$d"/*.o \
              "$BASE_DIR/sifive_xm_accel/$d"/*.ko \
              "$BASE_DIR/sifive_xm_accel/$d"/*.mod* \
              "$BASE_DIR/sifive_xm_accel/$d"/Module.symvers \
              "$BASE_DIR/sifive_xm_accel/$d"/modules.order 2>/dev/null || true
    done

    info "Removing IREE build dirs..."
    rm -rf "$BASE_DIR/iree-internal/build"
    rm -rf "$BASE_DIR/iree-internal/build-riscv-x392"

    if [ "$remove_repos" = "yes" ]; then
        step "Removing cloned repos"
        rm -rf "$BASE_DIR/rvoffload"
        rm -rf "$BASE_DIR/buildroot"
        rm -rf "$BASE_DIR/linux-private"
        rm -rf "$BASE_DIR/sifive_xm_accel"
        rm -rf "$BASE_DIR/iree-internal"
    fi

    step "Clean complete"
}

# ─── Argument parsing ──────────────────────────────────────────────────────────
case "${1:-}" in
    --clean)    do_clean no;  exit 0 ;;
    --cleanall) do_clean yes; exit 0 ;;
    "")         ;;  # normal build
    *) echo "Usage: $0 [--clean | --cleanall]"; exit 1 ;;
esac

# ─── Load modules ──────────────────────────────────────────────────────────────
step "Loading modules"
module load clang/17.0.4 ninja python/python/3.14.2
# cmake is the system binary at /usr/bin/cmake (3.26.5) — no module needed
module load sifive/freedom-tools/toolsuite-linux/5.0.0
export PATH="$TOOLCHAIN_ROOT/bin:$PATH"
info "CROSS_COMPILE: ${CROSS_COMPILE}"
info "$(${CROSS_COMPILE}gcc --version | head -1)"

# ─── Python venv (uv) ──────────────────────────────────────────────────────────
step "Python venv"
cd "$BASE_DIR"
info "Syncing Python venv (numpy + correct Python version)..."
uv sync
source "$BASE_DIR/.venv/bin/activate"
info "Python: $(python --version)"
info "numpy: $(python -c 'import numpy; print(numpy.__version__)')"

mkdir -p "$SHARE_DIR"

# ─── 1. rvoffload ──────────────────────────────────────────────────────────────
step "1/5  rvoffload"
cd "$BASE_DIR"

if [ ! -d rvoffload ]; then
    git clone git@github.com:sifive/rvoffload.git
    cd rvoffload
    git checkout dev/yunh/iree-demo-with-refactor-device 2>/dev/null \
        || info "Branch not found, staying on default"
    git submodule update --init
else
    info "rvoffload already cloned, skipping clone"
    cd rvoffload
fi

# Runtime (produces librvo.so for the device side)
# cmake is run from inside runtime/ so ../cmake resolves to rvoffload/cmake/
info "Configuring rvoffload runtime..."
cd "$BASE_DIR/rvoffload/runtime"
cmake -B build-runtime-riscv \
    -DRVO_LOG_DISABLE=ON \
    -DCMAKE_TOOLCHAIN_FILE=../cmake/riscv.toolchain.cmake \
    -DCMAKE_INSTALL_PREFIX=build-runtime-riscv/install \
    .
info "Building rvoffload runtime..."
cmake --build build-runtime-riscv -j"$NPROC" --target install
cp build-runtime-riscv/install/lib64/librvo.so "$SHARE_DIR/"
info "Copied librvo.so → share/"

# Device daemon (produces moray_daemon)
info "Configuring rvoffload device daemon..."
cd "$BASE_DIR/rvoffload/device"
cmake -B build-device-riscv \
    -DRVO_LOG_DISABLE=ON \
    -DCMAKE_TOOLCHAIN_FILE=../cmake/riscv.toolchain.cmake \
    -DCMAKE_INSTALL_PREFIX=build-device-riscv/install \
    .
info "Building rvoffload device daemon..."
cmake --build build-device-riscv -j"$NPROC" --target install
cp build-device-riscv/install/bin/moray_daemon "$SHARE_DIR/"
info "Copied moray_daemon → share/"

# ─── 2. buildroot ──────────────────────────────────────────────────────────────
step "2/5  buildroot"
cd "$BASE_DIR"

if [ ! -d buildroot ]; then
    git clone git@github.com:buildroot/buildroot.git
fi
cd buildroot

info "Applying qemu_riscv64_virt_defconfig..."
make qemu_riscv64_virt_defconfig

info "Patching .config (disable kernel build, enable CPIO rootfs, disable host QEMU)..."
# Disable buildroot's built-in Linux kernel build (we build our own)
sed -i 's/^BR2_LINUX_KERNEL=y/# BR2_LINUX_KERNEL is not set/' .config
sed -i '/^BR2_LINUX_KERNEL_/s/^/# /' .config

# Enable full CPIO rootfs (for initramfs in our kernel)
if grep -q "^# BR2_TARGET_ROOTFS_CPIO is not set" .config; then
    sed -i 's/^# BR2_TARGET_ROOTFS_CPIO is not set/BR2_TARGET_ROOTFS_CPIO=y/' .config
elif ! grep -q "^BR2_TARGET_ROOTFS_CPIO=y" .config; then
    echo "BR2_TARGET_ROOTFS_CPIO=y" >> .config
fi

if grep -q "^# BR2_TARGET_ROOTFS_CPIO_FULL is not set" .config; then
    sed -i 's/^# BR2_TARGET_ROOTFS_CPIO_FULL is not set/BR2_TARGET_ROOTFS_CPIO_FULL=y/' .config
elif ! grep -q "^BR2_TARGET_ROOTFS_CPIO_FULL=y" .config; then
    echo "BR2_TARGET_ROOTFS_CPIO_FULL=y" >> .config
fi

# Disable host QEMU build (not needed)
sed -i 's/^BR2_PACKAGE_HOST_QEMU=y/# BR2_PACKAGE_HOST_QEMU is not set/' .config

# Resolve any new/changed config symbols to their defaults (no prompts)
make olddefconfig

info "Building buildroot (this will take a while)..."
make -j"$NPROC"

ROOTFS_CPIO="$BASE_DIR/buildroot/output/images/rootfs.cpio"
info "rootfs.cpio: $ROOTFS_CPIO"

# ─── 3. linux-private ──────────────────────────────────────────────────────────
step "3/5  linux-private"
cd "$BASE_DIR"

if [ ! -d linux-private ]; then
    git clone git@github.com:sifive/linux-private.git -b dev/vincentc/v6.16-northstar
fi
cd linux-private

LINUX_BUILD="$BASE_DIR/linux-private/build"

info "Applying riscv defconfig (output → build/)..."
make ARCH=riscv O=build defconfig

info "Setting CONFIG_INITRAMFS_SOURCE..."
# Use kernel's scripts/config for safe, idempotent config edits
./scripts/config --file build/.config \
    --set-str CONFIG_INITRAMFS_SOURCE "$ROOTFS_CPIO"

# Resolve new config symbols to defaults — run twice to catch cascading dependencies
# introduced by CONFIG_INITRAMFS_SOURCE
info "Running olddefconfig to resolve new symbols non-interactively..."
make ARCH=riscv O=build olddefconfig
make ARCH=riscv O=build olddefconfig

info "Building kernel..."
# Redirect stdin from /dev/null so any remaining (NEW) kconfig prompts that appear
# during syncconfig at build time automatically accept the default instead of hanging
make ARCH=riscv O=build CROSS_COMPILE="$CROSS_COMPILE" -j20 </dev/null

cp "$LINUX_BUILD/arch/riscv/boot/Image" "$SHARE_DIR/"
info "Copied Image → share/"

# ─── 4. sifive_xm_accel ────────────────────────────────────────────────────────
step "4/5  sifive_xm_accel"
cd "$BASE_DIR"

if [ ! -d sifive_xm_accel ]; then
    git clone git@github.com:sifive/sifive_xm_accel.git
fi
cd sifive_xm_accel

info "Applying sifive_xm_sync_memcpy patch..."
if git apply --check "$PATCHES_DIR/sifive_xm_sync_memcpy.diff" 2>/dev/null; then
    git apply "$PATCHES_DIR/sifive_xm_sync_memcpy.diff"
else
    info "Patch already applied or does not apply cleanly, skipping"
fi

info "Building kernel modules..."
make HOST=riscv DEV=riscv \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KDIR="$LINUX_BUILD" \
    emulator_sock test

make HOST=riscv DEV=riscv \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KDIR="$LINUX_BUILD" \
    install

for ko in sifive_xm.ko sifive_xm_emu_sock_host.ko sifive_service.ko sifive_service_emu_sock_dev.ko; do
    cp "bins/modules/$ko" "$SHARE_DIR/"
    info "Copied $ko → share/"
done

# ─── 5. IREE ───────────────────────────────────────────────────────────────────
step "5/5  IREE"
cd "$BASE_DIR"

if [ ! -d iree-internal ]; then
    git clone git@github.com:sifive/iree-internal.git
    cd iree-internal
    git checkout dev/yunh/rvoffload-driver 2>/dev/null \
        || info "Branch dev/yunh/rvoffload-driver not found, staying on default"
    git submodule update --init
else
    info "iree-internal already cloned, skipping clone"
    cd iree-internal
fi

# ── 5a. IREE host build (compiler + tools) ──
info "Configuring IREE host build..."
cmake -G Ninja -B ./build/ -S . \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=./build/install \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_CXX_FLAGS="-stdlib=libc++ -Wno-align-mismatch" \
    -DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++ -Wno-align-mismatch -fuse-ld=lld" \
    -DIREE_ENABLE_RUNTIME_TRACING=ON \
    -DLLVM_ENABLE_LLD=ON \
    -DIREE_HAL_DRIVER_RVOFFLOAD_DEFAULT=ON \
    -DIREE_EXTERNAL_HAL_DRIVERS=rvoffload

info "Building IREE host (using ionice/nice to be a good citizen)..."
ionice -n 7 nice -n 19 cmake --build ./build/ --target install -j"$NPROC"

# ── 5b. IREE RISC-V runtime build ──
info "Configuring IREE RISC-V runtime (x392)..."
SIFIVE_TEST_TARGET=x392 cmake -G Ninja -B ./build-riscv-x392/ \
    -DCMAKE_TOOLCHAIN_FILE="./build_tools/cmake/riscv.toolchain.cmake" \
    -DIREE_HOST_BIN_DIR="./build/install/bin" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DRISCV_CPU=linux-riscv_64-sifive \
    -DRISCV_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT" \
    -DIREE_BUILD_COMPILER=OFF \
    -DIREE_ENABLE_CPUINFO=OFF \
    -DCMAKE_SKIP_RPATH=TRUE \
    -DIREE_HAL_DRIVER_RVOFFLOAD_DEFAULT=ON \
    -DIREE_EXTERNAL_HAL_DRIVERS=rvoffload \
    -DIREE_TARGET_BACKEND_CUDA=OFF \
    -DIREE_TARGET_BACKEND_METAL_SPIRV=OFF \
    -DIREE_TARGET_BACKEND_ROCM=OFF \
    -DIREE_TARGET_BACKEND_VULKAN_SPIRV=OFF \
    -DIREE_TARGET_BACKEND_WEBGPU_SPIRV=OFF \
    -DIREE_HAL_DRIVER_CUDA=OFF \
    -DIREE_HAL_DRIVER_HIP=OFF \
    -DIREE_HAL_DRIVER_METAL=OFF \
    -DIREE_HAL_DRIVER_VULKAN=OFF \
    -DIREE_BUILD_ALL_CHECK_TEST_MODULES=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_CXX_FLAGS="-Wno-c2y-extensions"

info "Building IREE RISC-V runtime..."
SIFIVE_TEST_TARGET=x392 VERBOSE=1 cmake --build ./build-riscv-x392/ -j32

cp ./build-riscv-x392/tools/iree-run-module "$SHARE_DIR/"
info "Copied iree-run-module → share/"

# ─── Done ──────────────────────────────────────────────────────────────────────
step "Build complete!"
echo "Files in $SHARE_DIR:"
ls -lh "$SHARE_DIR/"
