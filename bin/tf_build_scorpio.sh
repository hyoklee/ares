#!/bin/bash
# Build SCORPIO (E3SM's parallel I/O library) against the stack built in this session:
#   netcdf-fortran 4.6.5 / netcdf-c 4.10.2 / HDF5 2.3.0 (parallel) / MPICH 4.1.1
# PIO_ENABLE_TESTS=ON so tests/performance/pioperf is built.
set -o pipefail

SPACK_CMAKE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/cmake-3.30.5-pq5ntgo32v2psq3zvmpdfhfy3dnerodh/bin
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
H5_PFX=/mnt/common/hyoklee/opt/hdf5-develop
NC_PFX=/mnt/common/hyoklee/opt/netcdf-c
NF_PFX=/mnt/common/hyoklee/opt/netcdf-fortran
SP_PFX=/mnt/common/hyoklee/opt/scorpio
SP_SRC=/mnt/common/hyoklee/src/E3SM-Project/E3SM/externals/scorpio

export PATH=$SPACK_CMAKE:$NC_PFX/bin:$NF_PFX/bin:$MPI/bin:/usr/local/bin:/usr/bin:/bin
unset CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export CC=$MPI/bin/mpicc
export CXX=$MPI/bin/mpicxx
export FC=$MPI/bin/mpif90
export LD_LIBRARY_PATH=$H5_PFX/lib:$NC_PFX/lib:$NF_PFX/lib

echo "=============== ENV ==============="
echo "cmake : $(cmake --version | head -1)"
echo "CC/CXX/FC : mpicc / mpicxx / mpif90"
echo "netcdf-c  : $(nc-config --version)   parallel4=$(nc-config --has-parallel4)"
echo "netcdf-f  : $(nf-config --version)"
echo "scorpio   : $(cd $SP_SRC && git log --oneline -1 2>/dev/null || echo '(E3SM submodule)')"

echo
echo "=============== configure ==============="
rm -rf "$SP_SRC/build-par"
cmake -S "$SP_SRC" -B "$SP_SRC/build-par" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SP_PFX" \
  -DNetCDF_C_PATH="$NC_PFX" \
  -DNetCDF_Fortran_PATH="$NF_PFX" \
  -DHDF5_PATH="$H5_PFX" \
  -DWITH_NETCDF=ON \
  -DWITH_PNETCDF=OFF \
  -DWITH_HDF5=ON \
  -DWITH_ADIOS2=OFF \
  -DPIO_ENABLE_FORTRAN=ON \
  -DPIO_ENABLE_TESTS=ON \
  -DPIO_ENABLE_TOOLS=ON \
  -DPIO_ENABLE_DOC=OFF \
  -DPIO_ENABLE_EXAMPLES=OFF \
  -DCMAKE_INSTALL_RPATH="$SP_PFX/lib;$NF_PFX/lib;$NC_PFX/lib;$H5_PFX/lib;$MPI/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON 2>&1 | tail -35
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! SCORPIO CONFIGURE FAILED"; exit 1; }

echo
echo "=============== build ==============="
cmake --build "$SP_SRC/build-par" -j "$(nproc)" 2>&1 | tail -30
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "!!! SCORPIO BUILD FAILED"; exit 1; }

cmake --install "$SP_SRC/build-par" 2>&1 | tail -3
echo
echo ">>> SCORPIO installed to $SP_PFX"
echo "--- pioperf binary ---"
find "$SP_SRC/build-par" -name "pioperf*" -type f -perm -u+x | head -5
echo "ALL DONE"
