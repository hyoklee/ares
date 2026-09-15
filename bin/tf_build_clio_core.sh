#!/bin/bash
# Build clio-core (hyoklee/core, dev) with the HDF5 VOL + VFD adapters against
# OUR HDF5 2.3.0 fork build, not conda's 1.14.
#
# The clio deps (zmq, yaml-cpp, sodium, cereal) live in the base conda env, so
# unlike every other build in this series conda must stay on the path. The one
# thing that must NOT come from conda is HDF5 -- hence HDF5_ROOT plus conda
# ordered last in CMAKE_PREFIX_PATH.
set -o pipefail

SRC=$HOME/src/hyoklee/core
PFX=/mnt/common/hyoklee/opt/clio-core
H5=/mnt/common/hyoklee/opt/hdf5-develop
MC3=$HOME/mc3
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
SPACK_CMAKE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/cmake-3.30.5-pq5ntgo32v2psq3zvmpdfhfy3dnerodh/bin

# Our HDF5 is parallel, so hdf5-config.cmake does find_dependency(MPI);
# MPICH must be discoverable or the configure fails at CMakeLists.txt:814.
export PATH=$SPACK_CMAKE:$MPI/bin:$MC3/bin:/usr/local/bin:/usr/bin:/bin
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export HDF5_ROOT=$H5
unset LD_LIBRARY_PATH

echo "=============== ENV ==============="
echo "cmake  : $(cmake --version | head -1)"
echo "source : $(cd $SRC && git log --oneline -1)"
echo "hdf5   : $(grep -aoE 'HDF5 Version: [0-9.]+' $H5/lib/libhdf5.so | head -1)"
echo "jobs   : $(nproc)"

echo
echo "=============== configure ==============="
rm -rf "$SRC/build-vol"
cmake -S "$SRC" -B "$SRC/build-vol" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PFX" \
  -DCMAKE_C_FLAGS="-I$H5/include" \
  -DCMAKE_CXX_FLAGS="-I$H5/include" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DCLIO_CORE_ENABLE_CONDA=ON \
  -DCLIO_CORE_ENABLE_CTE=ON \
  -DCLIO_CORE_ENABLE_CEREAL=ON \
  -DCLIO_CORE_ENABLE_CCACHE=ON \
  -DCLIO_CTE_ENABLE_HDF5_VOL=ON \
  -DCLIO_CTE_ENABLE_VFD=ON \
  -DCLIO_CORE_ENABLE_CAE=OFF \
  -DCLIO_CORE_ENABLE_CEE=OFF \
  -DCLIO_CORE_ENABLE_BENCHMARKS=OFF \
  -DMPI_C_COMPILER="$MPI/bin/mpicc" \
  -DMPI_CXX_COMPILER="$MPI/bin/mpicxx" \
  -DHDF5_ROOT="$H5" \
  -DHDF5_C_INCLUDE_DIR="$H5/include" \
  -DCMAKE_PREFIX_PATH="$H5;$MC3" \
  -DCMAKE_INSTALL_RPATH="$PFX/lib;$H5/lib;$MC3/lib;$MPI/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON 2>&1 | tail -30
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! CORE CONFIGURE FAILED"; exit 1; }

echo
echo "=============== build ==============="
cmake --build "$SRC/build-vol" -j "$(nproc)" 2>&1 | tail -25
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! CORE BUILD FAILED"; exit 1; }

cmake --install "$SRC/build-vol" 2>&1 | tail -3

echo
echo ">>> clio-core installed to $PFX"
ls "$PFX/lib"/libclio_hdf5_vol.so "$PFX/lib"/libclio_vfd.so 2>/dev/null
echo "--- which HDF5 does the VOL link? ---"
ldd "$PFX/lib/libclio_hdf5_vol.so" 2>/dev/null | grep -iE "hdf5|mpi"
echo "CORE-BUILD-DONE"
