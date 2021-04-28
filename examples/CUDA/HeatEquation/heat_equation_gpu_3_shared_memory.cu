#include <algorithm>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pngwriter.h"

#define BLOCK_SIZE_X 16
#define BLOCK_SIZE_Y 16

/* Convert 2D index layout to unrolled 1D layout
 *
 * \param[in] i      Row index
 * \param[in] j      Column index
 * \param[in] width  The width of the area
 * 
 * \returns An index in the unrolled 1D array.
 */
int __host__ __device__ getIndex(const int i, const int j, const int width)
{
    return i*width + j;
}

__global__ void evolve_kernel(const float* Un, float* Unp1, const int nx, const int ny, const float dx2, const float dy2, const float aTimesDt)
{
    __shared__ float s_Un[(BLOCK_SIZE_X + 2)*(BLOCK_SIZE_Y + 2)];
    int i = threadIdx.x + blockIdx.x*blockDim.x;
    int j = threadIdx.y + blockIdx.y*blockDim.y;

    int s_i = threadIdx.x + 1;
    int s_j = threadIdx.y + 1;
    int s_nx = BLOCK_SIZE_X + 2;

    // Load data into shared memory
    // Central square
    s_Un[getIndex(s_i, s_j, s_nx)] = Un[getIndex(i, j, nx)];
    // Top border
    if (s_i == 1 && i != 0)
    {
        s_Un[getIndex(0, s_j, s_nx)] = Un[getIndex(blockIdx.x*blockDim.x - 1, j, nx)];
    }
    // Bottom border
    if (s_i == BLOCK_SIZE_X && i != nx - 1)
    {
        s_Un[getIndex(BLOCK_SIZE_X + 1, s_j, s_nx)] = Un[getIndex((blockIdx.x + 1)*blockDim.x, j, nx)];
    }
    // Left border
    if (s_j == 1 && j != 0)
    {
        s_Un[getIndex(s_i, 0, s_nx)] = Un[getIndex(i, blockIdx.y*blockDim.y - 1, nx)];
    }
    // Right border
    if (s_j == BLOCK_SIZE_Y && j != ny - 1)
    {
        s_Un[getIndex(s_i, BLOCK_SIZE_Y + 1, s_nx)] = Un[getIndex(i, (blockIdx.y + 1)*blockDim.y, nx)];
    }

    // Make sure all the data is loaded before computing
    __syncthreads();

    if (i > 0 && i < nx - 1)
    {
        if (j > 0 && j < ny - 1)
        {
            float uij = s_Un[getIndex(s_i, s_j, s_nx)];
            float uim1j = s_Un[getIndex(s_i-1, s_j, s_nx)];
            float uijm1 = s_Un[getIndex(s_i, s_j-1, s_nx)];
            float uip1j = s_Un[getIndex(s_i+1, s_j, s_nx)];
            float uijp1 = s_Un[getIndex(s_i, s_j+1, s_nx)];

            // Explicit scheme
            Unp1[getIndex(i, j, nx)] = uij + aTimesDt * ( (uim1j - 2.0*uij + uip1j)/dx2 + (uijm1 - 2.0*uij + uijp1)/dy2 );
        }
    }
}

int main()
{
    const int nx = 200;   // Width of the area
    const int ny = 200;   // Height of the area

    const float a = 0.5;     // Diffusion constant

    const float dx = 0.01;   // Horizontal grid spacing 
    const float dy = 0.01;   // Vertical grid spacing

    const float dx2 = dx*dx;
    const float dy2 = dy*dy;

    const float dt = dx2 * dy2 / (2.0 * a * (dx2 + dy2)); // Largest stable time step
    const int numSteps = 500;                             // Number of time steps
    const int outputEvery = 100;                          // How frequently to write output image

    int numElements = nx*ny;

    // Allocate two sets of data for current and next timesteps
    float* h_Un   = (float*)calloc(numElements, sizeof(float));

    // Initializing the data with a pattern of disk of radius of 1/6 of the width
    float radius2 = (nx/6.0) * (nx/6.0);
    for (int i = 0; i < nx; i++)
    {
        for (int j = 0; j < ny; j++)
        {
            int index = getIndex(i, j, nx);
            // Distance of point i, j from the origin
            float ds2 = (i - nx/2) * (i - nx/2) + (j - ny/2)*(j - ny/2);
            if (ds2 < radius2)
            {
                h_Un[index] = 65.0;
            }
            else
            {
                h_Un[index] = 5.0;
            }
        }
    }

    float* d_Un;
    float* d_Unp1;

    cudaMalloc((void**)&d_Un, numElements*sizeof(float));
    cudaMalloc((void**)&d_Unp1, numElements*sizeof(float));

    cudaMemcpy(d_Un, h_Un, numElements*sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_Unp1, h_Un, numElements*sizeof(float), cudaMemcpyHostToDevice);

    dim3 numBlocks(nx/BLOCK_SIZE_X + 1, ny/BLOCK_SIZE_Y + 1);
    dim3 threadsPerBlock(BLOCK_SIZE_X, BLOCK_SIZE_Y);

    // Main loop
    for (int n = 0; n < numSteps; n++)
    {
        evolve_kernel<<<numBlocks, threadsPerBlock>>>(d_Un, d_Unp1, nx, ny, dx2, dy2, a*dt);

        // Write the output if needed
        if (n % outputEvery == 0)
        {
            cudaMemcpy(h_Un, d_Un, numElements*sizeof(float), cudaMemcpyDeviceToHost);
            cudaError_t errorCode = cudaGetLastError();
            if (errorCode != cudaSuccess)
            {
                printf("Cuda error %d: %s\n", errorCode, cudaGetErrorString(errorCode));
                exit(0);
            }
            char filename[64];
            sprintf(filename, "heat_%04d.png", n);
            save_png(h_Un, nx, ny, filename, 'c');
        }

        std::swap(d_Un, d_Unp1);
    }

    // Release the memory
    free(h_Un);

    cudaFree(d_Un);
    cudaFree(d_Unp1);
    
    return 0;
}
