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

#include <mutex>
#include <set>

#include "kernels/allocator.h"
#include <kernels/registry.h>
#include <unordered_map>
#include <unordered_set>

namespace rwkv {
namespace cuda {

class CudaAsyncAllocator : public rwkv::Allocator {
public:
  void *DoAllocate(size_t size) {
    void *ptr;
    cudaMallocAsync(&ptr, size, stream());
    return ptr;
  }
  void Deallocate(void *ptr) { cudaFreeAsync(ptr, stream()); }
  cudaStream_t stream() {
    if (stream_ == nullptr) {
      cudaStreamCreate(&stream_);
    }
    return stream_;
  }

private:
  cudaStream_t stream_;
};

template<typename ThreadLock>
class CachingAllocator final : public Allocator {
 public:
  explicit CachingAllocator();
  ~CachingAllocator();

  void* DoAllocate(std::size_t size) override;
  void Deallocate(void* mem_ptr) override;

 private:
  static constexpr int32_t kInvalidBinNum = -1;
  static constexpr int32_t kBinNumSize = 20;

  // Piece is the basic memory unit of BinAllocator.
  // A Piece is either is free(is_free = true) or in used(is_free = false).
  // If the Piece is_free = true, the pointer to the piece will be stored in the Bin structure of
  // the corresponding BinSize. Pieces are stored in a linked list. The Piece's prev and next are
  // continuous with the current Piece in physical memory.
  struct Piece {
    size_t size = 0;
    char* ptr = nullptr;
    bool is_free = false;
    Piece* prev = nullptr;
    Piece* next = nullptr;
    int32_t bin_num = kInvalidBinNum;
  };

  // Bin is a structure that stores a set of pieces which is free and has similar size, and
  // these Pieces are arger than the size of bin
  //
  // BinAllocator has a set of Bin structures according to the binary multiple increasing relation,
  // which is used to quickly index and find the free Piece of appropriate size when Allocate()
  //
  // The size of the smallest bin is 512 (512 is the smallest unit Allocated by BinAllocator,
  // and the memory size of all Allocated will be multiples of 512, 512 is kCudaMemAllocAlignSize).
  // The size of each Bin is twice the size of the previous Bin, like
  //    BinNum:   Bin0, Bin1, Bin2, Bin3, ..., Bin19
  //    BinSize:  512, 1024, 2048, 4096, ... , 512MB
  struct Bin {
    size_t size = 0;

    struct PieceCmp {
      bool operator()(const Piece* lhs, const Piece* rhs) const {
        if (lhs->size != rhs->size) { return lhs->size < rhs->size; }
        return lhs->ptr < rhs->ptr;
      }
    };
    std::set<Piece*, PieceCmp> pieces;
  };

  // Block is large physical memory that is actually allocated.
  // There maybe many consecutive disjoint Pieces distributed on the Block memory
  struct Block {
    size_t size = 0;
    char* ptr = nullptr;
    Piece* start_piece = nullptr;
    Block(Piece* p) : size(p->size), ptr(p->ptr), start_piece(p) {}
  };

  size_t BinSize4BinNum(int32_t bin_num) { return kAlignSize << bin_num; }

  int32_t BinNum4BinSize(size_t size) {
    uint64_t value = std::max<size_t>(size, kAlignSize) >> 9;
    return std::min(kBinNumSize - 1, static_cast<int32_t>(63 ^ __builtin_clzll(value)));
  }

  // Try find free Piece which size is larger than aligned_size in Bins.
  // Return nullptr when find failure
  Piece* FindPiece(size_t aligned_size);

  // Insert the free Piece to the appropriate Bin which bin size is smaller than piece
  void InsertPiece2Bin(Piece* piece);

  // Create new empty Piece or recycle a Piece from recycle_piece_list_
  Piece* AllocatePiece();
  // Delete a Piece and move in the linked list recycle_piece_list_
  void DeallocatePiece(Piece* piece);

  // Insert a {piece->ptr, piece} pair into the ptr2piece_ map for search Piece when call
  // Deallocate()
  void MarkPiece(Piece* piece);
  // Erase the {piece->ptr, piece} pair from ptr2piece_ because the ptr is useless
  // Usually call before DeallocatePiece()
  void UnMarkPiece(Piece* piece);

  void MergeNeighbourFreePiece(Piece* lhs, Piece* rhs);
  void RemovePieceFromBin(Piece* piece);

  bool AllocateBlockToExtendTotalMem(size_t aligned_size);
  bool DeallocateFreeBlockForGarbageCollection();

  const size_t alignment_;
  ThreadLock thread_lock_;
  size_t total_memory_bytes_;
  std::unordered_map<void*, Block> mem_ptr2block_;

  std::vector<Bin> bins_;
  std::vector<std::unique_ptr<Piece>> pieces_;
  std::unordered_map<void*, Piece*> ptr2piece_;
  Piece* recycle_piece_list_;
};

namespace {

const size_t kHostAlignSize = 64;
const size_t kCudaAlignSize = 512;
const size_t kCudaMemAllocAlignSize = 512;

inline size_t RoundUp(size_t n, size_t val) { return (n + val - 1) / val * val; }

inline size_t GetCudaAlignedSize(size_t size) { return RoundUp(size, kCudaAlignSize); }

inline size_t MemAlignedBytes(size_t bytes, size_t alignment) { return RoundUp(bytes, alignment); }

inline bool IsAlignedSize(size_t size, size_t alignment) { return size % alignment == 0; }

static const size_t kPieceSplitThreshold = 128 << 20;  // 128MiB

}  // namespace

template<typename ThreadLock>
CachingAllocator<ThreadLock>::CachingAllocator()
    : alignment_(kCudaAlignSize),
      total_memory_bytes_(0),
      recycle_piece_list_(nullptr) {
  bins_.resize(kBinNumSize);
  for (int i = 0; i < kBinNumSize; ++i) {
    size_t bin_size = BinSize4BinNum(i);
    bins_.at(i).size = bin_size;
  }
}

template<typename ThreadLock>
CachingAllocator<ThreadLock>::~CachingAllocator() {
  if (total_memory_bytes_ == 0) {
    return;
  }
  for (auto& pair : mem_ptr2block_) { 
    cudaFree(pair.first);
  }
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::InsertPiece2Bin(Piece* piece) {
  RV_CHECK(piece->is_free && piece->bin_num == kInvalidBinNum);
  int32_t bin_num = BinNum4BinSize(piece->size);
  piece->bin_num = bin_num;
  RV_CHECK(bins_.at(bin_num).pieces.insert(piece).second);
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::RemovePieceFromBin(Piece* piece) {
  RV_CHECK(piece->is_free);
  bins_.at(piece->bin_num).pieces.erase(piece);
  piece->bin_num = kInvalidBinNum;
}

template<typename ThreadLock>
typename CachingAllocator<ThreadLock>::Piece* CachingAllocator<ThreadLock>::AllocatePiece() {
  if (recycle_piece_list_) {
    Piece* ret = recycle_piece_list_;
    recycle_piece_list_ = recycle_piece_list_->next;
    return ret;
  } else {
    pieces_.emplace_back(new Piece());
    return pieces_.at(pieces_.size() - 1).get();
  }
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::DeallocatePiece(Piece* piece) {
  piece->ptr = nullptr;
  piece->size = 0;
  piece->bin_num = kInvalidBinNum;
  piece->is_free = true;
  piece->prev = nullptr;
  piece->next = recycle_piece_list_;
  recycle_piece_list_ = piece;
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::MarkPiece(Piece* piece) {
  RV_CHECK(ptr2piece_.emplace(piece->ptr, piece).second);
}
template<typename ThreadLock>
void CachingAllocator<ThreadLock>::UnMarkPiece(Piece* piece) {
  auto it = ptr2piece_.find(piece->ptr);
  RV_CHECK(it != ptr2piece_.end());
  ptr2piece_.erase(it);
}

template<typename ThreadLock>
typename CachingAllocator<ThreadLock>::Piece* CachingAllocator<ThreadLock>::FindPiece(size_t aligned_size) {
  for (int32_t bin_num = BinNum4BinSize(aligned_size); bin_num < kBinNumSize; ++bin_num) {
    Bin* bin = &bins_.at(bin_num);
    for (auto it = bin->pieces.begin(); it != bin->pieces.end(); ++it) {
      Piece* piece = *it;
      RV_CHECK(piece->is_free);
      RV_CHECK(IsAlignedSize(piece->size, alignment_));
      if (piece->size >= aligned_size) {
        bin->pieces.erase(it);
        piece->bin_num = kInvalidBinNum;
        piece->is_free = false;
        if (piece->size >= aligned_size * 2 || piece->size - aligned_size >= kPieceSplitThreshold) {
          Piece* new_piece = AllocatePiece();
          new_piece->ptr = piece->ptr + aligned_size;
          new_piece->size = piece->size - aligned_size;
          piece->size = aligned_size;

          Piece* next_p = piece->next;
          piece->next = new_piece;
          new_piece->prev = piece;
          new_piece->next = next_p;
          if (next_p != nullptr) { next_p->prev = new_piece; }

          new_piece->is_free = true;
          new_piece->bin_num = kInvalidBinNum;
          RV_CHECK(IsAlignedSize(piece->size, alignment_));
          RV_CHECK(IsAlignedSize(new_piece->size, alignment_));
          InsertPiece2Bin(new_piece);
          MarkPiece(new_piece);
        }
        return piece;
      }
    }
  }
  return nullptr;
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::MergeNeighbourFreePiece(Piece* lhs, Piece* rhs) {
  RV_CHECK(lhs->is_free);
  RV_CHECK(rhs->is_free);
  RV_CHECK(lhs->next == rhs);
  RV_CHECK(lhs == rhs->prev);
  RV_CHECK(lhs->ptr + lhs->size == rhs->ptr);

  lhs->size += rhs->size;
  lhs->next = rhs->next;
  if (rhs->next != nullptr) { rhs->next->prev = lhs; }
  UnMarkPiece(rhs);
  DeallocatePiece(rhs);
}

template<typename ThreadLock>
bool CachingAllocator<ThreadLock>::AllocateBlockToExtendTotalMem(size_t aligned_size) {
  size_t allocate_bytes = aligned_size;
  if (allocate_bytes < 1048576) {
    // Allocate 2MB if `allocate_bytes` is less than 1MB
    allocate_bytes = 2097152;
  } else if (allocate_bytes < 10485760) {
    // Allocate 20MB if `allocate_bytes` is between 1MB and 10MB
    allocate_bytes = 20971520;
  } else {
    // Round up to 2MB if `allocate_bytes` is larger than 10MB
    allocate_bytes = RoundUp(allocate_bytes, 2097152);
  }
  const size_t final_allocate_bytes = MemAlignedBytes(allocate_bytes, alignment_);

  if (final_allocate_bytes < aligned_size) { return false; }

  char* mem_ptr = nullptr;
  cudaMalloc(&mem_ptr, final_allocate_bytes);
  if (mem_ptr == nullptr) { return false; }

  // extend sucess
  total_memory_bytes_ += final_allocate_bytes;

  Piece* piece = AllocatePiece();
  piece->size = final_allocate_bytes;
  piece->ptr = mem_ptr;
  piece->prev = nullptr;
  piece->next = nullptr;
  piece->is_free = true;
  piece->bin_num = kInvalidBinNum;
  InsertPiece2Bin(piece);
  MarkPiece(piece);

  mem_ptr2block_.emplace(mem_ptr, Block(piece));

  return true;
}

template<typename ThreadLock>
bool CachingAllocator<ThreadLock>::DeallocateFreeBlockForGarbageCollection() {
  size_t total_free_bytes = 0;
  std::unordered_set<char*> free_block_ptrs;
  for (const auto& pair : mem_ptr2block_) {
    const Block& block = pair.second;
    bool all_free = true;
    Piece* p = block.start_piece;
    while (p != nullptr) {
      if (!(p->is_free)) {
        all_free = false;
        break;
      }
      p = p->next;
    }

    if (all_free) {
      total_free_bytes += block.size;
      free_block_ptrs.insert(pair.first);
    }
  }

  total_memory_bytes_ -= total_free_bytes;

  if (total_free_bytes > 0) {
    for (char* ptr : free_block_ptrs) {
      auto it = mem_ptr2block_.find(ptr);
      RV_CHECK(it != mem_ptr2block_.end());
      const Block& block = it->second;

      // delete all Piece on Block
      size_t piece_size_sum = 0;
      Piece* p = block.start_piece;
      CHECK_EQ(block.ptr, block.start_piece->ptr);
      CHECK_EQ(block.ptr, ptr);
      while (p != nullptr) {
        Piece* next_p = p->next;
        piece_size_sum += p->size;
        RemovePieceFromBin(p);
        UnMarkPiece(p);
        DeallocatePiece(p);
        p = next_p;
      }
      CHECK_EQ(block.size, piece_size_sum);

      mem_ptr2block_.erase(it);
      cudaFree(ptr);
    }
  }
  return total_free_bytes > 0;
}

template<typename ThreadLock>
void* CachingAllocator<ThreadLock>::DoAllocate(std::size_t size) {
  typename ThreadLock::RAIIGuard guard(thread_lock_);
  if (size == 0) {
    return nullptr;
  }
  size_t aligned_size = MemAlignedBytes(size, alignment_);

  Piece* piece = FindPiece(aligned_size);

  if (piece == nullptr) {
    if (AllocateBlockToExtendTotalMem(aligned_size)) { piece = FindPiece(aligned_size); }
  }

  RV_CHECK(piece != nullptr);

  return piece->ptr;
}

template<typename ThreadLock>
void CachingAllocator<ThreadLock>::Deallocate(void* mem_ptr) {
  if (mem_ptr == nullptr) { return; }
  typename ThreadLock::RAIIGuard guard(thread_lock_);

  auto it = ptr2piece_.find(mem_ptr);
  Piece* piece = it->second;
  RV_CHECK(!piece->is_free);

  piece->is_free = true;

  Piece* last_piece_insert_to_bin = piece;
  Piece* next_p = piece->next;
  Piece* prev_p = piece->prev;

  if (next_p != nullptr && next_p->is_free) {
    RemovePieceFromBin(next_p);
    MergeNeighbourFreePiece(piece, next_p);
  }

  if (prev_p != nullptr && prev_p->is_free) {
    RemovePieceFromBin(prev_p);
    MergeNeighbourFreePiece(prev_p, piece);
    last_piece_insert_to_bin = prev_p;
  }
  InsertPiece2Bin(last_piece_insert_to_bin);
}

class ThreadSafeLock final {
 public:
  class RAIIGuard final {
   public:
    explicit RAIIGuard(ThreadSafeLock& lock) : guard_(lock.mutex4guard) {}

   private:
    std::unique_lock<std::mutex> guard_;
  };

 private:
  std::mutex mutex4guard;
};

rwkv::Allocator& allocator() {
  static CachingAllocator<ThreadSafeLock> allocator;
  return allocator;
}

KernelRegister allocator_reg("allocator", Device::kCUDA, allocator);

} // namespace cuda
} // namespace rwkv
