#!/bin/bash
# Rebuild CAE's OMNI module (the wrp tool) WITH HDF5 support.
#
# Why standalone: the original build at /mnt/common/hyoklee/cae/build was
# configured against ~/spack packages (Hermes, HermesShm, OpenMPI 5.0.3) that no
# longer exist, and the top-level CMakeLists does find_package(Hermes REQUIRED)
# -- a name that predates the Hermes -> clio/CTE rename, so current clio-core
# does not satisfy it. omni/CMakeLists.txt carries its own project() and makes
# HERMES_LIBS conditional (USE_HERMES, default OFF), so the wrp tool builds
# without any of that.
#
# USE_MPI=ON because omni/format/hdf5_dataset_client.cc calls H5Pset_fapl_mpio
# and H5Pset_dxpl_mpio -- the reader is MPI-parallel, so it needs a parallel
# HDF5 and a matching MPI. Ours is HDF5 2.3.0 built with MPICH 4.1.1.
set -o pipefail

SRC=$HOME/cae/omni
BLD=$SRC/build-hdf5dbg
PFX=/mnt/common/hyoklee/opt/cae-omni
H5=/mnt/common/hyoklee/opt/hdf5-develop
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
MC3=$HOME/mc3
SPACK_CMAKE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/cmake-3.30.5-pq5ntgo32v2psq3zvmpdfhfy3dnerodh/bin

export PATH=$SPACK_CMAKE:$MPI/bin:$MC3/bin:/usr/local/bin:/usr/bin:/bin
export CC=$MPI/bin/mpicc CXX=$MPI/bin/mpicxx
export HDF5_ROOT=$H5
unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH

echo "=============== ENV ==============="
echo "cmake : $(cmake --version | head -1)"
echo "hdf5  : $(grep -aoE 'HDF5 Version: [0-9.]+' $H5/lib/libhdf5.so|head -1) $(grep -aoE 'Parallel HDF5: [A-Z]+' $H5/lib/libhdf5.so|head -1)"
echo "src   : $(cd $HOME/cae && git log --oneline -1 2>/dev/null || echo '(not a git repo)')"

echo
echo "=============== configure ==============="
rm -rf "$BLD"
cmake -S "$SRC" -B "$BLD" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_INSTALL_PREFIX="$PFX" \
  -DUSE_HDF5=ON \
  -DUSE_MPI=ON \
  -DUSE_HERMES=OFF \
  -DUSE_POCO=OFF \
  -DUSE_DATAHUB=OFF \
  -DUSE_AWS=OFF \
  -DHDF5_ROOT="$H5" \
  -DHDF5_PREFER_PARALLEL=ON \
  -DMPI_C_COMPILER="$MPI/bin/mpicc" \
  -DMPI_CXX_COMPILER="$MPI/bin/mpicxx" \
  -DCMAKE_PREFIX_PATH="$H5;$MC3" \
  -DCMAKE_INSTALL_RPATH="$H5/lib;$MC3/lib;$MPI/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON 2>&1 | tail -25
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! CONFIGURE FAILED"; exit 1; }

echo
echo "=============== build ==============="
cmake --build "$BLD" -j "$(nproc)" --target wrp 2>&1 | tail -25
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! BUILD FAILED"; exit 1; }

W=$(find "$BLD" -name wrp -type f -perm -u+x | head -1)
echo
echo ">>> wrp: $W"
echo "--- HDF5 actually linked? ---"
ldd "$W" 2>/dev/null | grep -icE "hdf5" | xargs -I{} echo "  hdf5 libs: {}"
nm -C "$W" 2>/dev/null | grep -cE "H5Dread|H5Dopen" | xargs -I{} echo "  H5Dread/H5Dopen symbols: {}"
echo "CAE-OMNI-BUILD-DONE"
