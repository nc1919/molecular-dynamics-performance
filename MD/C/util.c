#include <math.h>

void vis_forces(int N,double *f, double *vis, double *velo)
{
  int i;
          for(i=0;i<N;i++){
            f[i] = -vis[i] * velo[i];
          }
}
void wind_forces(int N,double *f, double *vis, double velo)
{
  int i;
          for(i=0;i<N;i++){
            f[i] = f[i] -vis[i] * velo;
          }
}
void add_norms(int N,double *r, double *delta)
{
  int k;
        for(k=0;k<N;k++){
          r[k] += (delta[k] * delta[k]);
        }
}

double forces(double Wv, double deltav, double rv){
  return Wv*deltav/(pow(rv,3.0));
}



