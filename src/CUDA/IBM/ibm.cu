#include "ibm.h"

#ifdef IBM

__host__ void immersedBoundaryMethod(
    ParticlesSoA particles,
    Macroscopics *const __restrict__ macr,
    Populations *const __restrict__ pop,
    dim3 gridLBM,
    dim3 threadsLBM,
    unsigned int gridIBM,
    unsigned int threadsIBM,
    cudaStream_t *__restrict__ stream)
{
    // TODO: Update it to multi GPU
    // Update macroscopics post streaming and reset forces
    gpuUpdateMacrResetForces<<<gridLBM, threadsLBM, 0, stream[0]>>>(pop[0], macr[0]);
    gpuResetNodesForces<<<gridIBM, threadsIBM, 0, stream[0]>>>(particles.nodesSoA);

    checkCudaErrors(cudaStreamSynchronize(stream[0]));

    for (int i = 0; i < IBM_MAX_ITERATION; i++)
    {
        gpuForceInterpolationSpread<<<gridIBM, threadsIBM, 0, stream[0]>>>(
            particles.nodesSoA, particles.pCenterArray, macr[0]);

        // Update LBM velcoties and density
        // TODO: update it in kernel with interpolation/spread
        // TODO: update only velocities, since density is constant
        gpuUpdateMacr<<<gridLBM, threadsLBM, 0, stream[0]>>>(pop[0], macr[0]);
        checkCudaErrors(cudaStreamSynchronize(stream[0]));

        // Update particle velocity using body center force and constant forces
        updateParticleCenterVelocityAndRotation(particles.pCenterArray);
    }

    // Update particle center position and its old values
    particleMovement(particles.pCenterArray);
    // Update particle nodes positions
    gpuParticleNodeMovement<<<gridIBM, threadsIBM, 0, stream[0]>>>(
        particles.nodesSoA, particles.pCenterArray);

    checkCudaErrors(cudaStreamSynchronize(stream[0]));
}

__global__ void gpuForceInterpolationSpread(
    ParticleNodeSoA const particlesNodes,
    ParticleCenter const particleCenters[NUM_PARTICLES],
    Macroscopics const macr)
{
    // TODO: update atomic double add to use only if is double
    const unsigned int i = threadIdx.x + blockDim.x * blockIdx.x;

    if (i >= particlesNodes.numNodes)
        return;

    dfloat aux; // aux variable for many things
    size_t idx; // index for many things

    const dfloat xIBM = particlesNodes.pos.x[i];
    const dfloat yIBM = particlesNodes.pos.y[i];
    const dfloat zIBM = particlesNodes.pos.z[i];

// Stencil distance
#if defined STENCIL_2
    const int pdist = 2;
#endif

#if defined STENCIL_4
    const int pdist = 4;
#endif

    // LBM nearest position
    const int xNear = (int)(xIBM + 0.5);
    const int yNear = (int)(yIBM + 0.5);
    const int zNear = (int)(zIBM + 0.5);

    // Minimum number of xyz for LBM interpolation
    const unsigned int xMin = ((xNear - pdist) < 0) ? 0 : xNear - pdist;
    const unsigned int yMin = ((yNear - pdist) < 0) ? 0 : yNear - pdist;
    const unsigned int zMin = ((zNear - pdist) < 0) ? 0 : zNear - pdist;

    // Maximum number of xyz for LBM interpolation, excluding last
    // (e.g. NX goes just until NX-1)
    const unsigned int xMax = ((xNear + pdist) > NX) ? NX : xNear + pdist;
    const unsigned int yMax = ((yNear + pdist) > NY) ? NY : yNear + pdist;
    const unsigned int zMax = ((zNear + pdist) > NZ) ? NZ : zNear + pdist;

    dfloat rhoVar = 0;
    dfloat uxVar = 0;
    dfloat uyVar = 0;
    dfloat uzVar = 0;

    // Index of particle center of this particle node
    idx = particlesNodes.particleCenterIdx[i];

    // Load position, velocity and rotation velocity of particle center
    const dfloat x_pc = particleCenters[idx].pos.x;
    const dfloat y_pc = particleCenters[idx].pos.y;
    const dfloat z_pc = particleCenters[idx].pos.z;

    const dfloat vx_pc = particleCenters[idx].vel.x;
    const dfloat vy_pc = particleCenters[idx].vel.y;
    const dfloat vz_pc = particleCenters[idx].vel.z;

    const dfloat wx_pc = particleCenters[idx].w.x;
    const dfloat wy_pc = particleCenters[idx].w.y;
    const dfloat wz_pc = particleCenters[idx].w.z;

    // velocity on node, given the center velocity and rotation
    // (i.e. no slip boundary condition velocity)
    const dfloat ux_cal = vx_pc + (wy_pc * (zIBM - z_pc) - wz_pc * (yIBM - y_pc));
    const dfloat uy_cal = vy_pc + (wz_pc * (xIBM - x_pc) - wx_pc * (zIBM - z_pc));
    const dfloat uz_cal = vz_pc + (wx_pc * (yIBM - y_pc) - wy_pc * (xIBM - x_pc));

    //  Interpolation
    for (int z = zMin; z < zMax; z++)
    {
        for (int y = yMin; y < yMax; y++)
        {
            for (int x = xMin; x < xMax; x++)
            {
                idx = idxScalar(x, y, z);
                // Dirac delta (kernel)
                aux = stencil(x - xIBM) * stencil(y - yIBM) * stencil(z - zIBM);

                rhoVar += macr.rho[idx] * aux;
                uxVar += macr.ux[idx] * aux;
                uyVar += macr.uy[idx] * aux;
                uzVar += macr.uz[idx] * aux;
                
            }
        }
    }

    particlesNodes.vel.x[i] = uxVar;
    particlesNodes.vel.y[i] = uyVar;
    particlesNodes.vel.z[i] = uzVar;

    const dfloat dA = particlesNodes.S[i];
    aux = 2 * rhoVar * dA * IBM_THICKNESS;

    const dfloat deltaFx = aux * (uxVar - ux_cal);
    const dfloat deltaFy = aux * (uyVar - uy_cal);
    const dfloat deltaFz = aux * (uzVar - uz_cal);

    // Calculate IBM forces
    const dfloat fxIBM = particlesNodes.f.x[i] + deltaFx;
    const dfloat fyIBM = particlesNodes.f.y[i] + deltaFy;
    const dfloat fzIBM = particlesNodes.f.z[i] + deltaFz;

    // Spreading
    for (int z = zMin; z < zMax; z++)
    {
        for (int y = yMin; y < yMax; y++)
        {
            for (int x = xMin; x < xMax; x++)
            {
                idx = idxScalar(x, y, z);

                // Dirac delta (kernel)
                aux = stencil(x - xIBM) * stencil(y - yIBM) * stencil(z - zIBM);

                // TODO: update rho and velocities of LBM here, but with 
                // different array to not have concurrent problems with loading 
                // the velocities
                atomicDoubleAdd((double *)&(macr.fx[idx]), (double)-deltaFx * aux);
                atomicDoubleAdd((double *)&(macr.fy[idx]), (double)-deltaFy * aux);
                atomicDoubleAdd((double *)&(macr.fz[idx]), (double)-deltaFz * aux);
            }
        }
    }

    // Update node force
    particlesNodes.f.x[i] = fxIBM;
    particlesNodes.f.y[i] = fyIBM;
    particlesNodes.f.z[i] = fzIBM;

    // Update node delta forne
    particlesNodes.deltaF.x[i] = deltaFx;
    particlesNodes.deltaF.y[i] = deltaFy;
    particlesNodes.deltaF.z[i] = deltaFz;

    // Particle node delta momentum
    dfloat3 deltaMomentum = dfloat3();

    deltaMomentum.x = (yIBM - y_pc) * deltaFz - (zIBM - z_pc) * deltaFy;
    deltaMomentum.y = (zIBM - z_pc) * deltaFx - (xIBM - x_pc) * deltaFz;
    deltaMomentum.z = (xIBM - x_pc) * deltaFy - (yIBM - y_pc) * deltaFx;

    // Add node force to particle center
    idx = particlesNodes.particleCenterIdx[i];

    // TODO: check if shared memory is more efficient
    atomicDoubleAdd((double *)&(particleCenters[idx].f.x), (double)deltaFx);
    atomicDoubleAdd((double *)&(particleCenters[idx].f.y), (double)deltaFy);
    atomicDoubleAdd((double *)&(particleCenters[idx].f.z), (double)deltaFz);

    atomicDoubleAdd((double *)&(particleCenters[idx].M.x), (double)deltaMomentum.x);
    atomicDoubleAdd((double *)&(particleCenters[idx].M.y), (double)deltaMomentum.y);
    atomicDoubleAdd((double *)&(particleCenters[idx].M.z), (double)deltaMomentum.z);
}

__global__ void gpuUpdateMacrResetForces(Populations pop, Macroscopics macr)
{
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= NX || y >= NY || z >= NZ)
        return;

    size_t idx = idxScalar(x, y, z);

    // Reset forces
    macr.fx[idx] = FX;
    macr.fy[idx] = FY;
    macr.fz[idx] = FZ;

    // load populations
    dfloat fNode[Q];
    for (unsigned char i = 0; i < Q; i++)
        fNode[i] = pop.pop[idxPop(x, y, z, i)];

    // calc for macroscopics
    // rho = sum(f[i])
    // ux = sum(f[i]*cx[i] + Fx/2) / rho
    // uy = sum(f[i]*cy[i] + Fy/2) / rho
    // uz = sum(f[i]*cz[i] + Fz/2) / rho
#ifdef D3Q19
    const dfloat rhoVar = fNode[0] + fNode[1] + fNode[2] + fNode[3] + fNode[4] 
        + fNode[5] + fNode[6] + fNode[7] + fNode[8] + fNode[9] + fNode[10] 
        + fNode[11] + fNode[12] + fNode[13] + fNode[14] + fNode[15] + fNode[16] 
        + fNode[17] + fNode[18];
    const dfloat invRho = 1 / rhoVar;
    const dfloat uxVar = ((fNode[1] + fNode[7] + fNode[9] + fNode[13] + fNode[15]) 
    - (fNode[2] + fNode[8] + fNode[10] + fNode[14] + fNode[16]) + 0.5 * FX) * invRho;
    const dfloat uyVar = ((fNode[3] + fNode[7] + fNode[11] + fNode[14] + fNode[17])
     - (fNode[4] + fNode[8] + fNode[12] + fNode[13] + fNode[18]) + 0.5 * FY) * invRho;
    const dfloat uzVar = ((fNode[5] + fNode[9] + fNode[11] + fNode[16] + fNode[18])
     - (fNode[6] + fNode[10] + fNode[12] + fNode[15] + fNode[17]) + 0.5 * FZ) * invRho;
#endif // !D3Q19
#ifdef D3Q27
    const dfloat rhoVar = fNode[0] + fNode[1] + fNode[2] + fNode[3] + fNode[4] 
        + fNode[5] + fNode[6] + fNode[7] + fNode[8] + fNode[9] + fNode[10] 
        + fNode[11] + fNode[12] + fNode[13] + fNode[14] + fNode[15] + fNode[16] 
        + fNode[17] + fNode[18] + fNode[19] + fNode[20] + fNode[21] + fNode[22] 
        + fNode[23] + fNode[24] + fNode[25] + fNode[26];
    const dfloat invRho = 1 / rhoVar;
    const dfloat uxVar = ((fNode[1] + fNode[7] + fNode[9] + fNode[13] + fNode[15] 
        + fNode[19] + fNode[21] + fNode[23] + fNode[26]) 
        - (fNode[2] + fNode[8] + fNode[10] + fNode[14] + fNode[16] + fNode[20] 
        + fNode[22] + fNode[24] + fNode[25]) + 0.5 * FX) * invRho;
    const dfloat uyVar = ((fNode[3] + fNode[7] + fNode[11] + fNode[14] + fNode[17]
        + fNode[19] + fNode[21] + fNode[24] + fNode[25]) 
        - (fNode[4] + fNode[8] + fNode[12] + fNode[13] + fNode[18] + fNode[20] 
        + fNode[22] + fNode[23] + fNode[26]) + 0.5 * FY) * invRho;
    const dfloat uzVar = ((fNode[5] + fNode[9] + fNode[11] + fNode[16] + fNode[18]
        + fNode[19] + fNode[22] + fNode[23] + fNode[25]) 
        - (fNode[6] + fNode[10] + fNode[12] + fNode[15] + fNode[17] + fNode[20] 
        + fNode[21] + fNode[24] + fNode[26]) + 0.5 * FZ) * invRho;
#endif // !D3Q27

    macr.rho[idx] = rhoVar;
    macr.ux[idx] = uxVar;
    macr.uy[idx] = uyVar;
    macr.uz[idx] = uzVar;
}

__global__ void gpuResetNodesForces(ParticleNodeSoA particlesNodes)
{
    int idx = threadIdx.x + blockDim.x * blockIdx.x;

    if (idx >= particlesNodes.numNodes)
        return;

    const dfloat3SoA force = particlesNodes.f;
    const dfloat3SoA delta_force = particlesNodes.deltaF;

    force.x[idx] = 0;
    force.y[idx] = 0;
    force.z[idx] = 0;
    delta_force.x[idx] = 0;
    delta_force.y[idx] = 0;
    delta_force.z[idx] = 0;
}

__host__ void updateParticleCenterVelocityAndRotation(
    ParticleCenter particleCenters[NUM_PARTICLES])
{
    for (int p = 0; p < NUM_PARTICLES; p++)
    {
        ParticleCenter *pc = &(particleCenters[p]);
        // Update particle center velocity using its surface forces and the body forces
        pc->vel.x = pc->vel_old.x + (0.5 * (pc->f_old.x + pc->f.x) + (PARTICLE_DENSITY - FLUID_DENSITY) * GX) / PARTICLE_DENSITY;
        pc->vel.y = pc->vel_old.y + (0.5 * (pc->f_old.y + pc->f.y) + (PARTICLE_DENSITY - FLUID_DENSITY) * GY) / PARTICLE_DENSITY;
        pc->vel.z = pc->vel_old.z + (0.5 * (pc->f_old.z + pc->f.z) + (PARTICLE_DENSITY - FLUID_DENSITY) * GZ) / PARTICLE_DENSITY;

        // Auxiliary variables for angular velocity update
        dfloat error = 1;
        dfloat3 wNew = dfloat3(), wAux;
        const dfloat3 M = pc->M;
        const dfloat3 M_old = pc->M_old;
        const dfloat3 w_old = pc->w_old;
        const dfloat3 I = pc->I;

        wAux.x = w_old.x;
        wAux.y = w_old.y;
        wAux.z = w_old.z;

        // Iteration process to upadate angular velocity 
        // (Crank-Nicolson implicit scheme)
        for (int i = 0; error > 1e-6; i++)
        {
            wNew.x = pc->w_old.x + (0.5*(M.x + M_old.x) - (I.z - I.y)*0.25*(w_old.y + wAux.y)*(w_old.z + wAux.z))/I.x;
            wNew.y = pc->w_old.y + (0.5*(M.y + M_old.y) - (I.x - I.z)*0.25*(w_old.x + wAux.x)*(w_old.z + wAux.z))/I.y;
            wNew.z = pc->w_old.z + (0.5*(M.z + M_old.z) - (I.y - I.x)*0.25*(w_old.x + wAux.x)*(w_old.y + wAux.y))/I.z;

            error = (wNew.x - wAux.x)*(wNew.x - wAux.x)/(wNew.x*wNew.x);
            error += (wNew.y - wAux.y)*(wNew.y - wAux.y)/(wNew.y*wNew.y);
            error += (wNew.z - wAux.z)*(wNew.z - wAux.z)/(wNew.z*wNew.z);

            wAux.x = wNew.x;
            wAux.y = wNew.y;
            wAux.z = wNew.z;
        }
        // Store new velocities in particle center
        pc->w.x = wNew.x;
        pc->w.y = wNew.x;
        pc->w.z = wNew.x;
    }
}


__host__
void particleMovement(
    ParticleCenter particleCenters[NUM_PARTICLES])
{
    for (int p = 0; p < NUM_PARTICLES; p++){
        ParticleCenter *pc = &(particleCenters[p]);

        pc->pos_old.x = pc->pos.x;
        pc->pos_old.y = pc->pos.y;
        pc->pos_old.z = pc->pos.z;

        pc->pos.x += 0.5 * (pc->vel.x + pc->vel_old.x);
        pc->pos.y += 0.5 * (pc->vel.y + pc->vel_old.y);
        pc->pos.z += 0.5 * (pc->vel.z + pc->vel_old.z);

        pc->vel_old.x = pc->vel.x;
        pc->vel_old.y = pc->vel.y;
        pc->vel_old.z = pc->vel.z;

        pc->w_avg.x = 0.5 * (pc->w.x + pc->w_old.x);
        pc->w_avg.y = 0.5 * (pc->w.y + pc->w_old.y);
        pc->w_avg.z = 0.5 * (pc->w.z + pc->w_old.z);

        pc->w_old.x = pc->w.x;
        pc->w_old.y = pc->w.y;
        pc->w_old.z = pc->w.z;
    }
}

__global__
void gpuParticleNodeMovement(
    ParticleNodeSoA const particlesNodes,
    ParticleCenter particleCenters[NUM_PARTICLES]
){
    int i = threadIdx.x + blockDim.x * blockIdx.x;

    if(i >= particlesNodes.numNodes)
        return;

    const ParticleCenter pc = particleCenters[particlesNodes.particleCenterIdx[i]];

    // TODO: make the calculation of w_norm along with w_avg?
    const dfloat w_norm = sqrt((pc.w_avg.x * pc.w_avg.x) 
        + (pc.w_avg.y * pc.w_avg.y) 
        + (pc.w_avg.z * pc.w_avg.z));

    if(w_norm <= 1e-8)
    {
        particlesNodes.pos.x[i] += pc.pos.x - pc.pos_old.x;
        particlesNodes.pos.y[i] += pc.pos.y - pc.pos_old.y;
        particlesNodes.pos.z[i] += pc.pos.z - pc.pos_old.z; 
        return;
    }

    // TODO: these variables are the same for every particle center, optimize it
    const dfloat q0 = cos(0.5*w_norm);
    const dfloat qi = (pc.w_avg.x/w_norm) * sin (0.5*w_norm);
    const dfloat qj = (pc.w_avg.y/w_norm) * sin (0.5*w_norm);
    const dfloat qk = (pc.w_avg.z/w_norm) * sin (0.5*w_norm);

    const dfloat tq0m1 = (q0*q0) - 0.5;

    const dfloat x_vec = particlesNodes.pos.x[i] - pc.pos_old.x;
    const dfloat y_vec = particlesNodes.pos.y[i] - pc.pos_old.y;
    const dfloat z_vec = particlesNodes.pos.z[i] - pc.pos_old.z;

    particlesNodes.pos.x[i] = pc.pos.x + 2 * (   (tq0m1 + (qi*qi))*x_vec + ((qi*qj) - (q0*qk))*y_vec + ((qi*qk) + (q0*qj))*z_vec);
    particlesNodes.pos.y[i] = pc.pos.y + 2 * ( ((qi*qj) + (q0*qk))*x_vec +   (tq0m1 + (qj*qj))*y_vec + ((qj*qk) - (q0*qi))*z_vec);
    particlesNodes.pos.z[i] = pc.pos.z + 2 * ( ((qi*qj) - (q0*qj))*x_vec + ((qj*qk) + (q0*qi))*y_vec +   (tq0m1 + (qk*qk))*z_vec);
}

/*
__host__ 
dfloat3 particleCollisionSoft(
    ParticleCenter* __restrict__ particleCenter,
    int particleIndex)
{

}
*/

#endif // !IBM