/*
 * Force-included shim (via -include) to work around HDF5 develop assuming
 * strlcpy/strlcat exist on every non-Windows platform.
 *
 * src/H5private.h:156 guards its portable implementations with
 *     #ifdef H5_HAVE_WIN32_API
 * but glibc only gained strlcpy/strlcat in 2.38 (Aug 2023). On glibc < 2.38
 * (Ubuntu 22.04 = 2.35, RHEL 8/9, Debian 11/12) the symbols are absent and
 * libhdf5.so ends up with undefined references.
 *
 * This file is external to the HDF5 source tree; nothing in the repo is
 * modified. It compiles to nothing on platforms that already have these.
 */
#ifndef H5_STRLCPY_SHIM_H
#define H5_STRLCPY_SHIM_H

#include <stddef.h>
#include <string.h>

#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if !__GLIBC_PREREQ(2, 38)
#define H5_SHIM_NEED_STRLCPY 1
#endif
#endif

#ifdef H5_SHIM_NEED_STRLCPY

static inline size_t
strlcpy(char *dst, const char *src, size_t dsize)
{
    size_t srclen = strlen(src);
    if (dsize > 0) {
        size_t copylen = (srclen < dsize - 1) ? srclen : dsize - 1;
        memcpy(dst, src, copylen);
        dst[copylen] = '\0';
    }
    return srclen;
}

static inline size_t
strlcat(char *dst, const char *src, size_t dsize)
{
    size_t dstlen = strlen(dst);
    size_t srclen = strlen(src);
    if (dsize > dstlen + 1) {
        size_t copylen = srclen < dsize - dstlen - 1 ? srclen : dsize - dstlen - 1;
        memcpy(dst + dstlen, src, copylen);
        dst[dstlen + copylen] = '\0';
    }
    return dstlen + srclen;
}

#endif /* H5_SHIM_NEED_STRLCPY */
#endif /* H5_STRLCPY_SHIM_H */
