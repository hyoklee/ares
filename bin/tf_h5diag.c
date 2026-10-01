/* Open a granule with the full HDF5 error stack enabled, and cap memory so a
 * runaway allocation reports instead of inviting the OOM killer. */
#include <hdf5.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: h5diag <file> [rss_mb]\n"); return 2; }
  long cap = (argc > 2) ? atol(argv[2]) : 8192;           /* MiB */
  struct rlimit rl = { (rlim_t)cap * 1024 * 1024, (rlim_t)cap * 1024 * 1024 };
  setrlimit(RLIMIT_AS, &rl);
  printf("# address space capped at %ld MiB\n", cap);
  H5Eset_auto2(H5E_DEFAULT, (H5E_auto2_t)H5Eprint2, stderr);
  printf("# H5Fopen(%s)\n", argv[1]);
  fflush(stdout);
  hid_t f = H5Fopen(argv[1], H5F_ACC_RDONLY, H5P_DEFAULT);
  if (f < 0) { printf("# H5Fopen FAILED\n"); return 1; }
  printf("# H5Fopen OK\n");
  hsize_t n = 0;
  H5Gget_num_objs(H5Gopen2(f, "/", H5P_DEFAULT), &n);
  printf("# root has %llu objects\n", (unsigned long long)n);
  H5Fclose(f);
  return 0;
}
