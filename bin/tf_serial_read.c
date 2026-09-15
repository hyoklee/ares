/* Serial netCDF-4 reader for the Terra Fusion clio VFD/VOL comparison.
 *
 * Deliberately SERIAL and deliberately C:
 *   - clio's VFD and VOL are built against a non-parallel HDF5 (Parallel: OFF)
 *     and link no MPI, so nf90_open_par / H5FD_MPIO cannot be used with them.
 *     Every measurement here is one process issuing one read.
 *   - the nc4-clio-work tree has netcdf-c but no netcdf-fortran.
 *
 * The adapter is selected entirely through environment (HDF5_DRIVER /
 * HDF5_VOL_CONNECTOR / HDF5_PLUGIN_PATH), so this binary is identical across
 * all three variants -- which is the point: the only thing that changes between
 * runs is which data path HDF5 loads underneath it.
 *
 * Usage:  tf_serial_read <file> <varname> [label]
 * Emits:  <label>,<var>,<MiB>,<seconds>,<MiB_s>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <netcdf.h>

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

#define CHK(call, what)                                                       \
    do {                                                                      \
        int _s = (call);                                                      \
        if (_s != NC_NOERR) {                                                 \
            fprintf(stderr, "FAIL [%s]: %s\n", (what), nc_strerror(_s));      \
            return 2;                                                         \
        }                                                                     \
    } while (0)

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <file> <varname> [label]\n", argv[0]);
        return 1;
    }
    const char *path  = argv[1];
    const char *vname = argv[2];
    const char *label = (argc > 3) ? argv[3] : "run";

    int ncid, varid, ndims, dimids[8];
    size_t len, nelem = 1;

    double t_open0 = now_s();
    CHK(nc_open(path, NC_NOWRITE, &ncid), "nc_open");
    double t_open = now_s() - t_open0;

    CHK(nc_inq_varid(ncid, vname, &varid), "nc_inq_varid");
    CHK(nc_inq_varndims(ncid, varid, &ndims), "nc_inq_varndims");
    if (ndims > 8) { fprintf(stderr, "FAIL: ndims %d > 8\n", ndims); return 2; }
    CHK(nc_inq_vardimid(ncid, varid, dimids), "nc_inq_vardimid");
    for (int i = 0; i < ndims; i++) {
        CHK(nc_inq_dimlen(ncid, dimids[i], &len), "nc_inq_dimlen");
        nelem *= len;
    }

    float *buf = malloc(nelem * sizeof(float));
    if (!buf) { fprintf(stderr, "FAIL: malloc %zu floats\n", nelem); return 2; }

    /* Whole-variable read: on a single-chunk variable this is exactly one
     * enormous request, which is the case the VFD's vector/coalescing path
     * is supposed to help with. */
    double t0 = now_s();
    CHK(nc_get_var_float(ncid, varid, buf), "nc_get_var_float");
    double t1 = now_s();

    /* Report BEFORE nc_close, deliberately. The clio VOL blocks in
     * clio_write_stamp -> PutBlobTask during file close (it issues a WRITE even
     * for an NC_NOWRITE open) and never returns, so anything printed after the
     * close is lost and the read time is unrecoverable. Printing here separates
     * "the read path works and only close hangs" from "nothing works". */
    double mib = (double)nelem * sizeof(float) / 1048576.0;
    double el  = t1 - t0;
    printf("%s,%s,%.2f,%.4f,%.1f,%.4f\n",
           label, vname, mib, el, mib / (el > 0 ? el : 1e-9), t_open);
    fflush(stdout);

    CHK(nc_close(ncid), "nc_close");
    fprintf(stderr, "%s,%s: nc_close returned\n", label, vname);

    free(buf);
    return 0;
}
