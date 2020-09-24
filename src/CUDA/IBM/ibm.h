/*
*   @file ibm.h
*   @author Marco Ferrari. (marcoferrari@alunos.utfpr.edu.br)
*   @author Waine Jr. (waine@alunos.utfpr.edu.br)
*   @brief IBM steps: perform interpolation and spread force
*   @version 0.3.0
*   @date 26/08/2020
*/


#ifndef __IBM_H
#define __IBM_H

#include "ibmVar.h"

#include "ibmGlobalFunctions.h"
#include "../lbm.h"
#include "../structs/macroscopics.h"
#include "../structs/populations.h"
#include "../structs/globalStructs.h"
#include "structs/particle.h"

__host__
void immersedBoundaryMethod(
    ParticlesSoA particles,
    Macroscopics* const __restrict__ macr,
    Populations* const __restrict__ pop,
    dim3 gridLBM,
    dim3 threadsLBM,
    unsigned int gridIBM,
    unsigned int threadsIBM,
    cudaStream_t* __restrict__ stream
);


__global__
void gpuForceInterpolationSpread(
    ParticleNodeSoA particlesNodes,
    ParticleCenter const particleCenters[NUM_PARTICLES],
    Macroscopics const macr
);


__global__
void gpuUpdateMacrResetForces(Populations pop, Macroscopics macr);


__global__
void gpuResetNodesForces(ParticleNodeSoA* __restrict__ particleNodes);


__host__
void updateParticleCenterVelocityAndRotation(
    ParticleCenter particleCenters[NUM_PARTICLES]
);

__host__
void particleMovement(
    ParticleCenter particleCenters[NUM_PARTICLES]
);

__global__
void particleNodeMovement(
    ParticleNodeSoA const particlesNodes,
    ParticleCenter particleCenters[NUM_PARTICLES]
);

__host__ 
dfloat3 particleCollisionSoft(
    ParticleCenter* __restrict__ particleCenter,
    int particleIndex
);


#endif // !__IBM_H