#!/bin/bash
# Build HDF5 (develop, parallel) then netcdf-c from hyoklee's forks.
set -o pipefail

# --- clean environment: drop conda (~/mc3) and iowarp from PATH/LD_LIBRARY_PATH ---
SPACK_CMAKE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/cmake-3.30.5-pq5ntgo32v2psq3zvmpdfhfy3dnerodh/bin
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
export PATH=$SPACK_CMAKE:$MPI/bin:/usr/local/bin:/usr/bin:/bin
unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export CC=$MPI/bin/mpicc

H5_SRC=$HOME/src/hyoklee/hdf5
NC_SRC=$HOME/src/hyoklee/netcdf-c
H5_PFX=/mnt/common/hyoklee/opt/hdf5-develop
NC_PFX=/mnt/common/hyoklee/opt/netcdf-c
J=$(nproc)

echo "=============== ENV ==============="
echo "cmake : $(command -v cmake) $(cmake --version | head -1)"
echo "CC    : $CC"
$CC -show
echo "jobs  : $J"

echo
echo "=============== 1/2  HDF5 $(grep -m1 'define H5_VERS_MAJOR' $H5_SRC/src/H5public.h | awk '{print $3}').x  ==============="
rm -rf "$H5_SRC/build-par"
cmake -S "$H5_SRC" -B "$H5_SRC/build-par" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-include $(dirname $0)/tf_strlcpy_shim.h" \
  -DCMAKE_INSTALL_PREFIX="$H5_PFX" \
  -DBUILD_SHARED_LIBS=ON \
  -DHDF5_ENABLE_PARALLEL=ON \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_BUILD_FORTRAN=OFF \
  -DHDF5_BUILD_HL_LIB=ON \
  -DHDF5_BUILD_TOOLS=ON \
  -DHDF5_BUILD_EXAMPLES=OFF \
  -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
  -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
  -DBUILD_TESTING=OFF 2>&1 | tail -25
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! HDF5 CONFIGURE FAILED"; exit 1; }

cmake --build "$H5_SRC/build-par" -j "$J" 2>&1 | tail -20
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! HDF5 BUILD FAILED"; exit 1; }
cmake --install "$H5_SRC/build-par" 2>&1 | tail -3
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! HDF5 INSTALL FAILED"; exit 1; }
echo ">>> HDF5 installed to $H5_PFX"
"$H5_PFX/bin/h5cc" -showconfig 2>/dev/null | grep -iE "HDF5 Version|Parallel HDF5|zlib" | head -5

echo
echo "=============== 2/2  netcdf-c ==============="
export HDF5_ROOT="$H5_PFX"
export LD_LIBRARY_PATH="$H5_PFX/lib"
rm -rf "$NC_SRC/build-par"
cmake -S "$NC_SRC" -B "$NC_SRC/build-par" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-include $(dirname $0)/tf_strlcpy_shim.h" \
  -DCMAKE_INSTALL_PREFIX="$NC_PFX" \
  -DCMAKE_PREFIX_PATH="$H5_PFX" \
  -DHDF5_ROOT="$H5_PFX" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_PARALLEL4=ON \
  -DENABLE_HDF5=ON \
  -DENABLE_DAP=OFF \
  -DENABLE_BYTERANGE=OFF \
  -DENABLE_NCZARR=OFF \
  -DENABLE_PLUGINS=OFF \
  -DENABLE_TESTS=ON 2>&1 | tail -30
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NETCDF CONFIGURE FAILED"; exit 1; }

cmake --build "$NC_SRC/build-par" -j "$J" 2>&1 | tail -20
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NETCDF BUILD FAILED"; exit 1; }
cmake --install "$NC_SRC/build-par" 2>&1 | tail -3
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NETCDF INSTALL FAILED"; exit 1; }

echo ">>> netcdf-c installed to $NC_PFX"
"$NC_PFX/bin/nc-config" --version
"$NC_PFX/bin/nc-config" --has-hdf5 --has-parallel4 2>/dev/null
echo "ALL DONE"
