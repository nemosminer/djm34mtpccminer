/**
 * MTP 
 * djm34 2017-2018
 **/

#include <stdio.h>
#include <memory.h>


#include "lyra2/cuda_lyra2_vectors.h"
static uint32_t *h_MinNonces[16]; // this need to get fixed as the rest of that routine
static uint32_t *d_MinNonces[16];

__constant__ uint32_t pTarget[8];
__constant__ uint32_t pData[20]; // truncated data
__constant__ uint4 Elements[1];
 uint4 * HBlock[16];

#define ARGON2_SYNC_POINTS 4
#define argon_outlen 32
#define argon_timecost 1
#define argon_memcost 4*1024*1024 //*1024 //32*1024*2 //1024*256*1 //2Gb
#define argon_lanes 4
#define argon_threads 1
#define argon_hashlen 80
#define argon_version 19
#define argon_type 0 // argon2d
#define argon_pwdlen 80 // hash and salt lenght
#define argon_default_flags 0 // hmm not sure
#define argon_segment_length argon_memcost/(argon_lanes * ARGON2_SYNC_POINTS)
#define argon_lane_length argon_segment_length * ARGON2_SYNC_POINTS
#define TREE_LEVELS 20
#define ELEM_MAX 2048
#define gpu_thread 2
#define gpu_shared 128
#define kernel1_thread 64
#define mtp_L 64
#define TPB52 32
#define TPB30 160
#define TPB20 160



__constant__ static const uint8_t blake2b_sigma[12][16] =
{
	{ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 } ,
	{ 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 } ,
	{ 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 } ,
	{ 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 } ,
	{ 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 } ,
	{ 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 } ,
	{ 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 } ,
	{ 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 } ,
	{ 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 } ,
	{ 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13 , 0 } ,
	{ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 } ,
	{ 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 }
};


static __device__ __forceinline__ uint2 mf1(const uint2* u, const uint2* __restrict__ v, uint32_t a, uint32_t b) {
	uint8_t res = blake2b_sigma[a][b];
	if (res<4)
	 return u[res];
	else 
	 return v[res - 4];	
}

static __device__ __forceinline__ uint2 mf2(const uint2* __restrict__ v, uint32_t a, uint32_t b) {
	uint8_t res = blake2b_sigma[a][b];

	if (res<4)
		return v[res];
	else
		return make_uint2(0, 0);
}


static __device__ __forceinline__ uint2 eorswap32(uint2 u, uint2 v) {
	uint2 result;
	result.y = u.x ^ v.x;
	result.x = u.y ^ v.y;
	return result;
}

__device__ static int blake2b_compress2_256(uint2 *hash, const uint2 *hzcash, const uint2 block[16], const uint32_t len)
{
	uint2 m[16];
	uint2 v[16];


	 const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};
	for (int i = 0; i < 16; ++i)
		m[i] = block[i];

	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];

	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = ~blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + m[blake2b_sigma[r][2*i+0]]; \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + m[blake2b_sigma[r][2*i+1]]; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

	for (int i = 0; i < 4; ++i)
		hash[i] = hzcash[i] ^ v[i] ^ v[i + 8];

#undef G
#undef ROUND
	return 0;
}

__device__ static int blake2b_compress2c_256(uint2 *hash, const uint2 *hzcash, const uint2 block[16], const uint32_t len)
{
	uint2 m[16];
	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};
	for (int i = 0; i < 16; ++i)
		m[i] = block[i];

	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];
	uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = ~blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + m[blake2b_sigma[r][2*i+0]]; \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + m[blake2b_sigma[r][2*i+1]]; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

	for (int i = 0; i < 4; ++i)
		hash[i] = hzcash[i] ^ v[i] ^ v[i + 8];

#undef G
#undef ROUND
	return 0;
}


__device__ static int blake2b_compress2c_256_v2(uint2 *hash, const uint2 *hzcash, const uint2* __restrict__ m1, const uint32_t len)
{

	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};

	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];
	uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = ~blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + mf2(m1,r,2*i+0); \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + mf2(m1,r,2*i+1); \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

	for (int i = 0; i < 4; ++i)
		hash[i] = hzcash[i] ^ v[i] ^ v[i + 8];

#undef G
#undef ROUND
	return 0;
}


__device__ static int blake2b_compress2b(uint2 *hash, const uint2 *hzcash, const uint2 block[16], const uint32_t len)
{
	uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	uint2 m[16];
	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};
	for (int i = 0; i < 16; ++i)
		m[i] = block[i];

	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + m[blake2b_sigma[r][2*i+0]]; \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + m[blake2b_sigma[r][2*i+1]]; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

	for (int i = 0; i < 8; ++i)
		hash[i] = hzcash[i] ^ v[i] ^ v[i + 8];


#undef G
#undef ROUND
	return 0;
}


__device__ __forceinline__ int blake2b_compress2b_v2(uint2 *hzcash, const uint2* __restrict__ m, const uint32_t len)
{

	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};



	#pragma unroll
	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + m[blake2b_sigma[r][2*i+0]]; \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + m[blake2b_sigma[r][2*i+1]]; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

#pragma unroll
	for (int i = 0; i < 8; ++i)
		hzcash[i] ^= v[i] ^ v[i + 8];


#undef G
#undef ROUND
	return 0;
}

__device__ __forceinline__ int blake2b_compress2b_v3(uint2 *hzcash, const uint2 block[16], const uint32_t len)
{

	uint2 m[16];
	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};
#pragma unroll
		for (int i = 0; i < 16; ++i)
			m[i] = block[i];

#pragma unroll
	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + m[blake2b_sigma[r][2*i+0]]; \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + m[blake2b_sigma[r][2*i+1]]; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

#pragma unroll
	for (int i = 0; i < 8; ++i)
		hzcash[i] ^= v[i] ^ v[i + 8];


#undef G
#undef ROUND
	return 0;
}

__device__ __forceinline__ int blake2b_compress2b_v4(uint2 *hzcash, const uint2* block1, const uint2* __restrict__ m1, const uint32_t len)
{

//	uint2 m[16];
	uint2 v[16];
	const uint2 blakeIV[8] =
	{
		{ 0xf3bcc908UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};
//#pragma unroll
//	for (int i = 0; i < 16; ++i)
//		m[i] = block[i];

#pragma unroll
	for (int i = 0; i < 8; ++i)
		v[i] = hzcash[i];


	v[8] = blakeIV[0];
	v[9] = blakeIV[1];
	v[10] = blakeIV[2];
	v[11] = blakeIV[3];
	v[12] = blakeIV[4];
	v[12].x ^= len;
	v[13] = blakeIV[5];
	v[14] = blakeIV[6];
	v[15] = blakeIV[7];

#define G(r,i,a,b,c,d) \
   { \
     v[a] +=   v[b] + mf1(block1,m1,r,2*i+0); \
     v[d] = eorswap32(v[d] , v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 24); \
     v[a] += v[b] + mf1(block1,m1,r,2*i+1) ; \
     v[d] = ROR16(v[d] ^ v[a]); \
     v[c] += v[d]; \
     v[b] = ROR2(v[b] ^ v[c], 63); \
  } 
#define ROUND(r)  \
  { \
    G(r,0, 0,4,8,12); \
    G(r,1, 1,5,9,13); \
    G(r,2, 2,6,10,14); \
    G(r,3, 3,7,11,15); \
    G(r,4, 0,5,10,15); \
    G(r,5, 1,6,11,12); \
    G(r,6, 2,7,8,13); \
    G(r,7, 3,4,9,14); \
  } 

	ROUND(0);
	ROUND(1);
	ROUND(2);
	ROUND(3);
	ROUND(4);
	ROUND(5);
	ROUND(6);
	ROUND(7);
	ROUND(8);
	ROUND(9);
	ROUND(10);
	ROUND(11);

#pragma unroll
	for (int i = 0; i < 8; ++i)
		hzcash[i] ^= v[i] ^ v[i + 8];


#undef G
#undef ROUND
	return 0;
}



__global__ __launch_bounds__(352, 1)   // 352 or 208
void mtp_yloop(uint32_t thr_id, uint32_t threads, uint32_t startNounce, const uint4  * __restrict__ DBlock,
  uint32_t * __restrict__ SmallestNonce)
{

	const uint2 blakeFinal[8] =
	{
		{ 0xf2bdc928UL, 0x6a09e667UL },
		{ 0x84caa73bUL, 0xbb67ae85UL },
		{ 0xfe94f82bUL, 0x3c6ef372UL },
		{ 0x5f1d36f1UL, 0xa54ff53aUL },
		{ 0xade682d1UL, 0x510e527fUL },
		{ 0x2b3e6c1fUL, 0x9b05688cUL },
		{ 0xfb41bd6bUL, 0x1f83d9abUL },
		{ 0x137e2179UL, 0x5be0cd19UL }
	};

	uint32_t event_thread = (blockDim.x * blockIdx.x + threadIdx.x);

	uint32_t NonceIterator = startNounce + event_thread;
	//	uint32_t thread_event = thread / event_base; // might be a lot (considering this isn't thread per blocks)
	if (event_thread < threads)
	{

		const uint4 *	 __restrict__ GBlock	   = &DBlock[0];
		 uint8 YLocal;

		uint2 DataChunk[16] = { 0 };

		((uint4*)DataChunk)[0] = __ldg(&((uint4*)pData)[0]);
		((uint4*)DataChunk)[1] = __ldg(&((uint4*)pData)[1]);

		((uint4*)DataChunk)[2] = __ldg(&((uint4*)pData)[2]);
		((uint4*)DataChunk)[3] = __ldg(&((uint4*)pData)[3]);

		((uint4*)DataChunk)[4] = __ldg(&((uint4*)pData)[4]);
		((uint4*)DataChunk)[5] = __ldg(&((uint4*)Elements)[0]);
		
		((uint16*)DataChunk)[1].hi.s0  = NonceIterator;

		blake2b_compress2_256((uint2*)&YLocal,blakeFinal,DataChunk,100);


		bool init_blocks; 
		uint32_t unmatch_block;
		uint32_t localIndex;
		init_blocks = false;
		unmatch_block = 0;

		uint2 DataTmp[8] = { 0 };
		
		for (int j = 1; j <= mtp_L; j++)
		{

				localIndex = YLocal.s0%(argon_memcost);

				if (localIndex == 0 || localIndex == 1) {
					init_blocks = true;
					break;
				}


				uint32_t len = 128;

				((uint16*)DataTmp)[0] = ((uint16*)blakeFinal)[0];
				
				blake2b_compress2b_v4((uint2*)&DataTmp, (uint2*)&YLocal, &((uint2*)GBlock)[localIndex * 32*4], len);

				for (int i = 0; i < 7; i++) {
					len += (i&1==0)? 32:128;
					blake2b_compress2b_v2((uint2*)&DataTmp, &((uint2* )GBlock)[localIndex * 128 + 12 + 16 * i], len);
				}



//				blake2b_compress2c_256((uint2*)&YLocal, (uint2*)&DataTmp, (uint2*)DataChunk, 1024+32);
				blake2b_compress2c_256_v2((uint2*)&YLocal, (uint2*)&DataTmp, &((uint2*)GBlock)[localIndex * 32 * 4+ 31*4], 1024 + 32);
		}


		if (init_blocks) {
			return; // not a solution
		}

		if (YLocal.s7 <= pTarget[7]) 
		{
		atomicMin(&SmallestNonce[0],NonceIterator);

		}

	}
}



__host__
void mtp_cpu_init(int thr_id, uint32_t threads)
{
cudaSetDevice(device_map[thr_id]);
	// just assign the device pointer allocated in main loop


	cudaMalloc((void**)&HBlock[device_map[thr_id]], 256 * argon_memcost * sizeof(uint32_t) );
	cudaMalloc(&d_MinNonces[device_map[thr_id]], sizeof(uint32_t));
	cudaMallocHost(&h_MinNonces[device_map[thr_id]],  sizeof(uint32_t));
}


__host__
void mtp_setBlockTarget(int thr_id,const void* pDataIn,const void *pTargetIn, const void * zElement)
{
cudaSetDevice(device_map[thr_id]);

	cudaMemcpyToSymbol(pData, pDataIn, 80, 0, cudaMemcpyHostToDevice); 
	cudaMemcpyToSymbol(pTarget, pTargetIn, 32, 0, cudaMemcpyHostToDevice);	
	cudaMemcpyToSymbol(Elements, zElement, 4*sizeof(uint32_t), 0, cudaMemcpyHostToDevice);

}

__host__
void mtp_fill(uint32_t thr_id ,const uint64_t *Block,uint32_t offset, uint32_t datachunk)
{
cudaSetDevice(device_map[thr_id]);
	 uint4 *Blockptr   = &HBlock[device_map[thr_id]][offset*64* datachunk];
	 cudaError_t err = cudaMemcpyAsync(Blockptr, Block, datachunk * 256 * sizeof(uint32_t), cudaMemcpyHostToDevice);
	
	if (err != cudaSuccess)
	{
		printf("%s\n", cudaGetErrorName(err));
		cudaDeviceReset();
		exit(1);
	}

}

__host__
uint32_t mtp_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce)
{
cudaSetDevice(device_map[thr_id]);
	uint32_t result = UINT32_MAX;
	cudaMemset(d_MinNonces[device_map[thr_id]],0xff,sizeof(uint32_t));
	

	uint32_t tpb = 352; //TPB52;
 
	dim3 gridyloop(threads/tpb);
	dim3 blockyloop(tpb);

	mtp_yloop << < gridyloop,blockyloop >> >(device_map[thr_id],threads,startNounce,HBlock[device_map[thr_id]],d_MinNonces[device_map[thr_id]]);


	cudaMemcpy(h_MinNonces[device_map[thr_id]], d_MinNonces[device_map[thr_id]], sizeof(uint32_t), cudaMemcpyDeviceToHost);

	result = *h_MinNonces[device_map[thr_id]];
	return result;

}
