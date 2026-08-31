/*
 * Shared data for the MD update.
 *
 * The performance version keeps a structure-of-arrays layout and only
 * stores state that is required by the current timestep kernel.
 */

#ifdef DECL
#define DEF
#else
#define DEF extern
#endif
#define ARRAY_ALIGNMENT 64
#define Nbody 4*1024
#define  Npair ((Nbody*(Nbody-1))/2)

enum{ Xcoord=0, Ycoord, Zcoord, Ndim };
      
DEF double *pos[Ndim], *velo[Ndim];
DEF double *f[Ndim], *vis, *mass, *radius, *inv_mass;
DEF double *pair_mass_scale, *central_mass_scale;
DEF double wind[Ndim];
DEF int collisions;

#define G 2.0
#define M_central 1000.0

void evolve(int Nstep, double dt);
