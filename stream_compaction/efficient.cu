#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }

        #define blockSize 8

        int* dev_idata;
        int* dev_odata;
        int* dev_buf;

        __global__ void upSweep(int N, int* idata, int* odata, int depth) {
            int k = threadIdx.x + (blockIdx.x * blockDim.x);
            if (k >= N) {
                return;
            }
            if ((k+1)%(1 << depth) == 0) {
                odata[k] = idata[k] + idata[k - (1 << (depth-1))];
            }
            else {
                odata[k] = idata[k];
            }
        }

        __global__ void downSweep(int N, int* idata, int* odata, int depth) {
            int k = threadIdx.x + (blockIdx.x * blockDim.x);
            if (k >= N) {
                return;
            }

            if ((k + 1) % (1 << depth) == 0) {
                if ((k + 1) % (1 << (depth + 1)) == 0) {
                    odata[k] = idata[k - (1 << depth)] + idata[k];
                }
                else {
                    odata[k] = idata[k + (1 << depth)];
                }
            }
            else {
                odata[k] = idata[k];
            }
        }

        __global__ void toInclusive(int N, int* idata, int* odata, int* buf) {
            int k = threadIdx.x + (blockIdx.x * blockDim.x);
            if (k >= N) {
                return;
            }
            if (k < N-1){
                odata[k] = buf[k + 1];
            }
            else {
                odata[k] = buf[k] + idata[k];
            }
        }

        __global__ void scatter(int N, int* idata, int* odata, int* buf) {
            int k = threadIdx.x + (blockIdx.x * blockDim.x);
            if (k >= N) {
                return;
            }
            if (k == 0 && idata[k] > 0) {
                odata[k] = idata[k];
            }
            else {
                if (buf[k] > buf[k-1]) {
                    odata[buf[k] - 1] = idata[k];
                }
            }
            
            //odata[k] = buf[k];
        }

        __global__ void binarize(int N, int* idata, int* odata) {
            int k = threadIdx.x + (blockIdx.x * blockDim.x);
            if (k >= N) {
                return;
            }
            idata[k] == 0 ? odata[k] = 0 : odata[k] = 1;
        }

        void zeroArray(int n, int* a) {
            for (int i = 0; i < n; i++) {
                a[i] = 0;
            }
        }

        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
        void scan(int n, int* odata, const int* idata) {
            timer().startGpuTimer();
            int arrLen;
            int maxDepth = ilog2ceil(n);
            maxDepth > ilog2(n) ? arrLen = pow(2, maxDepth) : arrLen = n;
            zeroArray(arrLen, odata);

            dim3 threadsPerBlock(arrLen / blockSize);

            int* buf = new int[arrLen];

            for (int i = 0; i < arrLen; i++) {
                if (i < n) {
                    buf[i] = idata[i];
                }
                else {
                    buf[i] = 0;
                }
            }

            cudaMalloc((void**)&dev_idata, n * sizeof(int));
            cudaMalloc((void**)&dev_odata, arrLen * sizeof(int));
            cudaMalloc((void**)&dev_buf, arrLen * sizeof(int));

            cudaMemcpy(dev_idata, idata, sizeof(int) * n, cudaMemcpyHostToDevice);
            cudaMemcpy(dev_odata, odata, sizeof(int) * arrLen, cudaMemcpyHostToDevice);
            cudaMemcpy(dev_buf, buf, sizeof(int) * arrLen, cudaMemcpyHostToDevice);

            for (int i = 1; i <= maxDepth; i++) {
                upSweep << <threadsPerBlock, blockSize >> > (arrLen, dev_buf, dev_odata, i);
                cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);
            }

            cudaMemset(&dev_buf[arrLen - 1], 0, sizeof(int) * 1);

            for (int i = maxDepth - 1; i >= 0; i--) {
                downSweep << <threadsPerBlock, blockSize >> > (arrLen, dev_buf, dev_odata, i);
                cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);
            }

            toInclusive << <threadsPerBlock, blockSize >> > (arrLen, dev_idata, dev_odata, dev_buf);

            cudaMemcpy((void**)idata, dev_idata, sizeof(int) * n, cudaMemcpyDeviceToHost);
            cudaMemcpy(odata, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToHost);
            cudaMemcpy(buf, dev_buf, sizeof(int) * arrLen, cudaMemcpyDeviceToHost);

            cudaFree(dev_idata);
            cudaFree(dev_odata);
            cudaFree(dev_buf);


            timer().endGpuTimer();
        }

        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {
            timer().startGpuTimer();
            
            int arrLen;
            int maxDepth = ilog2ceil(n);
            maxDepth > ilog2(n) ? arrLen = pow(2, maxDepth) : arrLen = n;
            zeroArray(arrLen, odata);

            dim3 threadsPerBlock(arrLen / blockSize);

            int* buf = new int[arrLen];

            for (int i = 0; i < arrLen; i++) {
                if (i < n) {
                    buf[i] = idata[i];
                }
                else {
                    buf[i] = 0;
                }
            }

            cudaMalloc((void**)&dev_idata, n * sizeof(int));
            cudaMalloc((void**)&dev_odata, arrLen * sizeof(int));
            cudaMalloc((void**)&dev_buf, arrLen * sizeof(int));

            cudaMemcpy(dev_idata, idata, sizeof(int) * n, cudaMemcpyHostToDevice);
            cudaMemcpy(dev_odata, odata, sizeof(int) * arrLen, cudaMemcpyHostToDevice);
            cudaMemcpy(dev_buf, buf, sizeof(int) * arrLen, cudaMemcpyHostToDevice);

            binarize << <threadsPerBlock, blockSize >> > (arrLen, dev_idata, dev_odata);
            cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);

            for (int i = 1; i <= maxDepth; i++) {
                upSweep << <threadsPerBlock, blockSize >> > (arrLen, dev_buf, dev_odata, i);
                cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);
            }

            cudaMemset(&dev_buf[arrLen - 1], 0, sizeof(int) * 1);

            for (int i = maxDepth - 1; i >= 0; i--) {
                downSweep << <threadsPerBlock, blockSize >> > (arrLen, dev_buf, dev_odata, i);
                cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);
            }

            toInclusive << <threadsPerBlock, blockSize >> > (arrLen, dev_idata, dev_odata, dev_buf);

            cudaMemcpy(odata, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToHost);
            int retLen = odata[n - 1];

            cudaMemcpy(dev_buf, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToDevice);

            scatter << <threadsPerBlock, blockSize >> > (arrLen, dev_idata, dev_odata, dev_buf);

            cudaMemcpy((void**)idata, dev_idata, sizeof(int) * n, cudaMemcpyDeviceToHost);
            cudaMemcpy(odata, dev_odata, sizeof(int) * arrLen, cudaMemcpyDeviceToHost);
            cudaMemcpy(buf, dev_buf, sizeof(int) * arrLen, cudaMemcpyDeviceToHost);

            cudaFree(dev_idata);
            cudaFree(dev_odata);
            cudaFree(dev_buf);
            
            timer().endGpuTimer();
            return retLen;
        }
    }
}
