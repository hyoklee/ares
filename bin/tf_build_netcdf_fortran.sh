#!/bin/bash
# Build netcdf-fortran against the freshly built netcdf-c 4.10.2 / HDF5 2.3.0 (parallel).
set -o pipefail

SPACK_CMAKE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/cmake-3.30.5-pq5ntgo32v2psq3zvmpdfhfy3dnerodh/bin
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
H5_PFX=/mnt/common/hyoklee/opt/hdf5-develop
NC_PFX=/mnt/common/hyoklee/opt/netcdf-c
NF_PFX=/mnt/common/hyoklee/opt/netcdf-fortran
NF_SRC=$HOME/src/unidata/netcdf-fortran

# clean env: no conda, no iowarp
export PATH=$SPACK_CMAKE:$NC_PFX/bin:$MPI/bin:/usr/local/bin:/usr/bin:/bin
unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export CC=$MPI/bin/mpicc
export FC=$MPI/bin/mpif90
export F77=$MPI/bin/mpif77
export LD_LIBRARY_PATH=$H5_PFX/lib:$NC_PFX/lib

echo "=============== ENV ==============="
echo "cmake     : $(cmake --version | head -1)"
echo "CC / FC   : $CC / $FC"
$FC --version | head -1
echo "nc-config : $(nc-config --version)  parallel4=$(nc-config --has-parallel4)"
echo "netcdf-f  : $(cd "$NF_SRC" && git log --oneline -1)"

echo
echo "=============== configure ==============="
rm -rf "$NF_SRC/build-par"
cmake -S "$NF_SRC" -B "$NF_SRC/build-par" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$NF_PFX" \
  -DCMAKE_PREFIX_PATH="$NC_PFX;$H5_PFX" \
  -DnetCDF_ROOT="$NC_PFX" \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_RPATH="$NF_PFX/lib;$NC_PFX/lib;$H5_PFX/lib;$MPI/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DENABLE_TESTS=ON 2>&1 | tail -30
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NF CONFIGURE FAILED"; exit 1; }

echo
echo "=============== build ==============="
cmake --build "$NF_SRC/build-par" -j "$(nproc)" 2>&1 | tail -25
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NF BUILD FAILED"; exit 1; }

cmake --install "$NF_SRC/build-par" 2>&1 | tail -3
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! NF INSTALL FAILED"; exit 1; }

echo
echo ">>> netcdf-fortran installed to $NF_PFX"
"$NF_PFX/bin/nf-config" --version 2>&1 | head -1
"$NF_PFX/bin/nf-config" --has-parallel 2>&1 | head -1
echo "--- unresolved libs in libnetcdff.so ---"
ldd "$NF_PFX/lib/libnetcdff.so" | grep -c "not found"
echo "ALL DONE"
