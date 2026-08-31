/*
 * MD_opt2.c — Optimisation Level 2
 *
 * All opt1 improvements (branchless, reciprocal-sqrt, vectorisation hints)
 * plus structural changes:
 *
 *   1. r²-based collision check.
 *      Replaces  r = r2·inv_r ; (r ≥ size)
 *      with      size² = size·size ; (r2 ≥ size²).
 *      Mathematically equivalent for positive r and size.
 *
 *      This eliminates the multiply  r = r2·inv_r  from the rsqrt
 *      critical path and makes the collision comparison depend only on
 *      r2 (available early) and size² (independent of the rsqrt).
 *      The sign-select value is ready before dfx/dfy/dfz, so the final
 *      accumulation can proceed without waiting on the collision check.
 *
 *   2. Software prefetching of the next j-block's position + mass data
 *      into L2, hiding memory latency for the upcoming block.
 */

#include <math.h>
#include "coord.h"

#if defined(__clang__) || defined(__GNUC__)
#define ASSUME_ALIGNED(ptr) __builtin_assume_aligned((ptr), ARRAY_ALIGNMENT)
#define PREFETCH_R(addr) __builtin_prefetch((addr), 0, 1)
#else
#define ASSUME_ALIGNED(ptr) (ptr)
#define PREFETCH_R(addr) ((void)0)
#endif

#if defined(__clang__)
#define VECTORIZE_LOOP \
  _Pragma("clang loop vectorize(enable) interleave(enable) vectorize_width(4)")
#elif defined(__GNUC__)
#define VECTORIZE_LOOP _Pragma("GCC ivdep")
#else
#define VECTORIZE_LOOP
#endif

enum { PairBlockSize = 128 };

void evolve(int count, double dt)
{
  int step, i, jj, j_block;
  int collisions_local = collisions;
  const double wind_x = wind[Xcoord];
  const double wind_y = wind[Ycoord];
  const double wind_z = wind[Zcoord];
  const double *restrict vis_coeff     = (const double *restrict) ASSUME_ALIGNED(vis);
  const double *restrict mass_value    = (const double *restrict) ASSUME_ALIGNED(mass);
  const double *restrict radius_value  = (const double *restrict) ASSUME_ALIGNED(radius);
  const double *restrict inv_mass_value= (const double *restrict) ASSUME_ALIGNED(inv_mass);
  const double *restrict pair_scale    = (const double *restrict) ASSUME_ALIGNED(pair_mass_scale);
  const double *restrict central_scale = (const double *restrict) ASSUME_ALIGNED(central_mass_scale);
  double *restrict pos_x   = (double *restrict) ASSUME_ALIGNED(pos[Xcoord]);
  double *restrict pos_y   = (double *restrict) ASSUME_ALIGNED(pos[Ycoord]);
  double *restrict pos_z   = (double *restrict) ASSUME_ALIGNED(pos[Zcoord]);
  double *restrict vel_x   = (double *restrict) ASSUME_ALIGNED(velo[Xcoord]);
  double *restrict vel_y   = (double *restrict) ASSUME_ALIGNED(velo[Ycoord]);
  double *restrict vel_z   = (double *restrict) ASSUME_ALIGNED(velo[Zcoord]);
  double *restrict force_x = (double *restrict) ASSUME_ALIGNED(f[Xcoord]);
  double *restrict force_y = (double *restrict) ASSUME_ALIGNED(f[Ycoord]);
  double *restrict force_z = (double *restrict) ASSUME_ALIGNED(f[Zcoord]);

  for(step = 0; step < count; step++){

    /* ---- central gravity + viscous drag  O(N) ---- */
    VECTORIZE_LOOP
    for(i = 0; i < Nbody; i++){
      const double px = pos_x[i];
      const double py = pos_y[i];
      const double pz = pos_z[i];
      const double drag = -vis_coeff[i];
      const double r2c = px*px + py*py + pz*pz;
      const double inv_rc  = 1.0 / sqrt(r2c);
      const double inv_rc3 = inv_rc * inv_rc * inv_rc;
      const double rs = central_scale[i] * inv_rc3;

      force_x[i] = drag * (vel_x[i] + wind_x) - rs * px;
      force_y[i] = drag * (vel_y[i] + wind_y) - rs * py;
      force_z[i] = drag * (vel_z[i] + wind_z) - rs * pz;
    }

    /* ---- pairwise forces  O(N²/2), Newton's third law ---- */
    for(i = 0; i < Nbody; i++){
      const double px_i = pos_x[i];
      const double py_i = pos_y[i];
      const double pz_i = pos_z[i];
      const double pair_scale_i = pair_scale[i];
      const double radius_i     = radius_value[i];

      double fix = force_x[i];
      double fiy = force_y[i];
      double fiz = force_z[i];

      for(j_block = i + 1; j_block < Nbody; j_block += PairBlockSize){
        const int block_end = (j_block + PairBlockSize < Nbody)
                            ? (j_block + PairBlockSize) : Nbody;
        const int block_len = block_end - j_block;
        const double *restrict px_blk = pos_x       + j_block;
        const double *restrict py_blk = pos_y       + j_block;
        const double *restrict pz_blk = pos_z       + j_block;
        const double *restrict m_blk  = mass_value   + j_block;
        const double *restrict r_blk  = radius_value + j_block;
        double *restrict fx_blk = force_x + j_block;
        double *restrict fy_blk = force_y + j_block;
        double *restrict fz_blk = force_z + j_block;

        /* prefetch next block into L2 */
        if(j_block + PairBlockSize < Nbody){
          PREFETCH_R(pos_x      + j_block + PairBlockSize);
          PREFETCH_R(pos_y      + j_block + PairBlockSize);
          PREFETCH_R(pos_z      + j_block + PairBlockSize);
          PREFETCH_R(mass_value + j_block + PairBlockSize);
        }

        VECTORIZE_LOOP
        for(jj = 0; jj < block_len; jj++){
          const double dx = px_i - px_blk[jj];
          const double dy = py_i - py_blk[jj];
          const double dz = pz_i - pz_blk[jj];
          const double r2 = dx*dx + dy*dy + dz*dz;

          const double inv_r  = 1.0 / sqrt(r2);
          const double inv_r3 = inv_r * inv_r * inv_r;
          const double scale  = pair_scale_i * m_blk[jj] * inv_r3;

          const double dfx = scale * dx;
          const double dfy = scale * dy;
          const double dfz = scale * dz;

          /*
           * r²-based collision check:  r ≥ size  ⟺  r² ≥ size²
           * (valid for non-negative r and size).
           *
           * size_sq depends only on radius data (not on rsqrt), so the
           * comparison r2 ≥ size_sq is resolved before dfx is ready.
           * The sign-select no longer sits on the rsqrt critical path.
           */
          const double size    = radius_i + r_blk[jj];
          const double size_sq = size * size;
          const double sign    = (r2 >= size_sq) ? 1.0 : -1.0;
          const int    coll    = (r2 < size_sq);

          const double sdfx = sign * dfx;
          const double sdfy = sign * dfy;
          const double sdfz = sign * dfz;

          fix -= sdfx;
          fiy -= sdfy;
          fiz -= sdfz;
          fx_blk[jj] += sdfx;
          fy_blk[jj] += sdfy;
          fz_blk[jj] += sdfz;
          collisions_local += coll;
        }
      }

      force_x[i] = fix;
      force_y[i] = fiy;
      force_z[i] = fiz;
    }

    /* ---- semi-implicit Euler integration  O(N) ---- */
    VECTORIZE_LOOP
    for(i = 0; i < Nbody; i++){
      const double vx = vel_x[i];
      const double vy = vel_y[i];
      const double vz = vel_z[i];
      const double dt_over_m = dt * inv_mass_value[i];

      pos_x[i] += dt * vx;
      pos_y[i] += dt * vy;
      pos_z[i] += dt * vz;
      vel_x[i] = vx + dt_over_m * force_x[i];
      vel_y[i] = vy + dt_over_m * force_y[i];
      vel_z[i] = vz + dt_over_m * force_z[i];
    }
  }

  collisions = collisions_local;
}
