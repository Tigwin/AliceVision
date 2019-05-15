// This file is part of the AliceVision project.
// Copyright (c) 2017 AliceVision contributors.
// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

namespace aliceVision {
namespace depthMap {

/**
 * @param[in] s: iteration over samples [-nSamplesHalf:nSamplesHalf]
 * @param[in] idCam: 
 * @param[in] samplesPerPixSize: global number of samples per pixelSize
 */
__global__ void fuse_computeGaussianKernelVotingSampleMap_kernel(float* out_gsvSampleMap, int out_gsvSampleMap_p,
                                                                 const float2* depthSimMap, int depthSimMap_p,
                                                                 const float2* midDepthPixSizeMap, int midDepthPixSizeMap_p,
                                                                 int width, int height, float s, int idCam,
                                                                 float samplesPerPixSize, float twoTimesSigmaPowerTwo)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if(x >= width || y >= height)
        return;

    float2 midDepthPixSize = *get2DBufferAt(midDepthPixSizeMap, midDepthPixSizeMap_p, x, y);
    float2 depthSim = *get2DBufferAt(depthSimMap, depthSimMap_p, x, y);
    float* out_gsvSample_ptr = get2DBufferAt(out_gsvSampleMap, out_gsvSampleMap_p, x, y);
    float gsvSample = (idCam == 0) ? 0.0f : *out_gsvSample_ptr;

    if((midDepthPixSize.x > 0.0f) && (depthSim.x > 0.0f))
    {
        // depthStep: the step used based on the pixelSize and the number of samples for the optimization
        float depthStep = midDepthPixSize.y / samplesPerPixSize;
        // i: index of the iteration within the depths
        float i = (midDepthPixSize.x - depthSim.x) / depthStep;
        // convert similarity:
        //  * inputSim < -0.7 is good ==> -1
        //  * inputSim > -0.7 is bad ==> 0
        float sim = -sigmoid(0.0f, 1.0f, 0.7f, -0.7f, depthSim.y);
        // gsvSample: gaussian weighted sum of similarity
        //            the gaussian curve is centered on the iteration "s" (in practive between [-150, +150])
        gsvSample += sim * expf(-((i - s) * (i - s)) / twoTimesSigmaPowerTwo);
    }
    *out_gsvSample_ptr = gsvSample;
}


__global__ void fuse_updateBestGaussianKernelVotingSampleMap_kernel(float2* out_bestGsvSampleMap, int bestGsvSampleMap_p,
                                                                    const float* gsvSampleMap, int gsvSampleMap_p, int width,
                                                                    int height, float s, int id)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if(x >= width || y >= height)
        return;

    float gsvSampleX = *get2DBufferAt(gsvSampleMap, gsvSampleMap_p, x, y);
    float2* bestGsvSample_ptr = get2DBufferAt(out_bestGsvSampleMap, bestGsvSampleMap_p, x, y);
    if(id == 0 || gsvSampleX < bestGsvSample_ptr->x)
        *bestGsvSample_ptr = make_float2(gsvSampleX, s);
}

__global__ void fuse_computeFusedDepthSimMapFromBestGaussianKernelVotingSampleMap_kernel(
    float2* oDepthSimMap, int oDepthSimMap_p, float2* bestGsvSampleMap, int bestGsvSampleMap_p,
    float2* midDepthPixSizeMap, int midDepthPixSizeMap_p, int width, int height, float samplesPerPixSize)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if(x >= width || y >= height)
        return;
    float2 bestGsvSample = *get2DBufferAt(bestGsvSampleMap, bestGsvSampleMap_p, x, y);
    float2 midDepthPixSize = *get2DBufferAt(midDepthPixSizeMap, midDepthPixSizeMap_p, x, y);
    float depthStep = midDepthPixSize.y / samplesPerPixSize;

    // normalize similarity to -1,0
    // figure; t = -5.0:0.01:0.0; plot(t,sigmoid(0.0,-1.0,6.0,-0.4,t,0));
    //bestGsvSample.x = sigmoid(0.0f, -1.0f, 6.0f, -0.4f, bestGsvSample.x);
    float2* oDepthSim = get2DBufferAt(oDepthSimMap, oDepthSimMap_p, x, y);
    if(midDepthPixSize.x <= 0.0f)
        *oDepthSim = make_float2(-1.0f, 1.0f);
    else
        *oDepthSim = make_float2(midDepthPixSize.x - bestGsvSample.y * depthStep, bestGsvSample.x);
}

__global__ void fuse_getOptDeptMapFromOPtDepthSimMap_kernel(float* optDepthMap, int optDepthMap_p,
                                                            float2* optDepthMapSimMap, int optDepthMapSimMap_p,
                                                            int width, int height)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if(x < width && y < height)
    {
        *get2DBufferAt(optDepthMap, optDepthMap_p, x, y) = get2DBufferAt(optDepthMapSimMap, optDepthMapSimMap_p, x, y)->x;
    }
}

/**
 * @return (smoothStep, energy)
 */
__device__ float2 getCellSmoothStepEnergy(const CameraStructBase& rc_cam, cudaTextureObject_t depthTex, const int2& cell0)
{
    float2 out = make_float2(0.0f, 180.0f);

    // Get pixel depth from the depth texture
    float d0 = tex2D<float>(depthTex, float(cell0.x)+0.5f, float(cell0.y) + 0.5f);

    // Early exit: depth is <= 0
    if(d0 <= 0.0f)
        return out;

    // Consider the neighbor pixels
    int2 cellL = cell0 + make_int2(0, -1);	// Left
    int2 cellR = cell0 + make_int2(0, 1);	// Right
    int2 cellU = cell0 + make_int2(-1, 0);	// Up
    int2 cellB = cell0 + make_int2(1, 0);	// Bottom

    // Get associated depths from depth texture
    float dL = tex2D<float>(depthTex, float(cellL.x) + 0.5f, float(cellL.y) + 0.5f);
    float dR = tex2D<float>(depthTex, float(cellR.x) + 0.5f, float(cellR.y) + 0.5f);
    float dU = tex2D<float>(depthTex, float(cellU.x) + 0.5f, float(cellU.y) + 0.5f);
    float dB = tex2D<float>(depthTex, float(cellB.x) + 0.5f, float(cellB.y) + 0.5f);

    // Get associated 3D points
    float3 p0 = get3DPointForPixelAndDepthFromRC(rc_cam, cell0, d0);
    float3 pL = get3DPointForPixelAndDepthFromRC(rc_cam, cellL, dL);
    float3 pR = get3DPointForPixelAndDepthFromRC(rc_cam, cellR, dR);
    float3 pU = get3DPointForPixelAndDepthFromRC(rc_cam, cellU, dU);
    float3 pB = get3DPointForPixelAndDepthFromRC(rc_cam, cellB, dB);

    // Compute the average point based on neighbors (cg)
    float3 cg = make_float3(0.0f, 0.0f, 0.0f);
    float n = 0.0f;

    if(dL > 0.0f) { cg = cg + pL; n++; }
    if(dR > 0.0f) { cg = cg + pR; n++; }
    if(dU > 0.0f) { cg = cg + pU; n++; }
    if(dB > 0.0f) { cg = cg + pB; n++; }

    // If we have at least one valid depth
    if(n > 1.0f)
    {
        cg = cg / n; // average of x, y, depth
        float3 vcn = rc_cam.C - p0;
        normalize(vcn);
        // pS: projection of cg on the line from p0 to camera
        float3 pS = closestPointToLine3D(cg, p0, vcn);
        // keep the depth difference between pS and p0 as the smoothing step
        out.x = size(rc_cam.C - pS) - d0;
    }

    float e = 0.0f;
    n = 0.0f;

    if(dL > 0.0f && dR > 0.0f)
    {
        // Large angle between neighbors == flat area => low energy
        // Small angle between neighbors == non-flat area => high energy
        e = fmaxf(e, (180.0f - angleBetwABandAC(p0, pL, pR)));
        n++;
    }
    if(dU > 0.0f && dB > 0.0f)
    {
        e = fmaxf(e, (180.0f - angleBetwABandAC(p0, pU, pB)));
        n++;
    }
    // The higher the energy, the less flat the area
    if(n > 0.0f)
        out.y = e;

    return out;
}

__global__ void fuse_optimizeDepthSimMap_kernel(cudaTextureObject_t rc_tex,
                                                const CameraStructBase& rc_cam,
                                                cudaTextureObject_t varianceTex,
                                                cudaTextureObject_t depthTex,
                                                float2* out_optDepthSimMap, int optDepthSimMap_p,
                                                float2* midDepthPixSizeMap, int midDepthPixSizeMap_p,
                                                float2* fusedDepthSimMap, int fusedDepthSimMap_p, int width, int height,
                                                int iter, float samplesPerPixSize, int yFrom)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int2 pix = make_int2(x, y);

    if(x >= width || y >= height)
        return;

    float2 midDepthPixSize = *get2DBufferAt(midDepthPixSizeMap, midDepthPixSizeMap_p, x, y);
    float2 fusedDepthSim = *get2DBufferAt(fusedDepthSimMap, fusedDepthSimMap_p, x, y);
    float2* out_optDepthSim_ptr = get2DBufferAt(out_optDepthSimMap, optDepthSimMap_p, x, y);
    float2 out_optDepthSim = (iter == 0) ? make_float2(midDepthPixSize.x, fusedDepthSim.y) : *out_optDepthSim_ptr;

    float depthOpt = out_optDepthSim.x;

    if(depthOpt > 0.0f)
    {
        float2 depthSmoothStepEnergy = getCellSmoothStepEnergy(rc_cam, depthTex, pix); // (smoothStep, energy)
        float depthSmoothStep = depthSmoothStepEnergy.x;
        if(depthSmoothStep < 0.0f)
        {
            depthSmoothStep = -fminf(fabsf(depthSmoothStep), midDepthPixSize.y / 10.0f);
        }
        else
        {
            depthSmoothStep = +fminf(fabsf(depthSmoothStep), midDepthPixSize.y / 10.0f);
        }

        float depthPhotoStep = fusedDepthSim.x - depthOpt;
        if(depthPhotoStep < 0.0f)
        {
            depthPhotoStep = -fminf(fabsf(depthPhotoStep), midDepthPixSize.y / 10.0f);
        }
        else
        {
            depthPhotoStep = +fminf(fabsf(depthPhotoStep), midDepthPixSize.y / 10.0f);
        }

        float depthVisStep = midDepthPixSize.x - depthOpt;

        float depthEnergy = depthSmoothStepEnergy.y;
        float sim = fusedDepthSim.y;

        float colorVariance = tex2D<float>(varianceTex, float(x) + 0.5f, float(y + yFrom) + 0.5f);

        // archive: 
        // float weightedColorVariance = sigmoid2(5.0f, 60.0f, 10.0f, 5.0f, colorVariance);
        // 0.6:
        float weightedColorVariance = sigmoid2(5.0f, 30.0f, 40.0f, 20.0f, colorVariance);

        // archive: 
        // float simWeight = -sim; // must be from 0 to 1=from worst=0 to best=1 ... it is from -1 to 0
        // 0.6:
        float simWeight = sigmoid(0.0f, 1.0f, 0.7f, -0.7f, sim);

        // archive: 
        // float photoWeight = sigmoid(0.0f, 1.0f, 60.0f, weightedColorVariance, depthEnergy);
        // 0.6:
        float photoWeight = sigmoid(0.0f, 1.0f, 30.0f, weightedColorVariance, depthEnergy);

        float smoothWeight = 1.0f - photoWeight;
        float visWeight = 1.0f - sigmoid(0.0f, 1.0f, 10.0f, 17.0f, fabsf(depthVisStep / midDepthPixSize.y));

        float depthOptStep = visWeight*depthVisStep + (1.0f - visWeight)*(photoWeight*simWeight*depthPhotoStep + smoothWeight*depthSmoothStep);

        out_optDepthSim.x = depthOpt + depthOptStep;

        // archive: 
        // out_optDepthSim.y = -photoWeight * simWeight
        // 0.6:
        out_optDepthSim.y = (1.0f - visWeight)*photoWeight*simWeight*sim + (1.0f - visWeight)*smoothWeight*(depthEnergy / 20.0f);
    }

    *out_optDepthSim_ptr = out_optDepthSim;
}

} // namespace depthMap
} // namespace aliceVision
