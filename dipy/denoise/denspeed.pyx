from __future__ import division

import numpy as np
cimport numpy as cnp
cimport cython
from cython.parallel import parallel, prange

from libc.math cimport sqrt, exp
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy


def nlmeans_3d(arr, mask=None, sigma=None, patch_radius=1,
               block_radius=5, rician=True):
    """ Non-local means for denoising 3D images

    Parameters
    ----------
    arr : 3D ndarray
        The array to be denoised
    mask : 3D ndarray
    sigma : float
        standard deviation of the noise estimated from the data
    patch_radius : int
        patch size is ``2 x patch_radius + 1``. Default is 1.
    block_radius : int
        block size is ``2 x block_radius + 1``. Default is 5.
    rician : boolean
        If True the noise is estimated as Rician, otherwise Gaussian noise
        is assumed.

    Returns
    -------
    denoised_arr : ndarray
        the denoised ``arr`` which has the same shape as ``arr``.

    """
    if arr.ndim != 3:
        raise ValueError('arr needs to be a 3D ndarray')

    if mask is None:
        mask = np.ones_like(arr, dtype='f8')
    else:
        mask = np.ascontiguousarray(mask, dtype='f8')

    if mask.ndim != 3:
        raise ValueError('arr needs to be a 3D ndarray')

    arr = np.ascontiguousarray(arr, dtype='f8')

    arr = add_padding_reflection(arr, block_radius)


    mask = add_padding_reflection(mask.astype('f8'), block_radius)

    arrnlm = _nlmeans_3d(arr, mask, sigma, patch_radius, block_radius, rician)

    return remove_padding(arrnlm, block_radius)


@cython.wraparound(False)
@cython.boundscheck(False)
def _nlmeans_3d(double [:, :, ::1] arr, double [:, :, ::1] mask,
                sigma, patch_radius=1, block_radius=5,
                rician=True):
    """ This algorithm denoises the value of every voxel (i, j ,k) by
    calculating a weight between a moving 3D patch and a static 3D patch
    centered at (i, j, k). The moving patch can only move inside a
    3D block.
    """

    cdef:
        cnp.npy_intp i, j, k, I, J, K
        double [:, :, ::1] out = np.zeros_like(arr)
        double summ = 0
        double sigm = 0
        cnp.npy_intp P = patch_radius
        cnp.npy_intp B = block_radius

    sigm = sigma

    I = arr.shape[0]
    J = arr.shape[1]
    K = arr.shape[2]

    #move the block
    with nogil, parallel():
        for i in prange(B, I - B):
            for j in range(B , J - B):
                for k in range(B, K - B):

                    if mask[i, j, k] == 0:
                        continue

                    out[i, j, k] = process_block(arr, i, j, k, B, P, sigm)

    new = np.asarray(out)

    if rician:
        new -= 2 * sigm ** 2
        new[new < 0] = 0

    return np.sqrt(new)


@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
cdef double process_block(double [:, :, ::1] arr,
                          cnp.npy_intp i, cnp.npy_intp j, cnp.npy_intp k,
                          cnp.npy_intp B, cnp.npy_intp P, double sigma) nogil:
    """ Process the block with center at (i, j, k)

    Parameters
    ----------
    arr : 3D array
        C contiguous array of doubles
    i, j, k : int
        center of block
    B : int
        block radius
    P : int
        patch radius
    sigma : double

    Returns
    -------
    new_value : double
    """

    cdef:
        cnp.npy_intp m, n, o, M, N, O, a, b, c, cnt, step
        double patch_vol_size
        double summ, d, w, sumw, sum_out, x
        double * W
        double * cache
        double denom
        cnp.npy_intp BS = B * 2 + 1


    cnt = 0
    sumw = 0
    patch_vol_size = (P + P + 1) * (P + P + 1) * (P + P + 1)
    denom = sigma * sigma

    W = <double *> malloc(BS * BS * BS * sizeof(double))
    cache = <double *> malloc(BS * BS * BS * sizeof(double))

    # (i, j, k) coordinates are the center of the static patch
    # copy block in cache
    copy_block_3d(cache, BS, BS, BS, arr, i - B, j - B, k - B)

    # calculate weights between the central patch and the moving patch in block
    # (m, n, o) coordinates are the center of the moving patch
    # (a, b, c) run inside both patches
    for m in range(P, BS - P):
        for n in range(P, BS - P):
            for o in range(P, BS - P):

                summ = 0

                # calculate square distance
                for a in range(- P, P + 1):
                    for b in range(- P, P + 1):
                        for c in range(- P, P + 1):

                            # this line takes most of the time! mem access
                            d = cache[(B + a) * BS * BS + (B + b) * BS + (B + c)] - cache[(m + a) * BS * BS + (n + b) * BS + (o + c)]
                            summ += d * d

                w = exp(-(summ / patch_vol_size) / denom)
                sumw += w
                W[cnt] = w
                cnt += 1

    cnt = 0

    sum_out = 0

    # calculate normalized weights and sums of the weights with the positions
    # of the patches
    for m in range(P, BS - P):
        for n in range(P, BS - P):
            for o in range(P, BS - P):

                if sumw > 0:
                    w = W[cnt] / sumw
                else:
                    w = 0

                x = cache[m * BS * BS + n * BS + o]

                sum_out += w * x * x

                cnt += 1

    free(W)
    free(cache)

    return sum_out


def add_padding_reflection(double [:, :, ::1] arr, cnp.npy_intp padding):
    cdef:
        double [:, :, ::1] final
        cnp.npy_intp i, j, k
        cnp.npy_intp B = padding
        cnp.npy_intp [::1] indices_i = correspond_indices(arr.shape[0], padding)
        cnp.npy_intp [::1] indices_j = correspond_indices(arr.shape[1], padding)
        cnp.npy_intp [::1] indices_k = correspond_indices(arr.shape[2], padding)

    final = np.zeros(np.array((arr.shape[0], arr.shape[1], arr.shape[2])) + 2*padding)

    for i in range(final.shape[0]):
        for j in range(final.shape[1]):
            for k in range(final.shape[2]):
                final[i, j, k] = arr[indices_i[i], indices_j[j], indices_k[k]]

    return final


def correspond_indices(dim_size, padding):
    return np.ascontiguousarray(np.hstack((np.arange(1, padding + 1)[::-1],
                                np.arange(dim_size),
                                np.arange(dim_size - padding - 1, dim_size - 1)[::-1])))


def remove_padding(arr, padding):
    shape = arr.shape
    return arr[padding:shape[0] - padding,
               padding:shape[1] - padding,
               padding:shape[2] - padding]


@cython.wraparound(False)
@cython.boundscheck(False)
cdef cnp.npy_intp copy_block_3d(double * dest,
                                 cnp.npy_intp I,
                                 cnp.npy_intp J,
                                 cnp.npy_intp K,
                                 double [:, :, ::1] source,
                                 cnp.npy_intp min_i,
                                 cnp.npy_intp min_j,
                                 cnp.npy_intp min_k) nogil:

    cdef cnp.npy_intp i, j

    for i in range(I):
        for j in range(J):
            memcpy(&dest[i * J * K  + j * K], &source[i + min_i, j + min_j, min_k], K * sizeof(double))

    return 1




