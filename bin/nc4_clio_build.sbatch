#!/bin/bash
# Build the three components the NetCDF-4/CLIO comparison needs, on an ares
# compute node, from the checkouts already under /home/hyoklee/src:
#
#   HDF5      develop  /home/hyoklee/src/HDFGroup/hdf5
#   netCDF-C  main     /home/hyoklee/src/unidata/netcdf-c
#   clio-core dev      /home/hyoklee/src/iowarp/clio-core/dev/conda
#
# The build itself is delegated to hpf's nc4_clio_bench.sh (--stages build), the
# same driver the "NetCDF-4 CLIO Performance Benchmark" workflow uses, so the
# ares numbers stay comparable with the ones published from CI. Everything ares
# specific is environment, set below:
#
#   cmake      HDF5 develop needs >= 3.26 and the system cmake is 3.22, so the
#              conda one (4.2.3) is put on PATH through a one-entry symlink dir.
#              Prepending all of ~/mc3/bin instead would also hand the build
#              conda's compilers, zlib, and libhdf5 -- exactly what must not win.
#   deps       clio-core needs yaml-cpp/cereal/msgpack, which on ares live in the
#              conda base at ~/mc3. CLIO_CORE_ENABLE_CONDA is left OFF (that
#              option adds ~/mc3/include and ~/mc3/lib to *every* target, and
#              ~/mc3 ships its own libhdf5); CMAKE_PREFIX_PATH gets them found
#              without the include/link-dir sledgehammer. The driver appends the
#              ambient value after its own HDF5 prefix, so ours still wins.
#   ldd gate   the driver verifies each plugin resolves the HDF5 it just built.
#              That runs with the ambient LD_LIBRARY_PATH, so our lib dir goes
#              first there too.
#   node       ares-comp-08 is NOT interchangeable with the rest of the debug
#              partition: it has libelf1 but not libelf-dev, so clio-core's
#              pkg_check_modules(libelf REQUIRED) -- CLIO_CORE_ENABLE_ELF is ON
#              on Linux, as in CI -- fails there and only there (03..07 all
#              have it). It is excluded below. Runs are unaffected: the
#              *runtime* libelf.so.1 is present on every node.
#
# Usage: sbatch /home/hyoklee/src/hyoklee/ares/bin/nc4_clio_build.sbatch
#SBATCH --job-name=nc4build
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclude=ares-comp-08
#SBATCH --exclusive
#SBATCH --time=06:00:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_build_%j.log
set -euo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
HPF=/home/hyoklee/src/hyoklee/hpf
MC3=/home/hyoklee/mc3

mkdir -p "$WORK/toolbin"
ln -sf "$MC3/bin/cmake" "$WORK/toolbin/cmake"
export PATH="$WORK/toolbin:$PATH"
export CMAKE_PREFIX_PATH="$MC3"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== nc4 clio build: host=$(hostname) job=${SLURM_JOB_ID:-none} $(date -Is) ==="
cmake --version | head -1
gcc --version | head -1

bash "$HPF/.github/scripts/nc4_clio_bench.sh" \
  --work-dir    "$WORK" \
  --results-dir "$WORK/results" \
  --hdf5-src    /home/hyoklee/src/HDFGroup/hdf5 \
  --netcdf-src  /home/hyoklee/src/unidata/netcdf-c \
  --clio-src    /home/hyoklee/src/iowarp/clio-core/dev/conda \
  --stages      build \
  --jobs        "$(nproc)"

echo "=== build done $(date -Is) ==="
ls -l "$WORK/clio-build/bin/libclio_vfd.so" "$WORK/clio-build/bin/libclio_hdf5_vol.so"
find "$WORK/netcdf-build" -name tst_chunks3 -type f
echo "NC4_CLIO_BUILD_DONE"
