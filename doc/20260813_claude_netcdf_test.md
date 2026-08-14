You goal is to test ~/src/unidata/netcdf-c
like ~/src/hyoklee/hpf/.github/workflows/nc4-clio-benchmark.yml does.

Build and test 3 different netCDF-4 performances using `main` branch and

1. HDF5 `develop` branch on ~/src/hyoklee/HDFGroup/hdf5
2. HDF5 `develop` with clio-core `dev` VFD on ~/src/iowarp/clio-core/dev/conda
3. HDF5 `develop` with clio-core `dev` VOL on ~/src/iowarp/clio-core/dev/conda.

Compare performance of NetCDF-4 main branch's benchmark
using HDF5 `develop` branch,
HDF5 `develop` with clio-core VFD, and
HDF5 `develop` with clio-core VOL.

Generate a sample plot HTML page that shows 3 line graphs for
3 different netCDF-4 performances.
The plot should look like https://hyoklee.github.io/hpf/benchmarks_nc4_clio/plots.html.
Add the HTML page to ~/src/hyoklee/ares/doc/ directory.

Test everything locally using cloned clio-core, hdf5, and netcdf-c repos
under /home/hyoklee/src/ directory.

Use slurm job to run tests on compute node.

If everything works, compare the use of NVMe on compute node for
clio-core benchmarks.

Finally, increase double the dimension and chunk sizes
until clio-core test fails.
Measure the effect of increasing dimensions and chunk size.




