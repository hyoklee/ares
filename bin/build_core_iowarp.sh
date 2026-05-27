#!/bin/bash
# Build core.iowarp (upstream iowarp/clio-core v2.0.0) POSIX adapter + runtime,
# mirroring the working ~/core build (ELF=ON, MPI from iowarp-build, g++).
# Clean build dir (build_hk) to avoid the existing build's stale system-MPI
# cache. Installs to ~/core.iowarp/install so run_case6.sbatch can point
# CORE_INSTALL at it.
set -e
. /home/hyoklee/mc3/etc/profile.d/conda.sh
export PATH="/home/hyoklee/mc3/bin:$PATH"
export CONDA_PREFIX="/home/hyoklee/mc3"
export no_proxy='localhost,127.0.0.1,.localdomain'

IOW_ENV=/home/hyoklee/mc3/envs/iowarp-build
# Put the iowarp-build MPI first so FindMPI uses it, not the broken system MPI.
export PATH="$IOW_ENV/bin:$PATH"

CMAKE=/home/hyoklee/mc3/bin/cmake
SRC=/home/hyoklee/core.iowarp
BUILD=$SRC/build_hk
PREFIX=$SRC/install
SITE=$(hostname | cut -d'.' -f1)

rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"
echo "=== configure (clean): ELF=ON, MPI=iowarp-build, prefix=$PREFIX ==="
"$CMAKE" "$SRC" \
  -DSITE="$SITE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/gcc \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
  -DWRP_CORE_ENABLE_CONDA=ON \
  -DCLIO_CORE_ENABLE_ELF=ON \
  -DCLIO_CTE_ENABLE_POSIX_ADAPTER=ON \
  -DCLIO_CORE_ENABLE_MPI=ON \
  -DMPI_C_COMPILER="$IOW_ENV/bin/mpicc" \
  -DMPI_CXX_COMPILER="$IOW_ENV/bin/mpicxx" \
  -DMPIEXEC_EXECUTABLE="$IOW_ENV/bin/mpiexec" \
  -DCLIO_CORE_ENABLE_BENCHMARKS=OFF \
  -DCLIO_CORE_ENABLE_TESTS=OFF \
  -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
  -DCLIO_CORE_ENABLE_PYTHON=OFF \
  -DCLIO_CORE_ENABLE_COVERAGE=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"

echo "=== build ==="
"$CMAKE" --build "$BUILD" -j 40

echo "=== install ==="
"$CMAKE" --install "$BUILD"

echo "=== verify ==="
ls -la "$PREFIX/lib/libclio_cte_posix.so" "$PREFIX/bin/clio_run"
echo "BUILD_CORE_IOWARP_DONE"
