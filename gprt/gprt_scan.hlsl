/******************************************************************************
 * Exclusive Vectorized Chained Scan With Decoupled Lookback
 *
 * Variant: Raking warp-sized radix reduce scan using partitions of size equal to 
 *          maximum shared memory.
 *                    
 * Notes:   **Preprocessor macros must be manually changed for AMD**
 * 
 * Author:  Thomas Smith 8/7/2023
 *
 * Based off of Research by:
 *          Duane Merrill, Nvidia Corporation
 *          Michael Garland, Nvidia Corporation
 *          https://research.nvidia.com/publication/2016-03_single-pass-parallel-prefix-scan-decoupled-look-back
 *
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2022, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

#include "gprt.h"

[[vk::push_constant]] gprt::ScanConstants pc;

typedef gprt::ScanRecord ScanRecord;

#define PARTITION_SIZE      8192
#define PART_VEC_SIZE       2048
#define PART_VEC_MASK       2047
#define GROUP_SIZE          512
#define THREAD_BLOCKS       256
#define PART_LOG            13
#define PART_VEC_LOG        11

#define VECTOR_MASK         3
#define VECTOR_LOG          2

#define LANE_COUNT          32  // <---------------------------   For Nvidia; change depending on hardware
#define LANE_MASK           31
#define LANE_LOG            5
#define WAVES_PER_GROUP     16
#define WAVE_PARTITION_SIZE 128
#define WAVE_PART_LOG       7

//#define LANE_COUNT            64 <-------------------------   AMD 
//#define LANE_MASK             63
//#define LANE_LOG              6    
//#define WAVES_PER_GROUP       8
//#define WAVE_PARTITION_SIZE   256
//#define WAVE_PART_LOG         8

#define FLAG_NOT_READY  0
#define FLAG_AGGREGATE  1
#define FLAG_INCLUSIVE  2
#define FLAG_MASK       3

#define LANE            gtid.x
#define WAVE_INDEX      gtid.y
#define SPINE_INDEX     (((gtid.x + 1) << WAVE_PART_LOG) - 1)
#define PARTITIONS      (pc.size >> PART_LOG)
#define WAVE_PART_START (WAVE_INDEX << WAVE_PART_LOG)
#define WAVE_PART_END   (WAVE_INDEX + 1 << WAVE_PART_LOG)
#define PARTITION_START (partitionIndex << PART_VEC_LOG)

// using 0th value to hold the partition index
#define STATE_START     1

groupshared uint4 g_sharedMem[PART_VEC_SIZE];

GPRT_COMPUTE_PROGRAM(InitChainedDecoupledExclusive, (ScanRecord, record), (512,1,1)) {
  uint3 id = DispatchThreadID;
  
  if (id.x == 0)
    gprt::store<uint32_t>(pc.state, id.x, 0);

  gprt::store<uint32_t>(STATE_START + pc.state, id.x, FLAG_NOT_READY);
}

GPRT_COMPUTE_PROGRAM(ChainedDecoupledExclusive, (ScanRecord, record), (LANE_COUNT, WAVES_PER_GROUP,1)) {
  uint3 gtid = GroupThreadID;
  uint3 gid = GroupID;

  //Acquire the partition index
  int partitionIndex;
  if (WAVE_INDEX == 0 && LANE == 0)
    g_sharedMem[0].x = gprt::atomicAdd(pc.state, 0, 1);
  GroupMemoryBarrierWithGroupSync();
  partitionIndex = WaveReadLaneAt(g_sharedMem[0].x, 0);
  GroupMemoryBarrierWithGroupSync();

  // Note, the code below is using a warp-sized-radix ranking reduce scan, which mostly avoids bank conflicts.
  const int partSize = partitionIndex == PARTITIONS ? (pc.size >> VECTOR_LOG) + (pc.size & VECTOR_MASK ? 1 : 0) - PARTITION_START : PART_VEC_SIZE;
  int i = LANE + WAVE_PART_START;
  if (i < partSize)
  {
    g_sharedMem[i] = gprt::atomicLoad<uint4>(pc.input, i + PARTITION_START);
    
    uint t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].y;
    g_sharedMem[i].y = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].z;
    g_sharedMem[i].z = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].w;
    g_sharedMem[i].w = t;
    g_sharedMem[i] += WavePrefixSum(g_sharedMem[i].x);
  }
          
  i += LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i] = gprt::atomicLoad<uint4>(pc.input, i + PARTITION_START);
    
    uint t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].y;
    g_sharedMem[i].y = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].z;
    g_sharedMem[i].z = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].w;
    g_sharedMem[i].w = t;
    g_sharedMem[i] += WavePrefixSum(g_sharedMem[i].x) + WaveReadLaneAt(g_sharedMem[i - 1].x, 0);
  }
          
  i += LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i] = gprt::atomicLoad<uint4>(pc.input, i + PARTITION_START);
    
    uint t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].y;
    g_sharedMem[i].y = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].z;
    g_sharedMem[i].z = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].w;
    g_sharedMem[i].w = t;
    g_sharedMem[i] += WavePrefixSum(g_sharedMem[i].x) + WaveReadLaneAt(g_sharedMem[i - 1].x, 0);
  }
          
  i += LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i] = gprt::atomicLoad<uint4>(pc.input, i + PARTITION_START);
    
    uint t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].y;
    g_sharedMem[i].y = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].z;
    g_sharedMem[i].z = t;
    
    t = g_sharedMem[i].x;
    g_sharedMem[i].x += g_sharedMem[i].w;
    g_sharedMem[i].w = t;
    g_sharedMem[i] += WavePrefixSum(g_sharedMem[i].x) + WaveReadLaneAt(g_sharedMem[i - 1].x, 0);
  }
  GroupMemoryBarrierWithGroupSync();

  if (WAVE_INDEX == 0 && LANE < WAVES_PER_GROUP)
    g_sharedMem[SPINE_INDEX] += WavePrefixSum(g_sharedMem[SPINE_INDEX].x);
  GroupMemoryBarrierWithGroupSync();

  //Set flag payload
  if (WAVE_INDEX == 0 && LANE == 0)
  {
    if (partitionIndex == 0)
      gprt::atomicOr(pc.state, STATE_START + partitionIndex, FLAG_INCLUSIVE ^ (g_sharedMem[PART_VEC_MASK].x << 2));
    else
      gprt::atomicOr(pc.state, STATE_START + partitionIndex, FLAG_AGGREGATE ^ (g_sharedMem[PART_VEC_MASK].x << 2));
  }

  //Lookback
  uint aggregate = 0;
  if (partitionIndex)
  {
    if (WAVE_INDEX == 0)
    {
      for (int k = partitionIndex - LANE - 1; 0 <= k;)
      {
        uint flagPayload = gprt::atomicLoad<uint>(pc.state, STATE_START + k);
        const int inclusiveIndex = WaveActiveMin(LANE + LANE_COUNT - ((flagPayload & FLAG_MASK) == FLAG_INCLUSIVE ? LANE_COUNT : 0));
        const int gapIndex = WaveActiveMin(LANE + LANE_COUNT - ((flagPayload & FLAG_MASK) == FLAG_NOT_READY ? LANE_COUNT : 0));
        if (inclusiveIndex < gapIndex)
        {
            aggregate += WaveActiveSum(LANE <= inclusiveIndex ? (flagPayload >> 2) : 0);
            if (LANE == 0)
            {
              gprt::atomicAdd(pc.state, STATE_START + partitionIndex, 1 | aggregate << 2);
              g_sharedMem[PART_VEC_MASK].x = aggregate;
            }
            break;
        }
        else
        {
          if (gapIndex < LANE_COUNT)
          {
            aggregate += WaveActiveSum(LANE < gapIndex ? (flagPayload >> 2) : 0);
            k -= gapIndex;
          }
          else
          {
            aggregate += WaveActiveSum(flagPayload >> 2);
            k -= LANE_COUNT;
          }
        }
      }
    }
    GroupMemoryBarrierWithGroupSync();
        
    //propogate aggregate values
    if (WAVE_INDEX || LANE)
      aggregate = WaveReadLaneAt(g_sharedMem[PART_VEC_MASK].x, 1);
  }

  const uint prev = (WAVE_INDEX ? WaveReadLaneAt(g_sharedMem[LANE + WAVE_PART_START - 1].x, 0) : 0) + aggregate;
  GroupMemoryBarrierWithGroupSync();
          
  if (i < partSize)
  {
    g_sharedMem[i].x = g_sharedMem[i - 1].x + (LANE != LANE_MASK ? 0 : prev - aggregate);
    gprt::store<uint4>(pc.output, i + PARTITION_START, g_sharedMem[i] + (LANE != LANE_MASK ? prev : aggregate));
  }
  
  i -= LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i].x = g_sharedMem[i - 1].x;
    gprt::store<uint4>(pc.output, i + PARTITION_START, g_sharedMem[i] + prev);
  }
          
  i -= LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i].x = g_sharedMem[i - 1].x;
    gprt::store<uint4>(pc.output, i + PARTITION_START, g_sharedMem[i] + prev);
  }
          
  i -= LANE_COUNT;
  if (i < partSize)
  {
    g_sharedMem[i].x = LANE ? g_sharedMem[i - 1].x : 0;
    gprt::store<uint4>(pc.output, i + PARTITION_START, g_sharedMem[i] + prev);
  }
}
