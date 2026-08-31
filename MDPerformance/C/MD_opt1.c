/*
 * MD_opt1.c — Optimisation Level 1
 *
 * Same algorithmic structure as baseline (Newton's-third-law pair walk with
 * j-blocking).  Changes are purely arithmetic / compiler-hint level:
 *
 *   1. Reciprocal-sqrt:  replace  sqrt(r2) + division  with
 *        inv_r = 1/sqrt(r2),  inv_r3 = inv_r*inv_r*inv_r,
 *        r = r2*inv_r        (avoids a second sqrt for collision check).
 *      This eliminates all explicit divisions from the hot loop and enables
 *      the compiler to emit hardware rsqrt + Newton-Raphson under -ffast-math.
 *
 *   2. Branchless collision:  replace the if/else with a sign-select so the
 *      inner loop body contains no branches.  This allows the auto-vectoriser
 *      to use masked SIMD lanes instead of scalar fallback.
 *
 *   3. Compiler vectorisation hints  (clang loop pragmas / GCC ivdep) on the
 *      inner jj loop.
 */

#include <math.h>
#include "coord.h"

#if defined(__clang__) || defined(__GNUC__)
#define ASSUME_ALIGNED(ptr) __builtin_assume_aligned((ptr), ARRAY_ALIGNMENT)
#else
#define ASSUME_ALIGNED(ptr) (ptr)
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
  int step;
  int i, j_block, jj;
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
      const double r2 = px*px + py*py + pz*pz;
      const double inv_r  = 1.0 / sqrt(r2);
      const double inv_r3 = inv_r * inv_r * inv_r;
      const double rs = central_scale[i] * inv_r3;

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
        const double *restrict px_blk = pos_x      + j_block;
        const double *restrict py_blk = pos_y      + j_block;
        const double *restrict pz_blk = pos_z      + j_block;
        const double *restrict m_blk  = mass_value  + j_block;
        const double *restrict r_blk  = radius_value+ j_block;
        double *restrict fx_blk = force_x + j_block;
        double *restrict fy_blk = force_y + j_block;
        double *restrict fz_blk = force_z + j_block;

        VECTORIZE_LOOP
        for(jj = 0; jj < block_len; jj++){
          const double dx = px_i - px_blk[jj];
          const double dy = py_i - py_blk[jj];
          const double dz = pz_i - pz_blk[jj];
          const double r2 = dx*dx + dy*dy + dz*dz;

          /* reciprocal sqrt: one sqrt, no division */
          const double inv_r  = 1.0 / sqrt(r2);
          const double r      = r2 * inv_r;
          const double inv_r3 = inv_r * inv_r * inv_r;

          const double scale = pair_scale_i * m_blk[jj] * inv_r3;
          const double dfx   = scale * dx;
          const double dfy   = scale * dy;
          const double dfz   = scale * dz;

          /* branchless collision: sign = +1 normal gravity, -1 repulsion */
          const double size = radius_i + r_blk[jj];
          const double sign = (r >= size) ? 1.0 : -1.0;
          const int    coll = (r < size);

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
