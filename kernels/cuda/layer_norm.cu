/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <assert.h>
#include <cub/cub.cuh>
#include <math_constants.h>

#include <tensor.h>
#include <kernels/registry.h>

namespace rwkv {

namespace cuda {

namespace layer_norm {

constexpr int kWarpSize = 32;

template <typename T> struct SumOp {
  __device__ __forceinline__ T operator()(const T &a, const T &b) const {
    return a + b;
  }
};

template <typename T> struct MaxOp {
  __device__ __forceinline__ T operator()(const T &a, const T &b) const {
    return max(a, b);
  }
};

template <template <typename> class ReductionOp, typename T,
          int thread_group_width = kWarpSize>
__inline__ __device__ T WarpAllReduce(T val) {
  for (int mask = thread_group_width / 2; mask > 0; mask /= 2) {
    val = ReductionOp<T>()(
        val, __shfl_xor_sync(0xffffffff, val, mask, thread_group_width));
  }
  return val;
}

template <template <typename> class ReductionOp, typename T, int block_size>
__inline__ __device__ T BlockAllReduce(T val) {
  typedef cub::BlockReduce<T, block_size> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  __shared__ T result_broadcast;
  T result = BlockReduce(temp_storage).Reduce(val, ReductionOp<T>());
  if (threadIdx.x == 0) {
    result_broadcast = result;
  }
  __syncthreads();
  return result_broadcast;
}

template <typename T> __inline__ __device__ T Div(T a, T b);

template <> __inline__ __device__ float Div<float>(float a, float b) {
#ifdef OF_LAYER_NORM_USE_FAST_MATH
  return __fdividef(a, b);
#else
  return a / b;
#endif
}

template <> __inline__ __device__ double Div<double>(double a, double b) {
  return a / b;
}

template <typename T> __inline__ __device__ T Rsqrt(T x);

template <> __inline__ __device__ float Rsqrt<float>(float x) {
#ifdef OF_LAYER_NORM_USE_FAST_MATH
  return __frsqrt_rn(x);
#else
  return rsqrt(x);
#endif
}

template <> __inline__ __device__ double Rsqrt<double>(double x) {
  return rsqrt(x);
}

template <class Func>
inline cudaError_t GetNumBlocks(Func func, int64_t block_size,
                                size_t dynamic_smem_size, int64_t max_blocks,
                                int64_t waves, int *num_blocks) {
  int dev;
  {
    cudaError_t err = cudaGetDevice(&dev);
    if (err != cudaSuccess) {
      return err;
    }
  }
  int sm_count;
  {
    cudaError_t err =
        cudaDeviceGetAttribute(&sm_count, cudaDevAttrMultiProcessorCount, dev);
    if (err != cudaSuccess) {
      return err;
    }
  }
  int max_active_blocks;
  {
    cudaError_t err = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &max_active_blocks, func, block_size, dynamic_smem_size);
  }
  *num_blocks = std::max<int>(
      1, std::min<int64_t>(max_blocks, sm_count * max_active_blocks * waves));
  return cudaSuccess;
}

template <typename T> struct DefaultComputeType {
  using type = T;
};

template <> struct DefaultComputeType<half> {
  using type = float;
};

#if CUDA_VERSION >= 11000
template <> struct DefaultComputeType<nv_bfloat16> {
  using type = float;
};
#endif // CUDA_VERSION >= 11000

template <typename T> class HasCanPackAs {
  typedef char one;
  struct two {
    char x[2];
  };

  template <typename C> static one test(decltype(&C::CanPackAs));
  template <typename C> static two test(...);

public:
  enum { value = sizeof(test<T>(0)) == sizeof(char) };
};

template <typename T>
typename std::enable_if<HasCanPackAs<T>::value == true, bool>::type
CanPackAs(T t, size_t pack_size) {
  return t.CanPackAs(pack_size);
}

template <typename T>
typename std::enable_if<HasCanPackAs<T>::value == false, bool>::type
CanPackAs(T t, size_t pack_size) {
  return true;
}

template <typename T, int N> struct GetPackType {
  using type =
      typename std::aligned_storage<N * sizeof(T), N * sizeof(T)>::type;
};

template <typename T, int N> using PackType = typename GetPackType<T, N>::type;

template <typename T, int N> union Pack {
  static_assert(sizeof(PackType<T, N>) == sizeof(T) * N, "");
  __device__ Pack() {
    // do nothing
  }
  PackType<T, N> storage;
  T elem[N];
};

template <typename SRC, typename DST> struct DirectLoad {
  using LoadType = DST;
  DirectLoad(const SRC *src, int64_t row_size) : src(src), row_size(row_size) {}
  template <int N>
  __device__ void load(DST *dst, int64_t row, int64_t col) const {
    Pack<SRC, N> pack;
    const int64_t offset = (row * row_size + col) / N;
    pack.storage = *(reinterpret_cast<const PackType<SRC, N> *>(src) + offset);
#pragma unroll
    for (int i = 0; i < N; ++i) {
      dst[i] = static_cast<DST>(pack.elem[i]);
    }
  }
  const SRC *src;
  int64_t row_size;
};

template <typename SRC, typename DST> struct DirectStore {
  DirectStore(DST *dst, int64_t row_size) : dst(dst), row_size(row_size) {}
  template <int N>
  __device__ void store(const SRC *src, int64_t row, int64_t col) {
    Pack<DST, N> pack;
    const int64_t offset = (row * row_size + col) / N;
#pragma unroll
    for (int i = 0; i < N; ++i) {
      pack.elem[i] = static_cast<DST>(src[i]);
    }
    *(reinterpret_cast<PackType<DST, N> *>(dst) + offset) = pack.storage;
  }
  DST *dst;
  int64_t row_size;
};

template <typename T>
inline __device__ void WelfordCombine(T val, T *mean, T *m2, T *count) {
  // Use Welford Online algorithem to compute mean and variance
  // For more details you can refer to:
  // https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford's_online_algorithm
  *count += 1;
  T delta1 = val - *mean;
  *mean += Div(delta1, *count);
  T delta2 = val - *mean;
  *m2 += delta1 * delta2;
}

template <typename T>
inline __device__ void WelfordCombine(T b_mean, T b_m2, T b_count, T *mean,
                                      T *m2, T *count) {
  if (b_count == 0) {
    return;
  }
  T new_count = *count + b_count;
  T nb_over_n = Div(b_count, new_count);
  T delta = b_mean - *mean;
  *mean += delta * nb_over_n;
  *m2 += b_m2 + delta * delta * (*count) * nb_over_n;
  *count = new_count;
}

template <typename T, int thread_group_width = kWarpSize>
__inline__ __device__ void WelfordWarpReduce(T thread_mean, T thread_m2,
                                             T thread_count, T *mean, T *m2,
                                             T *count) {
  *mean = thread_mean;
  *m2 = thread_m2;
  *count = thread_count;
  for (int mask = thread_group_width / 2; mask > 0; mask /= 2) {
    T b_mean = __shfl_down_sync(0xffffffff, *mean, mask, thread_group_width);
    T b_m2 = __shfl_down_sync(0xffffffff, *m2, mask, thread_group_width);
    T b_count = __shfl_down_sync(0xffffffff, *count, mask, thread_group_width);
    WelfordCombine(b_mean, b_m2, b_count, mean, m2, count);
  }
}

template <typename T, int thread_group_width = kWarpSize>
__inline__ __device__ void WelfordWarpAllReduce(T thread_mean, T thread_m2,
                                                T thread_count, T *mean, T *m2,
                                                T *count) {
  WelfordWarpReduce<T, thread_group_width>(thread_mean, thread_m2, thread_count,
                                           mean, m2, count);
  *mean = __shfl_sync(0xffffffff, *mean, 0, thread_group_width);
  *m2 = __shfl_sync(0xffffffff, *m2, 0, thread_group_width);
  *count = __shfl_sync(0xffffffff, *count, 0, thread_group_width);
}

template <typename T>
__inline__ __device__ void
WelfordBlockAllReduce(T thread_mean, T thread_m2, T thread_count,
                      T *result_mean, T *result_m2, T *result_count) {
  __shared__ T mean_shared[kWarpSize];
  __shared__ T m2_shared[kWarpSize];
  __shared__ T count_shared[kWarpSize];
  __shared__ T mean_result_broadcast;
  __shared__ T m2_result_broadcast;
  __shared__ T count_result_broadcast;
  const int lid = threadIdx.x % kWarpSize;
  const int wid = threadIdx.x / kWarpSize;
  T warp_mean = 0;
  T warp_m2 = 0;
  T warp_count = 0;
  WelfordWarpReduce(thread_mean, thread_m2, thread_count, &warp_mean, &warp_m2,
                    &warp_count);
  __syncthreads();
  if (lid == 0) {
    mean_shared[wid] = warp_mean;
    m2_shared[wid] = warp_m2;
    count_shared[wid] = warp_count;
  }
  __syncthreads();
  if (wid == 0) {
    if (threadIdx.x < blockDim.x / kWarpSize) {
      warp_mean = mean_shared[lid];
      warp_m2 = m2_shared[lid];
      warp_count = count_shared[lid];
    } else {
      warp_mean = static_cast<T>(0);
      warp_m2 = static_cast<T>(0);
      warp_count = static_cast<T>(0);
    }
    __syncwarp();
    T block_mean = 0;
    T block_m2 = 0;
    T block_count = 0;
    WelfordWarpReduce(warp_mean, warp_m2, warp_count, &block_mean, &block_m2,
                      &block_count);
    if (lid == 0) {
      mean_result_broadcast = block_mean;
      m2_result_broadcast = block_m2;
      count_result_broadcast = block_count;
    }
  }
  __syncthreads();
  *result_mean = mean_result_broadcast;
  *result_m2 = m2_result_broadcast;
  *result_count = count_result_broadcast;
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int max_cols_per_thread, int min_cols_per_thread,
          int thread_group_width, int rows_per_access, bool padding>
__global__ void LayerNormWarpImpl(LOAD load, STORE store, const int64_t rows,
                                  const int64_t cols, const double epsilon,
                                  ComputeType *mean,
                                  ComputeType *inv_variance) {
  using LoadType = typename LOAD::LoadType;
  static_assert(max_cols_per_thread % pack_size == 0, "");
  static_assert(min_cols_per_thread % pack_size == 0, "");
  static_assert(thread_group_width <= kWarpSize, "");
  static_assert(kWarpSize % thread_group_width == 0, "");
  constexpr int max_num_packs = max_cols_per_thread / pack_size;
  constexpr int min_num_packs = min_cols_per_thread / pack_size;
  assert(cols <= max_cols_per_thread * thread_group_width);
  ComputeType buf[rows_per_access][max_cols_per_thread];
  const int64_t global_thread_group_id = blockIdx.x * blockDim.y + threadIdx.y;
  const int64_t num_global_thread_group = gridDim.x * blockDim.y;
  const int64_t lane_id = threadIdx.x;
  const int64_t step = num_global_thread_group * rows_per_access;
  for (int64_t row = global_thread_group_id * rows_per_access; row < rows;
       row += step) {
    ComputeType thread_mean[rows_per_access];
    ComputeType thread_m2[rows_per_access];
    ComputeType thread_count[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      thread_mean[row_id] = 0;
      thread_m2[row_id] = 0;
      thread_count[row_id] = 0;
      ComputeType *row_buf = buf[row_id];
#pragma unroll
      for (int pack_id = 0; pack_id < min_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        LoadType pack[pack_size];
        load.template load<pack_size>(pack, row + row_id, col);
#pragma unroll
        for (int i = 0; i < pack_size; ++i) {
          row_buf[pack_offset + i] = static_cast<ComputeType>(pack[i]);
          WelfordCombine(row_buf[pack_offset + i], thread_mean + row_id,
                         thread_m2 + row_id, thread_count + row_id);
        }
      }
      for (int pack_id = min_num_packs; pack_id < max_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        if (!padding || col < cols) {
          LoadType pack[pack_size];
          load.template load<pack_size>(pack, row + row_id, col);
#pragma unroll
          for (int i = 0; i < pack_size; ++i) {
            row_buf[pack_offset + i] = static_cast<ComputeType>(pack[i]);
            WelfordCombine(row_buf[pack_offset + i], thread_mean + row_id,
                           thread_m2 + row_id, thread_count + row_id);
          }
        } else {
#pragma unroll
          for (int i = 0; i < pack_size; ++i) {
            row_buf[pack_offset + i] = 0;
          }
        }
      }
    }
    ComputeType warp_mean[rows_per_access];
    ComputeType warp_m2[rows_per_access];
    ComputeType warp_count[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      int global_row_id = row + row_id;
      ComputeType *row_buf = buf[row_id];
      WelfordWarpAllReduce<ComputeType, thread_group_width>(
          thread_mean[row_id], thread_m2[row_id], thread_count[row_id],
          warp_mean + row_id, warp_m2 + row_id, warp_count + row_id);
      ComputeType row_mean = warp_mean[row_id];
      ComputeType row_variance = max(Div(warp_m2[row_id], warp_count[row_id]),
                                     static_cast<ComputeType>(0.0));
      ComputeType row_inv_var =
          Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
      // if (lane_id == 0) {
      //   mean[global_row_id] = row_mean;
      //   inv_variance[global_row_id] = row_inv_var;
      // }
#pragma unroll
      for (int i = 0; i < max_cols_per_thread; ++i) {
        row_buf[i] = (row_buf[i] - row_mean) * row_inv_var;
      }
#pragma unroll
      for (int i = 0; i < min_num_packs; ++i) {
        const int col = (i * thread_group_width + lane_id) * pack_size;
        store.template store<pack_size>(row_buf + i * pack_size, global_row_id,
                                        col);
      }
#pragma unroll
      for (int i = min_num_packs; i < max_num_packs; ++i) {
        const int col = (i * thread_group_width + lane_id) * pack_size;
        if (!padding || col < cols) {
          store.template store<pack_size>(row_buf + i * pack_size,
                                          global_row_id, col);
        }
      }
    }
  }
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int max_cols_per_thread, int min_cols_per_thread,
          int thread_group_width, int rows_per_access, bool padding>
inline cudaError_t
LaunchLayerNormWarpImpl(cudaStream_t stream, LOAD load, STORE store,
                        const int64_t rows, const int64_t cols,
                        const double epsilon, ComputeType *mean,
                        ComputeType *inv_variance) {
  constexpr int block_size = 128;
  constexpr int waves = 32;
  static_assert(block_size % thread_group_width == 0, "");
  constexpr int thread_groups_per_block = block_size / thread_group_width;
  dim3 block_dim(thread_group_width, thread_groups_per_block);
  const int64_t num_blocks =
      (rows / rows_per_access + thread_groups_per_block - 1) /
      thread_groups_per_block;
  int grid_dim_x;
  {
    cudaError_t err = GetNumBlocks(
        LayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size,
                          max_cols_per_thread, min_cols_per_thread,
                          thread_group_width, rows_per_access, padding>,
        block_size, 0, num_blocks, waves, &grid_dim_x);
    if (err != cudaSuccess) {
      return err;
    }
  }
  LayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size, max_cols_per_thread,
                    min_cols_per_thread, thread_group_width, rows_per_access,
                    padding><<<grid_dim_x, block_dim, 0, stream>>>(
      load, store, rows, cols, epsilon, mean, inv_variance);
  return cudaPeekAtLastError();
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int max_cols_per_thread, int min_cols_per_thread,
          int thread_group_width, int rows_per_access>
inline cudaError_t
DispatchLayerNormWarpImplPadding(cudaStream_t stream, LOAD load, STORE store,
                                 const int64_t rows, const int64_t cols,
                                 const double epsilon, ComputeType *mean,
                                 ComputeType *inv_variance) {
  if (cols == max_cols_per_thread * thread_group_width) {
    // when not padding, min_cols_per_thread must equals to max_cols_per_thread,
    // pass max_cols_per_thread as min_cols_per_thread and max_cols_per_thread
    // param.
    return LaunchLayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size,
                                   max_cols_per_thread, max_cols_per_thread,
                                   thread_group_width, rows_per_access, false>(
        stream, load, store, rows, cols, epsilon, mean, inv_variance);
  } else {
    return LaunchLayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size,
                                   max_cols_per_thread, min_cols_per_thread,
                                   thread_group_width, rows_per_access, true>(
        stream, load, store, rows, cols, epsilon, mean, inv_variance);
  }
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size>
typename std::enable_if<pack_size == 1, cudaError_t>::type
DispatchLayerNormWarpImplCols(cudaStream_t stream, LOAD load, STORE store,
                              const int64_t rows, const int64_t cols,
                              const double epsilon, ComputeType *mean,
                              ComputeType *inv_variance) {
  if (cols <= 0) {
    return cudaErrorInvalidValue;
  }
#define DEFINE_ONE_ELIF(thread_group_width)                                    \
  else if (cols <= (thread_group_width)*pack_size) {                           \
    if (rows % 2 == 0) {                                                       \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType,        \
                                              pack_size, pack_size, 0,         \
                                              thread_group_width, 2>(          \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);       \
    } else {                                                                   \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType,        \
                                              pack_size, pack_size, 0,         \
                                              thread_group_width, 1>(          \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);       \
    }                                                                          \
  }
  DEFINE_ONE_ELIF(4)
  DEFINE_ONE_ELIF(8)
  DEFINE_ONE_ELIF(16)
  DEFINE_ONE_ELIF(32)
#undef DEFINE_ONE_ELIF
#define DEFINE_ONE_ELIF(max_col, min_col)                                      \
  else if (cols <= (max_col)*kWarpSize) {                                      \
    return DispatchLayerNormWarpImplPadding<                                   \
        LOAD, STORE, ComputeType, pack_size, max_col, min_col, kWarpSize, 1>(  \
        stream, load, store, rows, cols, epsilon, mean, inv_variance);         \
  }
  DEFINE_ONE_ELIF(2, 1)
  DEFINE_ONE_ELIF(4, 2)
  DEFINE_ONE_ELIF(8, 4)
  DEFINE_ONE_ELIF(12, 8)
  DEFINE_ONE_ELIF(16, 12)
  DEFINE_ONE_ELIF(20, 16)
  DEFINE_ONE_ELIF(24, 20)
  DEFINE_ONE_ELIF(28, 24)
  DEFINE_ONE_ELIF(32, 28)
#undef DEFINE_ONE_ELIF
  else {
    return cudaErrorInvalidValue;
  }
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size>
typename std::enable_if<pack_size == 2, cudaError_t>::type
DispatchLayerNormWarpImplCols(cudaStream_t stream, LOAD load, STORE store,
                              const int64_t rows, const int64_t cols,
                              const double epsilon, ComputeType *mean,
                              ComputeType *inv_variance) {
  if (cols <= 0) {
    return cudaErrorInvalidValue;
  }
#define DEFINE_ONE_ELIF(thread_group_width)                                    \
  else if (cols <= (thread_group_width)*pack_size) {                           \
    if (rows % 2 == 0) {                                                       \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType,        \
                                              pack_size, pack_size, 0,         \
                                              thread_group_width, 2>(          \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);       \
    } else {                                                                   \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType,        \
                                              pack_size, pack_size, 0,         \
                                              thread_group_width, 1>(          \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);       \
    }                                                                          \
  }
  DEFINE_ONE_ELIF(4)
  DEFINE_ONE_ELIF(8)
  DEFINE_ONE_ELIF(16)
  DEFINE_ONE_ELIF(32)
#undef DEFINE_ONE_ELIF
#define DEFINE_ONE_ELIF(max_col, min_col)                                      \
  else if ((cols <= (max_col)*kWarpSize) && (cols > (min_col)*kWarpSize)) {    \
    return DispatchLayerNormWarpImplPadding<                                   \
        LOAD, STORE, ComputeType, pack_size, max_col, min_col, kWarpSize, 1>(  \
        stream, load, store, rows, cols, epsilon, mean, inv_variance);         \
  }
  DEFINE_ONE_ELIF(4, 2)
  DEFINE_ONE_ELIF(8, 4)
  DEFINE_ONE_ELIF(12, 8)
  DEFINE_ONE_ELIF(16, 12)
  DEFINE_ONE_ELIF(20, 16)
  DEFINE_ONE_ELIF(24, 20)
  DEFINE_ONE_ELIF(28, 24)
  DEFINE_ONE_ELIF(32, 28)
#undef DEFINE_ONE_ELIF
  else {
    return cudaErrorInvalidValue;
  }
}

template <typename LOAD, typename STORE, typename ComputeType>
struct DispatchLayerNormWarpImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store,
                         const int64_t rows, const int64_t cols,
                         const double epsilon, ComputeType *mean,
                         ComputeType *inv_variance) {
    if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) &&
        CanPackAs<STORE>(store, 2)) {
      return DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template <typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t
DispatchLayerNormWarpImpl(cudaStream_t stream, LOAD load, STORE store,
                          const int64_t rows, const int64_t cols,
                          const double epsilon, ComputeType *mean,
                          ComputeType *inv_variance) {
  return DispatchLayerNormWarpImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int block_size>
__global__ void LayerNormBlockSMemImpl(LOAD load, STORE store,
                                       const int64_t rows, const int64_t cols,
                                       const double epsilon, ComputeType *mean,
                                       ComputeType *inv_variance) {
  using LoadType = typename LOAD::LoadType;
  extern __shared__ __align__(sizeof(double)) unsigned char shared_buf[];
  auto *buf = reinterpret_cast<LoadType *>(shared_buf);
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    ComputeType thread_mean = 0;
    ComputeType thread_m2 = 0;
    ComputeType thread_count = 0;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      load.template load<pack_size>(pack, row, pack_id * pack_size);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        buf[i * num_packs + pack_id] = pack[i];
        WelfordCombine(static_cast<ComputeType>(pack[i]), &thread_mean,
                       &thread_m2, &thread_count);
      }
    }
    ComputeType row_mean = 0;
    ComputeType row_m2 = 0;
    ComputeType row_count = 0;
    WelfordBlockAllReduce<ComputeType>(thread_mean, thread_m2, thread_count,
                                       &row_mean, &row_m2, &row_count);
    ComputeType row_variance =
        max(Div(row_m2, row_count), static_cast<ComputeType>(0.0));
    ComputeType row_inv_var =
        Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
    // if (threadIdx.x == 0) {
    //   mean[row] = row_mean;
    //   inv_variance[row] = row_inv_var;
    // }
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      ComputeType pack[pack_size];
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        pack[i] = (static_cast<ComputeType>(buf[i * num_packs + pack_id]) -
                   row_mean) *
                  row_inv_var;
      }
      store.template store<pack_size>(pack, row, pack_id * pack_size);
    }
  }
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int block_size>
inline cudaError_t
LaunchLayerNormBlockSMemImpl(cudaStream_t stream, LOAD load, STORE store,
                             int smem, const int64_t rows, const int64_t cols,
                             const double epsilon, ComputeType *mean,
                             ComputeType *inv_variance) {
  constexpr int waves = 32;
  int grid_dim_x;
  {
    cudaError_t err = GetNumBlocks(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size>,
        block_size, smem, rows, waves, &grid_dim_x);
    if (err != cudaSuccess) {
      return err;
    }
  }
  LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, smem, stream>>>(load, store, rows, cols,
                                                 epsilon, mean, inv_variance);
  return cudaPeekAtLastError();
}

template <typename Func>
cudaError_t MaximizeDynamicSharedMemorySize(Func func,
                                            const int max_smem_size) {
  cudaFuncAttributes attr{};
  cudaError_t err = cudaFuncGetAttributes(&attr, func);
  if (err != cudaSuccess) {
    return err;
  }
  constexpr int reserved_smem = 1024; // 1K
  return cudaFuncSetAttribute(func, cudaFuncAttributeMaxDynamicSharedMemorySize,
                              max_smem_size - attr.sharedSizeBytes -
                                  reserved_smem);
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size>
inline cudaError_t TryDispatchLayerNormBlockSMemImplBlockSize(
    cudaStream_t stream, LOAD load, STORE store, const int64_t rows,
    const int64_t cols, const double epsilon, ComputeType *mean,
    ComputeType *inv_variance, bool *success) {
  constexpr int block_size_conf_1 = 128;
  constexpr int block_size_conf_2 = 256;
  constexpr int block_size_conf_3 = 512;
  constexpr int block_size_conf_4 = 1024;

  int dev = 0;
  {
    cudaError_t err = cudaGetDevice(&dev);
    if (err != cudaSuccess) {
      return err;
    }
  }

  int sm_count = 0;
  {
    cudaError_t err =
        cudaDeviceGetAttribute(&sm_count, cudaDevAttrMultiProcessorCount, dev);
    if (err != cudaSuccess) {
      return err;
    }
  }

  static const bool max_smem_configed = [=]() {
    int max_smem_size = 0;
    cudaError_t err = cudaDeviceGetAttribute(
        &max_smem_size, cudaDevAttrMaxSharedMemoryPerBlockOptin, dev);
    if (err != cudaSuccess) {
      return false;
    }

    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_1>,
        max_smem_size);
    if (err != cudaSuccess) {
      return false;
    }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_2>,
        max_smem_size);
    if (err != cudaSuccess) {
      return false;
    }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_3>,
        max_smem_size);
    if (err != cudaSuccess) {
      return false;
    }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_4>,
        max_smem_size);
    if (err != cudaSuccess) {
      return false;
    }

    return true;
  }();

  const size_t smem = cols * sizeof(typename LOAD::LoadType);

  int max_active_blocks_conf_1;
  {
    cudaError_t err = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &max_active_blocks_conf_1,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_1>,
        block_size_conf_1, smem);
    if (err != cudaSuccess) {
      return err;
    }
  }
  if (max_active_blocks_conf_1 <= 0) {
    *success = false;
    return cudaSuccess;
  }

  int max_active_blocks_conf_4;
  {
    cudaError_t err = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &max_active_blocks_conf_4,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_4>,
        block_size_conf_4, smem);
    if (err != cudaSuccess) {
      return err;
    }
  }

  if (max_active_blocks_conf_4 == max_active_blocks_conf_1 ||
      (max_active_blocks_conf_4 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                                        block_size_conf_4>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  int max_active_blocks_conf_3;
  {
    cudaError_t err = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &max_active_blocks_conf_3,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_3>,
        block_size_conf_3, smem);
    if (err != cudaSuccess) {
      return err;
    }
  }
  if (max_active_blocks_conf_3 == max_active_blocks_conf_1 ||
      (max_active_blocks_conf_3 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                                        block_size_conf_3>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  int max_active_blocks_conf_2;
  {
    cudaError_t err = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
        &max_active_blocks_conf_2,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                               block_size_conf_2>,
        block_size_conf_2, smem);
    if (err != cudaSuccess) {
      return err;
    }
  }
  if (max_active_blocks_conf_2 == max_active_blocks_conf_1 ||
      (max_active_blocks_conf_2 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                                        block_size_conf_2>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  *success = true;
  return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size,
                                      block_size_conf_1>(
      stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
}

template <typename LOAD, typename STORE, typename ComputeType>
struct TryDispatchLayerNormBlockSMemImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store,
                         const int64_t rows, const int64_t cols,
                         const double epsilon, ComputeType *mean,
                         ComputeType *inv_variance, bool *success) {
    if (cols % 4 == 0 && CanPackAs<LOAD>(load, 4) &&
        CanPackAs<STORE>(store, 4)) {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE,
                                                        ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance,
          success);
    } else if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) &&
               CanPackAs<STORE>(store, 2)) {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE,
                                                        ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance,
          success);
    } else {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE,
                                                        ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance,
          success);
    }
  }
};

template <typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t
TryDispatchLayerNormBlockSMemImpl(cudaStream_t stream, LOAD load, STORE store,
                                  const int64_t rows, const int64_t cols,
                                  const double epsilon, ComputeType *mean,
                                  ComputeType *inv_variance, bool *success) {
  return TryDispatchLayerNormBlockSMemImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size,
          int block_size>
__global__ void __launch_bounds__(1024)
    LayerNormBlockUncachedImpl(LOAD load, STORE store, const int64_t rows,
                               const int64_t cols, const double epsilon,
                               ComputeType *mean, ComputeType *inv_variance) {
  using LoadType = typename LOAD::LoadType;
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    ComputeType thread_mean = 0;
    ComputeType thread_m2 = 0;
    ComputeType thread_count = 0;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      load.template load<pack_size>(pack, row, pack_id * pack_size);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        WelfordCombine(static_cast<ComputeType>(pack[i]), &thread_mean,
                       &thread_m2, &thread_count);
      }
    }
    ComputeType row_mean = 0;
    ComputeType row_m2 = 0;
    ComputeType row_count = 0;
    WelfordBlockAllReduce<ComputeType>(thread_mean, thread_m2, thread_count,
                                       &row_mean, &row_m2, &row_count);
    ComputeType row_variance =
        max(Div(row_m2, row_count), static_cast<ComputeType>(0.0));
    ComputeType row_inv_var =
        Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
    // if (threadIdx.x == 0) {
    //   mean[row] = row_mean;
    //   inv_variance[row] = row_inv_var;
    // }
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      ComputeType dst_pack[pack_size];
      const int pack_offset = pack_id * pack_size;
      load.template load<pack_size>(pack, row, pack_offset);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        dst_pack[i] =
            (static_cast<ComputeType>(pack[i]) - row_mean) * row_inv_var;
      }
      store.template store<pack_size>(dst_pack, row, pack_offset);
    }
  }
}

template <typename LOAD, typename STORE, typename ComputeType, int pack_size>
inline cudaError_t
LaunchLayerNormBlockUncachedImpl(cudaStream_t stream, LOAD load, STORE store,
                                 const int64_t rows, const int64_t cols,
                                 const double epsilon, ComputeType *mean,
                                 ComputeType *inv_variance) {
  constexpr int block_size = 1024;
  constexpr int waves = 32;
  int grid_dim_x;
  {
    cudaError_t err =
        GetNumBlocks(LayerNormBlockUncachedImpl<LOAD, STORE, ComputeType,
                                                pack_size, block_size>,
                     block_size, 0, rows, waves, &grid_dim_x);
    if (err != cudaSuccess) {
      return err;
    }
  }
  LayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, 0, stream>>>(load, store, rows, cols, epsilon,
                                              mean, inv_variance);
  return cudaPeekAtLastError();
}

template <typename LOAD, typename STORE, typename ComputeType>
struct DispatchLayerNormBlockUncachedImplPackSize {
  cudaError_t operator()(cudaStream_t stream, LOAD load, STORE store,
                         const int64_t rows, const int64_t cols,
                         const double epsilon, ComputeType *mean,
                         ComputeType *inv_variance) {
    if (cols % 4 == 0 && CanPackAs<LOAD>(load, 4) &&
        CanPackAs<STORE>(store, 4)) {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) &&
               CanPackAs<STORE>(store, 2)) {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template <typename LOAD, typename STORE, typename ComputeType>
inline cudaError_t
DispatchLayerNormBlockUncachedImpl(cudaStream_t stream, LOAD load, STORE store,
                                   const int64_t rows, const int64_t cols,
                                   const double epsilon, ComputeType *mean,
                                   ComputeType *inv_variance) {
  return DispatchLayerNormBlockUncachedImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

template <typename LOAD, typename STORE, typename ComputeType>
inline typename std::enable_if<!std::is_same<ComputeType, double>::value,
                               cudaError_t>::type
DispatchLayerNorm(cudaStream_t stream, LOAD load, STORE store,
                  const int64_t rows, const int64_t cols, const double epsilon,
                  ComputeType *mean, ComputeType *inv_variance) {
  if (cols <= 1024) {
    return DispatchLayerNormWarpImpl<LOAD, STORE, ComputeType>(
        stream, load, store, rows, cols, epsilon, mean, inv_variance);
  } else {
    bool dispatch_smem_impl_success;
    {
      cudaError_t err =
          TryDispatchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType>(
              stream, load, store, rows, cols, epsilon, mean, inv_variance,
              &dispatch_smem_impl_success);
      if (err != cudaSuccess) {
        return err;
      }
    }
    if (!dispatch_smem_impl_success) {
      return DispatchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
    return cudaSuccess;
  }
}

template <typename LOAD, typename STORE, typename ComputeType>
inline typename std::enable_if<std::is_same<ComputeType, double>::value,
                               cudaError_t>::type
DispatchLayerNorm(cudaStream_t stream, LOAD load, STORE store,
                  const int64_t rows, const int64_t cols, const double epsilon,
                  ComputeType *mean, ComputeType *inv_variance) {
  return DispatchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType>(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

namespace {

template <typename SRC, typename DST, bool do_scale, bool do_center>
struct AffineStore {
  AffineStore(DST *y, int64_t row_size, const DST *gamma, const DST *beta)
      : y(y), row_size(row_size), gamma(gamma), beta(beta) {}
  template <int N>
  __device__ void store(const SRC *src, int64_t row, int64_t col) {
    cuda::layer_norm::Pack<DST, N> y_pack;
    cuda::layer_norm::Pack<DST, N> gamma_pack;
    cuda::layer_norm::Pack<DST, N> beta_pack;
    const int64_t offset = (row * row_size + col) / N;
    const int64_t gamma_offset = col / N;
    if (do_scale) {
      gamma_pack.storage = *(
          reinterpret_cast<const cuda::layer_norm::PackType<DST, N> *>(gamma) +
          gamma_offset);
    } else {
#pragma unroll
      for (int i = 0; i < N; ++i) {
        gamma_pack.elem[i] = static_cast<DST>(1.f);
      }
    }
    if (do_center) {
      beta_pack.storage =
          *(reinterpret_cast<const cuda::layer_norm::PackType<DST, N> *>(beta) +
            gamma_offset);
    } else {
#pragma unroll
      for (int i = 0; i < N; ++i) {
        beta_pack.elem[i] = static_cast<DST>(0.f);
      }
    }
#pragma unroll
    for (int i = 0; i < N; ++i) {
      DST normalized_i = static_cast<DST>(src[i]);
      if (do_scale || do_center) {
        y_pack.elem[i] = normalized_i * gamma_pack.elem[i] + beta_pack.elem[i];
      } else {
        y_pack.elem[i] = normalized_i;
      }
    }
    *(reinterpret_cast<cuda::layer_norm::PackType<DST, N> *>(y) + offset) =
        y_pack.storage;
  }
  DST *y;
  int64_t row_size;
  const DST *gamma;
  const DST *beta;
};
} // namespace

template <typename T>
void LayerNormForwardGpu(const int64_t num_instances, const int64_t norm_size,
                         const double epsilon, const T *x_ptr,
                         const T *gamma_ptr, const T *beta_ptr, T *y_ptr) {
  using ComputeType = typename cuda::layer_norm::DefaultComputeType<T>::type;
  cuda::layer_norm::DirectLoad<T, T> load(x_ptr, norm_size);
  AffineStore<ComputeType, T, true, true> store(y_ptr, norm_size, gamma_ptr,
                                                beta_ptr);
  // we have updated the OneFlow implementation for inference so that mean and
  // inv_variance are not needed
  cuda::layer_norm::DispatchLayerNorm<decltype(load), decltype(store),
                                      ComputeType>(nullptr, load, store,
                                                   num_instances, norm_size,
                                                   epsilon, nullptr, nullptr);
}

} // namespace layer_norm

Tensor layer_norm_op(const Tensor& x, const Tensor& weight, const Tensor& bias) {
  Tensor out = Tensor::Empty(x.sizes(), x.dtype(), x.device());
  RV_CHECK(x.sizes().size() <= 2);
  int m, k;
  if (x.sizes().size() == 1) {
    m = 1;
    k = x.size(0);
  } else {
    m = x.size(0);
    k = x.size(1);
  }
  double epsilon = 1e-5;
  if (x.dtype() == weight.dtype() && x.dtype() == bias.dtype()) {
    if (x.dtype() == DType::kFloat32) {
      layer_norm::LayerNormForwardGpu(
          m, k, epsilon, x.data_ptr<float>(), weight.data_ptr<float>(),
          bias.data_ptr<float>(), out.data_ptr<float>());
    } else if (x.dtype() == DType::kFloat16) {
      layer_norm::LayerNormForwardGpu(
          m, k, epsilon, x.data_ptr<half>(), weight.data_ptr<half>(),
          bias.data_ptr<half>(), out.data_ptr<half>());
    } else {
      RV_CHECK(false);
    }
  } else {
    RV_CHECK(false);
  }
  return out;
}

KernelRegister layer_norm_reg("layernorm", Device::kCUDA, layer_norm_op);
} // namespace cuda

} // namespace rwkv
