/*
 *
 * Control program for the MD update
 *
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>

#define DECL
#include "coord.h"

double second(void);

static void *aligned_calloc_or_die(size_t count, size_t size, const char *label)
{
  void *ptr;
  const size_t total = count * size;

  if(size != 0 && count > (SIZE_MAX / size)){
    fprintf(stderr, "allocation overflow for %s\n", label);
    exit(1);
  }

  if(posix_memalign(&ptr, ARRAY_ALIGNMENT, total) != 0){
    fprintf(stderr, "aligned allocation failed for %s\n", label);
    exit(1);
  }

  memset(ptr, 0, total);
  return ptr;
}

int main(int argc, char *argv[]){
  int i,j;
  FILE *in, *out;
  double start,stop;
  double compute_total;
  char name[80];
  /*  timestep value */
  double dt=0.02;

  /*  number of timesteps to use. */
  int Nstep=100;
  int Nsave=5;
  
  if( argc > 1 ){
    Nstep=atoi(argv[1]);
  }
  wind[Xcoord] = 0.9;
  wind[Ycoord] = 0.4;
  wind[Zcoord] = 0.0;
  /* set up multi dimensional arrays */
  mass = aligned_calloc_or_die(Nbody, sizeof(double), "mass");
  inv_mass = aligned_calloc_or_die(Nbody, sizeof(double), "inv_mass");
  pair_mass_scale = aligned_calloc_or_die(Nbody, sizeof(double), "pair_mass_scale");
  central_mass_scale = aligned_calloc_or_die(Nbody, sizeof(double), "central_mass_scale");
  radius = aligned_calloc_or_die(Nbody, sizeof(double), "radius");
  vis = aligned_calloc_or_die(Nbody, sizeof(double), "vis");
  for(i=0;i<Ndim;i++){
    f[i] = aligned_calloc_or_die(Nbody, sizeof(double), "force");
    pos[i] = aligned_calloc_or_die(Nbody, sizeof(double), "position");
    velo[i] = aligned_calloc_or_die(Nbody, sizeof(double), "velocity");
  }

/* read the initial data from a file */

  collisions=0;
  in = fopen("input.dat","r");

  if( ! in ){
    perror("input.dat");
    exit(1);
  }

  for(i=0;i<Nbody;i++){
    fscanf(in,"%16le%16le%16le%16le%16le%16le%16le%16le%16le\n",
      mass+i,radius+i,vis+i,
      &pos[Xcoord][i], &pos[Ycoord][i], &pos[Zcoord][i],
      &velo[Xcoord][i], &velo[Ycoord][i], &velo[Zcoord][i]);
    inv_mass[i] = 1.0 / mass[i];
    pair_mass_scale[i] = G * mass[i];
    central_mass_scale[i] = G * M_central * mass[i];
  }
  fclose(in);

/*
 * Run Nstep timesteps and time how long it takes
 */
 
   compute_total = 0.0;
   for(j=1;j<=Nsave;j++){
      start=second();
      evolve(Nstep,dt); 
      stop=second();
      compute_total += stop - start;
      printf("%d timesteps took %f seconds\n",Nstep,stop-start);
      printf("collisions %d\n",collisions);
      fflush(stdout);
/* write final result to a file */
      sprintf(name,"output.dat%03d",j*Nstep);
      out = fopen(name,"w");

      if( ! out ){
	perror(name);
	exit(1);
      }

      for(i=0;i<Nbody;i++){
	fprintf(out,"%16.8E%16.8E%16.8E%16.8E%16.8E%16.8E%16.8E%16.8E%16.8E\n",
		mass[i],radius[i],vis[i],
		pos[Xcoord][i], pos[Ycoord][i], pos[Zcoord][i],
		velo[Xcoord][i], velo[Ycoord][i], velo[Zcoord][i]);
      }
      fclose(out);
  }
  printf("%d timesteps took %f seconds\n",Nsave*Nstep,compute_total);

}

double second()
{
        struct timeval tp;
        struct timezone tzp;
        int i;

        i = gettimeofday(&tp,&tzp);
        return ( (double) tp.tv_sec + (double) tp.tv_usec * 1.e-6 );
}
