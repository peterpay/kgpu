/*
 * This work is licensed under the terms of the GNU GPL, version 2.  See
 * the GPL-COPYING file in the top-level directory.
 *
 * Copyright (c) 2010-2011 University of Utah and the Flux Group.
 * All rights reserved.
 *
 */

#include <cuda.h>
#include <stdlib.h>
#include <stdio.h>
#include "helper.h"
#include "gputils.h"

extern "C" void init_gpu();
extern "C" void finit_gpu();

extern "C" void *alloc_pinned_mem(unsigned long size);
extern "C" void free_pinned_mem(void *p);

extern "C" int alloc_gpu_mem(struct service_request *sreq);
extern "C" void free_gpu_mem(struct service_request *sreq);
extern "C" int alloc_stream(struct service_request *sreq);
extern "C" void free_stream(struct service_request *sreq);
//extern "C" struct service_request* alloc_service_request();
//extern "C" void free_service_request(struct service_request *sreq);

extern "C" int execution_finished(struct service_request *sreq);
extern "C" int post_finished(struct service_request *sreq);

extern "C" unsigned long get_stream(int sid);

#define MAX_STREAM_NR 8
static cudaStream_t streams[MAX_STREAM_NR];
static int streamuses[MAX_STREAM_NR];

static const dim3 default_block_size(32,1);
static const dim3 default_grid_size(512,1);

struct gpu_buffer devbufs[KGPU_BUF_NR];

void init_gpu()
{
    int i;

    for (i=0; i< KGPU_BUF_NR; i++) {
	devbufs[i].addr = alloc_dev_mem(KGPU_BUF_SIZE);
    }

    for (i=0; i<MAX_STREAM_NR; i++) {
        csc( cudaStreamCreate(&streams[i]) );
	streamuses[i] = 0;
    }
}

void finit_gpu()
{
    int i;

    for (i=0; i<KGPU_BUF_NR; i++) {
	free_dev_mem(devbufs[i].addr);
    }
    for (i=0; i<MAX_STREAM_NR; i++) {
	csc( cudaStreamDestroy(streams[i]));
    }
}

unsigned long get_stream(int stid)
{
    if (stid < 0 || stid >= MAX_STREAM_NR)
	return 0;
    else
	return (unsigned long)streams[stid];
}

void *alloc_pinned_mem(unsigned long size) {
    void *h;
    csc( cudaHostAlloc(&h, size, 0) );
    return h;
}

void free_pinned_mem(void* p) {
    csc( cudaFreeHost(p) );
}

static int __check_stream_done(cudaStream_t s)
{
    cudaError_t e = cudaStreamQuery(s);
    if (e == cudaSuccess) {
	return 1;
    } else if (e != cudaErrorNotReady)
	csc(e);

    return 0;
}

int execution_finished(struct service_request *sreq)
{
    cudaStream_t s = (cudaStream_t)get_stream(sreq->stream_id);
    return __check_stream_done(s);
}

int post_finished(struct service_request *sreq)
{
    cudaStream_t s = (cudaStream_t)get_stream(sreq->stream_id);
    return __check_stream_done(s);
}

/*
 * Allocation policy is simple here: copy what the kernel part does
 * for the GPU memory. This works because:
 *   - GPU memory and host memory are identical in size
 *   - Whenever a host memory region is allocated, the same-sized
 *     GPU memory must be used for its GPU computation.
 *   - The data field in ku_request also uses pinned memory but we
 *     won't allocate GPU memory for it cause it is just for
 *     service provider. This is fine since the data tend to be
 *     very tiny.
 */
int alloc_gpu_mem(struct service_request *sreq)
{
    int i, oks=0;
    unsigned long inaddr = (unsigned long)(sreq->kureq.input);
    unsigned long outaddr = (unsigned long)(sreq->kureq.output);

    for (i=0; i<KGPU_BUF_NR; i++) {
	unsigned long hostbase = (unsigned long)(hostbufs[i].addr);
	unsigned long devbase = (unsigned long)(devbufs[i].addr);

	// for input
        if (hostbase <= inaddr
	    && hostbase + hostbufs[i].size >= inaddr + sreq->kureq.insize) {
	    sreq->dinput = (void*)(devbase + (inaddr-hostbase));
	    if (oks)
		return 0;
	    oks++;
	}

	// for output
	if (hostbase <= outaddr
	    && hostbase + hostbufs[i].size >= outaddr + sreq->kureq.outsize) {
	    sreq->doutput = (void*)(devbase + (outaddr-hostbase));
	    if (oks)
		return 0;
	    oks++;
	}	
    }
    return 1;
}

void free_gpu_mem(struct service_request *sreq)
{
    sreq->dinput = NULL;
    sreq->doutput = NULL;
}

int alloc_stream(struct service_request *sreq)
{
    int i;

    for (i=0; i<MAX_STREAM_NR; i++) {
	if (!streamuses[i]) {
	    streamuses[i] = 1;
	    sreq->stream_id = i;
	    sreq->stream = (unsigned long)(streams[i]);
	    return 0;
	}
    }
    return 1;
}

void free_stream(struct service_request *sreq)
{
    if (sreq->stream_id >= 0 && sreq->stream_id < MAX_STREAM_NR) {
	streamuses[sreq->stream_id] = 0;
    }
}


int default_compute_size(struct service_request *sreq)
{
    sreq->block_x = default_block_size.x;
    sreq->block_y = default_block_size.y;
    sreq->grid_x = default_grid_size.x;
    sreq->grid_y = default_grid_size.y;
    return 0;
}

int default_prepare(struct service_request *sreq)
{
    cudaStream_t s = (cudaStream_t)get_stream(sreq->stream_id);
    csc( ah2dcpy( sreq->dinput, sreq->kureq.input, sreq->kureq.insize, s) );
    return 0;
}

int default_post(struct service_request *sreq)
{
    cudaStream_t s = (cudaStream_t)get_stream(sreq->stream_id);
    csc( ad2hcpy( sreq->kureq.output, sreq->doutput, sreq->kureq.outsize, s) );
    return 0;
}
