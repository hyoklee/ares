/* The discrepancy pipeline's READ PATTERN, at the HDF5 C level, so it can be
 * run through the clio VOL.
 *
 * bin/tf_sources.py cannot be used directly: its netCDF4 comes from a pip
 * wheel that bundles its own HDF5 1.14, and the clio VOL is built against the
 * HDF5 2.3.0 fork. A connector cannot be loaded into a different libhdf5, so
 * the Python path is native-only by construction. This reproduces what that
 * script actually asks the file for, linked against the HDF5 the VOL targets.
 *
 * Three phases, matching tf_sources.py:
 *
 *   MODIS   EV_1KM_Emissive[band,:,:] over every granule that has _1KM.
 *           This is a PARTIAL read -- one band of sixteen -- which is the case
 *           1fc47b3d ("stop materialising the whole dataset on every partial
 *           read") changed, so it is the phase most likely to move.
 *   MISR    AN/Data_Fields/Red_Radiance in full. One 755 MB chunk, so the
 *           whole chunk is inflated however little is wanted; part 3 measured
 *           this at 69% of the pipeline's read time.
 *   GEO     MODIS _1KM/Geolocation Latitude+Longitude per granule. Many
 *           medium reads, the case ab28d5e2 ("skip the per-dataset hit test on
 *           a file whose tier is known empty") addresses.
 *
 * Reports wall time and bytes per phase. Run it twice -- once with
 * HDF5_VOL_CONNECTOR unset, once set -- and compare within the session, never
 * across sessions: the host is shared and absolute numbers drift.
 *
 * Build:
 *   h5cc -O2 -o tf_vol_discrepancy_read tf_vol_discrepancy_read.c
 */
#include <hdf5.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}

static const char *DEFAULT_FILE =
    "/mnt/common/datasets-staging/"
    "TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5";

/* Collect the MODIS granule names that carry a _1KM group. */
static herr_t collect(hid_t gid, const char *name, const H5L_info2_t *info,
                      void *op) {
  (void)info;
  char ***lp = (char ***)op;
  char path[512];
  snprintf(path, sizeof path, "%s/_1KM", name);
  if (H5Lexists(gid, path, H5P_DEFAULT) > 0) {
    size_t n = 0;
    while ((*lp)[n]) n++;
    (*lp)[n] = strdup(name);
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *path = (argc > 1) ? argv[1] : DEFAULT_FILE;
  int band = (argc > 2) ? atoi(argv[2]) : 10; /* band 31, part 11's choice */
  const char *vol = getenv("HDF5_VOL_CONNECTOR");
  printf("# file  %s\n# band index %d\n# HDF5_VOL_CONNECTOR=%s\n",
         path, band, vol ? vol : "(unset, native)");

  double t_open = now();
  hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
  if (f < 0) { fprintf(stderr, "open failed\n"); return 1; }
  t_open = now() - t_open;

  char **gran = calloc(4096, sizeof(char *));
  hid_t modis = H5Gopen2(f, "/MODIS", H5P_DEFAULT);
  hsize_t idx = 0;
  H5Literate2(modis, H5_INDEX_NAME, H5_ITER_INC, &idx, collect, &gran);
  H5Gclose(modis);
  size_t ngran = 0;
  while (gran[ngran]) ngran++;
  printf("# %zu MODIS granules with _1KM\n", ngran);

  /* ---- phase 1: MODIS one band per granule (PARTIAL read) ---------------- */
  double t = now();
  double mbytes = 0;
  for (size_t i = 0; i < ngran; i++) {
    char dp[768];
    snprintf(dp, sizeof dp, "/MODIS/%s/_1KM/Data_Fields/EV_1KM_Emissive",
             gran[i]);
    hid_t d = H5Dopen2(f, dp, H5P_DEFAULT);
    if (d < 0) continue;
    hid_t sp = H5Dget_space(d);
    hsize_t dims[3];
    H5Sget_simple_extent_dims(sp, dims, NULL);
    hsize_t start[3] = {(hsize_t)band, 0, 0};
    hsize_t count[3] = {1, dims[1], dims[2]};
    H5Sselect_hyperslab(sp, H5S_SELECT_SET, start, NULL, count, NULL);
    hid_t ms = H5Screate_simple(2, &dims[1], NULL);
    size_t n = (size_t)dims[1] * dims[2];
    float *buf = malloc(n * sizeof(float));
    H5Dread(d, H5T_NATIVE_FLOAT, ms, sp, H5P_DEFAULT, buf);
    mbytes += (double)n * sizeof(float);
    free(buf);
    H5Sclose(ms); H5Sclose(sp); H5Dclose(d);
  }
  double t_modis = now() - t;

  /* ---- phase 2: MISR Red_Radiance in full (one 755 MB chunk) ------------- */
  t = now();
  double rbytes = 0;
  hid_t d = H5Dopen2(f, "/MISR/AN/Data_Fields/Red_Radiance", H5P_DEFAULT);
  if (d >= 0) {
    hid_t sp = H5Dget_space(d);
    hsize_t dims[3];
    int nd = H5Sget_simple_extent_dims(sp, dims, NULL);
    size_t n = 1;
    for (int k = 0; k < nd; k++) n *= (size_t)dims[k];
    float *buf = malloc(n * sizeof(float));
    if (buf) {
      H5Dread(d, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
      rbytes = (double)n * sizeof(float);
      free(buf);
    }
    H5Sclose(sp); H5Dclose(d);
  }
  double t_misr = now() - t;

  /* ---- phase 3: MODIS geolocation, two datasets per granule -------------- */
  t = now();
  double gbytes = 0;
  for (size_t i = 0; i < ngran; i++) {
    const char *which[2] = {"Latitude", "Longitude"};
    for (int w = 0; w < 2; w++) {
      char dp[768];
      snprintf(dp, sizeof dp, "/MODIS/%s/_1KM/Geolocation/%s", gran[i],
               which[w]);
      hid_t dd = H5Dopen2(f, dp, H5P_DEFAULT);
      if (dd < 0) continue;
      hid_t sp = H5Dget_space(dd);
      hsize_t dims[2];
      int nd = H5Sget_simple_extent_dims(sp, dims, NULL);
      size_t n = 1;
      for (int k = 0; k < nd; k++) n *= (size_t)dims[k];
      float *buf = malloc(n * sizeof(float));
      H5Dread(dd, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
      gbytes += (double)n * sizeof(float);
      free(buf);
      H5Sclose(sp); H5Dclose(dd);
    }
  }
  double t_geo = now() - t;

  H5Fclose(f);
  for (size_t i = 0; i < ngran; i++) free(gran[i]);
  free(gran);

  double tot = t_modis + t_misr + t_geo;
  printf("phase,seconds,MiB,MiB_per_s\n");
  printf("open,%.4f,0,0\n", t_open);
  printf("modis_band,%.4f,%.1f,%.1f\n", t_modis, mbytes / 1048576.0,
         mbytes / 1048576.0 / t_modis);
  printf("misr_full,%.4f,%.1f,%.1f\n", t_misr, rbytes / 1048576.0,
         rbytes / 1048576.0 / t_misr);
  printf("modis_geo,%.4f,%.1f,%.1f\n", t_geo, gbytes / 1048576.0,
         gbytes / 1048576.0 / t_geo);
  printf("TOTAL,%.4f,%.1f,%.1f\n", tot,
         (mbytes + rbytes + gbytes) / 1048576.0,
         (mbytes + rbytes + gbytes) / 1048576.0 / tot);
  return 0;
}
