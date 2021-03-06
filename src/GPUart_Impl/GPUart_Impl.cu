//Copyright (c) 2017-2018 Christoph A. Hartmann, Ulrich Margull and Technische Hochschule Ingolstadt (THI)
//
//Permission is hereby granted, free of charge, to any person obtaining a copy of this 
//software and associated documentation files (the "Software"), to deal in the Software
//without restriction, including without limitation the rights to use, copy, modify, 
//merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
//permit persons to whom the Software is furnished to do so, subject to the following 
//conditions:
//
//The above copyright notice and this permission notice shall be included in all copies 
//or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
//PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT 
//HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION 
//OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
//SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

/*
* File:			GPUart_Impl.cu
* Created by: 	Christoph Hartmann
* Institute:	Technische Hochschule Ingolstadt
* Date:			07.04.2017								*/
/********************************************************
*   ___   ___    ___                   ___ 3      ___   *
*  |     |   |  |   |  |\  /|  |   |  |      |   |      *
*  |___  |   |  |___|  | \/ |  |   |  |___   |   |      *
*  |     |   |  |\     |    |  |   |      |  |   |      *
*  |     |___|  |  \   |    |  |___|   ___|  |   |___   *
*                                                       *
*********************************************************/

/*!	@file 	GPUart_Impl.cu
 *
 * 	@brief 	Implementation of the management component of the GPUart Implemenation layer.
 *
 * 			This file concentrates all GPGPU related memory declarations and allocations, memory transfers
 * 			operations, kernel launches, kernel initialisations, and GPU related implementation details.
 *
 *
 * 	@author	Christoph Hartmann
 *  @date	Created on: 7 Apr 2017
 */


/************************************************************************************************/
/* Includes																						*/
/************************************************************************************************/

//include header of Implementation layer
#include "GPUart_Impl.cuh"
#include "GPUart_Impl.h"

//include interfaces to other GPUart layer
#include "GPUart_Impl_Abstr_IF.h"
#include "GPUart_Impl_Sched_IF.h"

//include kernel libraries
#include "GPUart_Sobel.cuh"
#include "GPUart_MatrMul.cuh"



/************************************************************************************************/
/* Compiler Switches																			*/
/************************************************************************************************/
/*! @brief Use zero copy memory (requires integrated GPU)
 *
 * This MUST be defined so far, since memory transfers over PCIe are currently not implemented completely.
 *
 *  @see http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#zero-copy-memory
 *  @see https://software.intel.com/en-us/articles/getting-the-most-from-opencl-12-how-to-increase-performance-by-minimizing-buffer-copies-on-intel-processor-graphics
 */
#define S_USE_ZERO_COPY_FOR_GLOBAL_APPLICATION_MEMORY

/************************************************************************************************/
/* Constants																					*/
/************************************************************************************************/

/*!
 * 	@brief The length of the Event Queue, shared between GPU and CPU, used for kernel launch events.
 *
 * 	@see perKer_eventQueueCntHost_u32_host
 * 	@see perKer_eventQueueCntDevice_u32_host
 * 	@see perKer_eventQueue_s32_host
 */
#define C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH	(10)	//Length of event queue

/*!
 * 	@brief Event ID to indicate a termination request for the persistent kernel
 *
 * 	@see perKer_eventQueueCntHost_u32_host
 * 	@see perKer_eventQueueCntHost_u32_g
 */
#define C_PERSISTENT_KERNEL_TERMINATE			(-1)	//Event ID to terminate persistent kernel


/************************************************************************************************/
/* Typedef																						*/
/************************************************************************************************/

/*!
 * 	@brief Typedef for command queues (streams) to abstract GPGPU-API
 *
 * 	Command queues are required to improve the concurrency of memory and kernel operatation on the GPU.
 *
 * 	@see https://developer.download.nvidia.com/CUDA/training/StreamsAndConcurrencyWebinar.pdf
 * 	@see https://www.khronos.org/registry/OpenCL/sdk/1.0/docs/man/xhtml/clCreateCommandQueue.html
 */
typedef cudaStream_t command_queue_s;


/*!
 * 	@brief Typedef for a struct which combines global memory pointers, their related host pointers,
 * 		   and the size of the memory buffer.
 *
 */
typedef struct
{
	void ** mem_ptr;
	void ** host_ptr;
	size_t mem_size;
}device_global_memory_s;

/*!
 * 	@brief Typedef for a struct which combines constant memory pointers and the size of the related memory buffer.
 *
 */
typedef struct
{
	void ** mem_ptr;
	size_t mem_size;
}device_constant_memory_s;


/************************************************************************************************/
/* General Variables																			*/
/************************************************************************************************/

/*!
 *  @brief The command queue (stream) for memory operations
 */
static command_queue_s memory_command_queue_s;

/*!
 *  @brief The command queue (stream) for the persistent kernel
 */
static command_queue_s persistent_kernel_command_queue_s;


/*! @var perKer_isRunning_u32_host
 *  @brief A status flag, which represents the running status of the persistent kernel (host pointer).
 *  @see perKer_isRunning_u32_g
 */
/*! @var perKer_isRunning_u32_g
 *  @brief A status flag, which represents the running status of the persistent kernel (device pointer).
 *  @see perKer_isRunning_u32_host
 */
volatile uint32 *perKer_isRunning_u32_host;
uint32 *perKer_isRunning_u32_g;


/*! @var perKer_eventQueueCntHost_u32_host
 *  @brief The index of the tail of the event queue for kernel launches written by the host (host pointer).
 *  @see perKer_eventQueueCntDevice_u32_g
 */
/*! @var perKer_eventQueueCntHost_u32_g
 *  @brief The index of the tail of the event queue for kernel launches written by the host (device pointer).
 *  @see perKer_eventQueueCntHost_u32_host
 */
volatile uint32 *perKer_eventQueueCntHost_u32_host;
uint32 *perKer_eventQueueCntHost_u32_g;

/*! @var perKer_eventQueueCntDevice_u32_host
 *  @brief The index of the head of the event queue for kernel launches written by the device (host pointer).
 *  @see perKer_eventQueueCntDevice_u32_g
 */
/*! @var perKer_eventQueueCntDevice_u32_g
 *  @brief The index of the head of the event queue for kernel launches written by the device (device pointer).
 *  @see perKer_eventQueueCntDevice_u32_host
 */
volatile uint32 *perKer_eventQueueCntDevice_u32_host;
uint32 *perKer_eventQueueCntDevice_u32_g;


/*! @var perKer_eventQueue_s32_host
 *  @brief The event queue for kernel launch requests, written by the CPU and red by the GPU (host pointer).
 *
 *  		To request a kernel launch, write the kernel's ID (#kernel_task_id_e) into the tail of the queue.
 *  		Write #C_PERSISTENT_KERNEL_TERMINATE to terminate the persistent kernel #GPUart_Persistent_Kernel.
 *  @see perKer_eventQueue_s32_g
 */
/*! @var perKer_eventQueue_s32_g
 *  @brief The event queue for kernel launch requests, written by the CPU and red by the GPU (device pointer).
 *
 *      	To request a kernel launch, write the kernel's ID (#kernel_task_id_e) into the tail of the queue.
 *  		Write #C_PERSISTENT_KERNEL_TERMINATE to terminate the persistent kernel #GPUart_Persistent_Kernel.
 *  @see perKer_eventQueue_s32_host
 */
volatile sint32 *perKer_eventQueue_s32_host;
sint32 *perKer_eventQueue_s32_g;

/*! @var perKer_kernelTasksRunningStates_u32_host
 *  @brief A status flag, which represents the running status of each kernel (host pointer).
 *  @see perKer_kernelTasksRunningStates_u32_g
 */
/*! @var perKer_kernelTasksRunningStates_u32_g
 *  @brief A status flag, which represents the running status of each kernel (device pointer).
 *  @see perKer_kernelTasksRunningStates_u32_host
 */
volatile uint32 *perKer_kernelTasksRunningStates_u32_host;
uint32 *perKer_kernelTasksRunningStates_u32_g;

/*!
 *  @brief The allowed job cost per kernel
 *
 *  This value is equal to m * µ, whereby m is the number of Streaming Multiprocessors of the GPU
 *  #gpuS_nrOfMultiprocessor_u32 and µ is the resource factor #C_GPUS_RESOURCE_FACTOR.
 *
 *  @see kernel_task_id_e
 *  @see C_GPUS_RESOURCE_FACTOR
 *  @see gpuS_nrOfMultiprocessor_u32
 *  @see kernel_job_costs
 */
uint32 max_costs_per_kernel = 0;




/************************************************************************************************/
/* Kernel Task Variables - E_KTID_SOBEL1														*/
/************************************************************************************************/
sint32 * sob1_matrix_in_s32_g,  * sob1_matrix_in_s32_host;
sint32 * sob1_matrix_out_s32_g, * sob1_matrix_out_s32_host;

/* Synchronization variables */
uint32 * sync_SOB1_flags_in_u32_g;
uint32 * sync_SOB1_flags_out_u32_g;

/* Preemption related variables*/
sint32 * preempt_SOB1_flag_g;
volatile sint32 *preempt_SOB1_flag_host;
sint32 * preempt_SOB1_flag_internal_g;
sint32 * preempt_SOB1_sm_g;
volatile sint32 *preempt_SOB1_sm_host;

/* Buffer variables */
uint32 * sob1_buffer_loop_counter_u32_g;

/************************************************************************************************/
/* Kernel Task Variables - E_KTID_SOBEL2														*/
/************************************************************************************************/
sint32 * sob2_matrix_in_s32_g,  * sob2_matrix_in_s32_host;
sint32 * sob2_matrix_out_s32_g, * sob2_matrix_out_s32_host;

/* Synchronization variables */
uint32 * sync_SOB2_flags_in_u32_g;
uint32 * sync_SOB2_flags_out_u32_g;

/* Preemption related variables*/
sint32 * preempt_SOB2_flag_g;
volatile sint32 *preempt_SOB2_flag_host;
sint32 * preempt_SOB2_flag_internal_g;
sint32 * preempt_SOB2_sm_g;
volatile sint32 *preempt_SOB2_sm_host;

/* Buffer variables */
uint32 * sob2_buffer_loop_counter_u32_g;


/************************************************************************************************/
/* Kernel Task Variables - E_KTID_MM															*/
/************************************************************************************************/
float32 * mm_matrix_A_f32_g,  * mm_matrix_A_f32_host;
float32 * mm_matrix_B_f32_g,  * mm_matrix_B_f32_host;
float32 * mm_matrix_C_f32_g,  * mm_matrix_C_f32_host;

/* Synchronization variables */
uint32 * sync_MM_flags_in_u32_g;
uint32 * sync_MM_flags_out_u32_g;

/* Preemption related variables*/
sint32 * preempt_MM_flag_g;
volatile sint32 *preempt_MM_flag_host;
sint32 * preempt_MM_sm_g;
volatile sint32 *preempt_MM_sm_host;

/* Buffer variables */
uint32 * mm_buffer_blockY_g;
uint32 * mm_buffer_blockX_g;
uint32 * mm_buffer_M_g;


/************************************************************************************************/
/* Constant Variable Table																		*/
/************************************************************************************************/

/*!
 *  @brief The constant memory table
 *
 *  All constant memory buffers which must be written during runtime must be defined here.
 *  The i'th element represents the i'th constant memory buffer, define by #device_constant_memory_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: { (void **)& CONSTANT_BUFFER_NAME,
 *  SIZE_IN_BYTES }.
 *
 *  @see device_constant_memory_id_e
 */
static device_constant_memory_s constant_memory_list_a[E_CM_TOTAL_NR_OF_CONST_MEM_VARIABLES] =
{
//{ (void **)& VARIABLE_NAME,  SIZE IN BYTES	}
};


/************************************************************************************************/
/* Global Variable Table																		*/
/************************************************************************************************/

/*!
 *  @brief The global memory table
 *
 *  All global memory buffers which must be written or red during runtime must be defined here.
 *  The i'th element represents the i'th global memory buffer, define by #device_global_memory_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: { (void **)&
 *  GLOBAL_MEMORY_BUFFER_POINTER_DEVICE, GLOBAL_MEMORY_BUFFER_POINTER_HOST, SIZE_IN_BYTES }.
 *
 *  @see device_global_memory_id_e
 */
static device_global_memory_s global_memory_list_a[E_GM_TOTAL_NR_OF_GLOB_MEM_VARIABLES] =
{
	/* Sobel1 */
	{ (void **)&sob1_matrix_in_s32_g,		(void **)&sob1_matrix_in_s32_host,		C_SOB1_MATRIX_SIZE * sizeof(sint32)		}, //E_GM_ID_SOB1_MATRIX_IN
	{ (void **)&sob1_matrix_out_s32_g,		(void **)&sob1_matrix_out_s32_host,		C_SOB1_MATRIX_SIZE * sizeof(sint32)		}, //E_GM_ID_SOB1_MATRIX_OUT

	/* Sobel2 */
	{ (void **)&sob2_matrix_in_s32_g,		(void **)&sob2_matrix_in_s32_host,		C_SOB2_MATRIX_SIZE * sizeof(sint32)		}, //E_GM_ID_SOB2_MATRIX_IN
	{ (void **)&sob2_matrix_out_s32_g,		(void **)&sob2_matrix_out_s32_host,		C_SOB2_MATRIX_SIZE * sizeof(sint32)		}, //E_GM_ID_SOB2_MATRIX_OUT

	/* MatrMul */
	{ (void **)&mm_matrix_A_f32_g,			(void **)&mm_matrix_A_f32_host,			C_MM_MATRIX_TOTAL_SIZE * sizeof(sint32)	}, //E_GM_ID_MM_MATRIX_A
	{ (void **)&mm_matrix_B_f32_g,			(void **)&mm_matrix_B_f32_host,			C_MM_MATRIX_TOTAL_SIZE * sizeof(sint32)	}, //E_GM_ID_MM_MATRIX_B
	{ (void **)&mm_matrix_C_f32_g,			(void **)&mm_matrix_C_f32_host,			C_MM_MATRIX_TOTAL_SIZE * sizeof(sint32)	}  //E_GM_ID_MM_MATRIX_C
};


/************************************************************************************************/
/* Preemption Flag Table																		*/
/************************************************************************************************/

/*!
 *  @brief The preemption flag table
 *
 *  All preemption flags must be included by this table.
 *  The i'th element represents the i'th kernel, according to the enum #kernel_task_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: (volatile sint32**)&
 *  NAME_OF_PREEMPTION_FLAG_POINTER. If a kernel does not implement a preemption flag, because it
 *  is non-preemptive, insert a NULL.
 *
 *  @see kernel_task_id_e
 */
static volatile sint32** device_preemption_flags_a[E_KTID_NUMBER_OF_KERNEL_TASKS] =
{
	(volatile sint32**) &preempt_SOB1_flag_host,	//E_KTID_SOBEL1
	(volatile sint32**) &preempt_SOB2_flag_host,	//E_KTID_SOBEL2
	(volatile sint32**) &preempt_MM_flag_host		//E_KTID_MM
};

/************************************************************************************************/
/* Preemption Enabled Parameter Table															*/
/************************************************************************************************/

/*!
 *  @brief The preemption enabled table
 *
 *  The i'th element represents the i'th kernel, according to the enum #kernel_task_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: #C_TRUE if the related kernel
 *  is preemptive; #C_FALSE if the related kernel is non-preemptive.
 *
 *  @see kernel_task_id_e
 */
const static sint32 preemption_enabled_a[E_KTID_NUMBER_OF_KERNEL_TASKS] =
{
	C_TRUE,						//E_KTID_SOBEL1
	C_TRUE,						//E_KTID_SOBEL2
	C_TRUE						//E_KTID_MM
};


/************************************************************************************************/
/* Kernel State Machine Table																	*/
/************************************************************************************************/

/*!
 *  @brief The kernel state machine table
 *
 *  The i'th element represents the i'th kernel, according to the enum #kernel_task_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: &NAME_OF_STATE_MACHINE_POINTER.
 *  Use NULL if the related kernel is non-preemptive.
 *
 *  @see kernel_task_id_e
 */
static volatile sint32** device_kernel_task_SM_a[E_KTID_NUMBER_OF_KERNEL_TASKS] =
{
	&preempt_SOB1_sm_host,		//E_KTID_SOBEL1
	&preempt_SOB2_sm_host,		//E_KTID_SOBEL2
	&preempt_MM_sm_host			//E_KTID_MM
};

/*!
 *  @brief The number of state machines table
 *
 *  The i'th element represents the i'th kernel, according to the enum kernel_task_id_e
 *  in GPUart_Config.h. Each element must defined in the following style: NUMBER_OF_SM_IN_KERNEL.
 *  If a kernel preempts grid-synchronous then use the value 1u. If a kernel preempts thread-block
 *  synchronous then use the number of thread blocks of this kernel. If a kernel is non-preemptive
 *  then use 0u.
 *
 *  @see kernel_task_id_e
 */
static uint32 nb_of_StateMachines_in_kernel_a[E_KTID_NUMBER_OF_KERNEL_TASKS] =
{
	1u,							//E_KTID_SOBEL1	-> Grid-wide preemption
	1u,							//E_KTID_SOBEL2 -> Grid-wide preemption
	C_MM_NUMBER_OF_BLOCKS		//E_KTID_MM		-> Thread block-wide preemption
};


/************************************************************************************************/
/* Kernel Cost Table																			*/
/************************************************************************************************/

/*!
 *  @brief The job cost table
 *
 *  The i'th element represents the i'th kernel, according to the enum kernel_task_id_e
 *  in GPUart_Config.h. Each element represents the job costs of the related kernel.
 *  If a thread block of a kernel requires more then 1/µ of the available registers, shared memory,
 *  thread residency slots, or thread block residency slots of an Streaming Multiprocessor,
 *  then set corresponding  value to m * µ, whereby µ is the resource factor and m is the GPU's
 *  number of Streaming Multiprocessors. If a thread block of a kernel requires less then 1/µ of each
 *  resource type, then set the corresponding value to the kernels number of thread blocks.
 *
 *  @see kernel_task_id_e
 *  @see C_GPUS_RESOURCE_FACTOR
 *  @see gpuS_nrOfMultiprocessor_u32
 *  @see max_costs_per_kernel
 */
static uint8 kernel_job_costs[E_KTID_NUMBER_OF_KERNEL_TASKS] =
{
	C_SOB1_NUMBER_OF_BLOCKS,	//E_KTID_SOBEL1
	C_SOB2_NUMBER_OF_BLOCKS,	//E_KTID_SOBEL2
	C_MM_NUMBER_OF_BLOCKS		//E_KTID_MM
};

/*!
 *  @brief The device ID of the used GPU
 *
 *  @see http://docs.nvidia.com/cuda/cuda-c-programming-guide
 *  @see https://www.khronos.org/registry/OpenCL/sdk/1.0/docs/man/xhtml/clGetDeviceIDs.html
 */
static uint8 gpuI_deviceID_u8 = 0;





/************************************************************************************************/
/* Persistent Kernel																			*/
/************************************************************************************************/

/*!
 *  @brief The persistent kernel (GPU Daemon) which is used to reduce kernel launch latencies.
 *
 *  The kernel arguments must include all global memory buffers of all kernels in this system, since
 *  this kernel is used to launch GPGPU kernel on demand. The persistent kernel reduces kernel launch
 *  latencies by bypassing the GPGPU driver stack when launching kernels.
 *
 *  @see Mrozek et al. GPU Daemon: Road to zero cost submission, in Proceedings of the 4th International
 *  Workshop on OpenCL, Vienna, Austria, 2016 -> https://dl.acm.org/citation.cfm?id=2909450
 */
__global__ void GPUart_Persistent_Kernel
(
	//Persistent Kernel Management Data
	uint32*  __restrict__ perKer_isRunning_u32_g,
	uint32*  __restrict__ perKer_eventQueueCntDevice_u32_g,
	volatile uint32 * __restrict__ perKer_eventQueueCntHost_u32_g,
	volatile sint32 * __restrict__ perKer_eventQueue_s32_g,
	volatile uint32*  __restrict__ perKer_kernelTasksRunningStates_u32_g,

	//SOBEL1 Variables
	sint32  * __restrict__ sob1_matrix_in_s32_g,
	sint32  * __restrict__ sob1_matrix_out_s32_g,

	//SOBEL2 Variables
	sint32  * __restrict__ sob2_matrix_in_s32_g,
	sint32  * __restrict__ sob2_matrix_out_s32_g,

	//MM Variables
	float32  * __restrict__ mm_matrix_A_f32_g,
	float32  * __restrict__ mm_matrix_B_f32_g,
	float32  * __restrict__ mm_matrix_C_f32_g,

	/* Synchronization variables */

	//SOBEL1
	uint32	* __restrict__ sync_SOB1_flags_in_u32_g,
	uint32	* __restrict__ sync_SOB1_flags_out_u32_g,
	//SOBEL2
	uint32	* __restrict__ sync_SOB2_flags_in_u32_g,
	uint32	* __restrict__ sync_SOB2_flags_out_u32_g,
	//MM
	uint32	* __restrict__ sync_MM_flags_in_u32_g,
	uint32	* __restrict__ sync_MM_flags_out_u32_g,

	/* Preemption variables */

	//SOB1
	sint32	* __restrict__	preempt_SOB1_flag_g,
	sint32	* __restrict__	preempt_SOB1_flag_internal_g,
	sint32	* __restrict__	preempt_SOB1_sm_g,
	//SOB2
	sint32	* __restrict__	preempt_SOB2_flag_g,
	sint32	* __restrict__	preempt_SOB2_flag_internal_g,
	sint32	* __restrict__	preempt_SOB2_sm_g,
	//MM
	sint32	* __restrict__	preempt_MM_flag_g,
	sint32	* __restrict__	preempt_MM_sm_g,

	/* Buffer variables */

	//SOB1
	uint32  * __restrict__ sob1_buffer_loop_counter_u32_g,
	//SOB2
	uint32  * __restrict__ sob2_buffer_loop_counter_u32_g,
	//MM
	uint32 *  __restrict__ mm_buffer_blockY_g,
	uint32 *  __restrict__ mm_buffer_blockX_g,
	uint32 *  __restrict__ mm_buffer_M_g
)
{
	cudaStream_t stream_kernel_SOB1;
	cudaStream_t stream_kernel_SOB2;
	cudaStream_t stream_kernel_MM;

	cudaStreamCreateWithFlags(&stream_kernel_SOB1,   cudaStreamNonBlocking);
	cudaStreamCreateWithFlags(&stream_kernel_SOB2,   cudaStreamNonBlocking);
	cudaStreamCreateWithFlags(&stream_kernel_MM,	 cudaStreamNonBlocking);

	while(C_TRUE)
	{
		//Check if host has issued a new event to queue
		if(*perKer_eventQueueCntDevice_u32_g != *perKer_eventQueueCntHost_u32_g)
		{
			//Calculate position of next available event in queue
			*perKer_eventQueueCntDevice_u32_g = (*perKer_eventQueueCntDevice_u32_g + 1)
												 % C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH;

			//Interpret new event
			switch(perKer_eventQueue_s32_g[*perKer_eventQueueCntDevice_u32_g])
			{
				case C_PERSISTENT_KERNEL_TERMINATE: 	//Terminate persistent Kernel

					*perKer_isRunning_u32_g = C_FALSE;
					return;

				case E_KTID_SOBEL1:
					__syncthreads();
					Sobel_Kernel<<<C_SOB1_NUMBER_OF_BLOCKS,  C_SOB1_LOCAL_WORK_SIZE, 0, stream_kernel_SOB1>>>
					(
						sob1_matrix_in_s32_g,
						sob1_matrix_out_s32_g,
						C_SOB1_HEIGHT,
						C_SOB1_WIDTH,
						//Preemption status variables
						preempt_SOB1_flag_g,
						preempt_SOB1_flag_internal_g,
						preempt_SOB1_sm_g,
						//Buffer variables
						sob1_buffer_loop_counter_u32_g,
						//Synchronization variables
						sync_SOB1_flags_in_u32_g,
						sync_SOB1_flags_out_u32_g,
						/* Running status flag */
						&perKer_kernelTasksRunningStates_u32_g[E_KTID_SOBEL1]
					);
					__syncthreads();
					break;

				case E_KTID_SOBEL2:
					__syncthreads();
					Sobel_Kernel<<<C_SOB2_NUMBER_OF_BLOCKS,  C_SOB2_LOCAL_WORK_SIZE, 0, stream_kernel_SOB2>>>
					(
						sob2_matrix_in_s32_g,
						sob2_matrix_out_s32_g,
						C_SOB2_HEIGHT,
						C_SOB2_WIDTH,
						//Preemption status variables
						preempt_SOB2_flag_g,
						preempt_SOB2_flag_internal_g,
						preempt_SOB2_sm_g,
						//Buffer variables
						sob2_buffer_loop_counter_u32_g,
						//Synchronization variables
						sync_SOB2_flags_in_u32_g,
						sync_SOB2_flags_out_u32_g,
						/* Running status flag */
						&perKer_kernelTasksRunningStates_u32_g[E_KTID_SOBEL2]
					);
					__syncthreads();
					break;

				case E_KTID_MM:
					__syncthreads();

					dim3 dimGridMM(C_MM_NUMBER_OF_BLOCKS_X, C_MM_NUMBER_OF_BLOCKS_Y);
					dim3 dimBlockMM(C_MM_LOCAL_WORK_SIZE_X, C_MM_LOCAL_WORK_SIZE_Y);


					MatrMul_Kernel<<<dimGridMM,  dimBlockMM, 0, stream_kernel_MM>>>
					(
						//Functional Data
						mm_matrix_A_f32_g,
						mm_matrix_B_f32_g,
						mm_matrix_C_f32_g,

						//Preemption Buffer
						mm_buffer_blockY_g,
						mm_buffer_blockX_g,
						mm_buffer_M_g,

						//Preemption Managment
						preempt_MM_flag_g,
						preempt_MM_sm_g,

						//Synchronization Flags
						sync_MM_flags_in_u32_g,
						sync_MM_flags_out_u32_g,

						//Running status flag
						&perKer_kernelTasksRunningStates_u32_g[E_KTID_MM]
					);

					__syncthreads();
					break;
			}
			__threadfence_system();
		}
	}

}



/************************************************************************************************/
/* General function definition																	*/
/************************************************************************************************/



/*! @brief Copy data from host memory to device memory.
 *
 * 	Device memory may be shared physical memory or discrete device memory. The device driver
 * 	API call may depend on the type of device memory (global or texture memory).
 *
 *  @param[in] void * variable_p -> The host variable to be copied
 *  @param[in]	device_global_memory_id_e id_p -> The ID of the global memory variable
 *
 *  @return GPUART_SUCCESS if memory copy operation has been successfully.
 *  @return GPUART_ERROR_INVALID_ARGUMENT if id_p is an invalid ID.
 */
GPUart_Retval gpuI_memcpyHost2Device(void * variable_p, device_global_memory_id_e id_p)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	device_global_memory_s device_memory;
	
	if((id_p >= E_GM_TOTAL_NR_OF_GLOB_MEM_VARIABLES)||(variable_p == NULL))
	{
		retval = GPUART_ERROR_INVALID_ARGUMENT;
	}
	else
	{
		device_memory = global_memory_list_a[id_p];

#ifdef S_USE_ZERO_COPY_FOR_GLOBAL_APPLICATION_MEMORY
		memcpy(*device_memory.host_ptr, variable_p, device_memory.mem_size);
#else
		CUDA_CHECK_RETURN(cudaMemcpyAsync(*device_memory.mem_ptr, variable_p, device_memory.mem_size,
												cudaMemcpyHostToDevice, memory_command_queue_s));

#endif
	}

	return retval;
}


/*! @brief Copy data from device memory to host memory.
 *
 * 	Device memory may be shared physical memory or discrete device memory. The device driver
 * 	API call may depend on the type of device memory (global or texture memory).
 *
 *  @param[out] void * variable_p -> The host variable to be written
 *  @param[in]	device_global_memory_id_e id_p -> The ID of the global memory variable
 *
 *  @return GPUART_SUCCESS if memory copy operation has been successfully.
 *  @return GPUART_ERROR_INVALID_ARGUMENT if id_p is an invalid ID.
 */
GPUart_Retval gpuI_memcpyDevice2Host(void * variable_p, device_global_memory_id_e id_p)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	device_global_memory_s device_memory;

	if((id_p >= E_GM_TOTAL_NR_OF_GLOB_MEM_VARIABLES)||(variable_p == NULL))
	{
		retval = GPUART_ERROR_INVALID_ARGUMENT;
	}
	else
	{
		device_memory = global_memory_list_a[id_p];
#ifdef S_USE_ZERO_COPY_FOR_GLOBAL_APPLICATION_MEMORY
		memcpy(variable_p, *device_memory.host_ptr, device_memory.mem_size);
#else
		CUDA_CHECK_RETURN(cudaMemcpyAsync(variable_p,  *device_memory.mem_ptr, device_memory.mem_size,
												cudaMemcpyDeviceToHost, memory_command_queue_s));
#endif
	}

	return retval;
}

/*************************************************************************************************
Function: 		gpuI_memcpyConstantMemory
Description:	Copies data from host memory to constant device memory. The copy is only possible
				if persistent GPUart kernel is not running, since a constant memory variable is 
				immutable during kernel execution and its value is inherited from parent to child 
				kernel.
*/

/*! @brief Copy data from host memory to constant device memory.
 *
 *		The copy is only possible if persistent GPUart kernel #GPUart_Persistent_Kernel
 *		is not running, since a constant memory data is immutable during kernel execution
 *		and its value is inherited from parent to child kernel.
 *
 *  @param[in] void * variable_p -> The host variable to be copied
 *  @param[in] device_constant_memory_id_e id_p -> The ID of the constant memory buffer
 *
 *  @return GPUART_SUCCESS if memory copy operation has been successfully.
 *  @return GPUART_ERROR_INVALID_ARGUMENT if id_p is an invalid ID.
 */
GPUart_Retval gpuI_memcpyConstantMemory(void * variable_p, device_constant_memory_id_e id_p)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	device_constant_memory_s device_memory;
	
	if((id_p >= E_CM_TOTAL_NR_OF_CONST_MEM_VARIABLES) || (variable_p == NULL))
	{
		retval = GPUART_ERROR_INVALID_ARGUMENT;
	}
	else
	{
		if(*perKer_isRunning_u32_host == C_TRUE)
		{
			retval = GPUART_ERROR_PESISTENT_KERNEL_IS_RUNNING;
		}
		else
		{
			device_memory = constant_memory_list_a[id_p];
			CUDA_CHECK_RETURN(cudaMemcpyToSymbolAsync(*device_memory.mem_ptr, variable_p, device_memory.mem_size, 0,
															cudaMemcpyHostToDevice, memory_command_queue_s));
			CUDA_CHECK_RETURN(cudaStreamSynchronize(memory_command_queue_s));
		}
	}

	return retval;
}



/*!
 *  @brief Request the launch of a GPGPU kernel.
 *
 *  @param kernel_task_id_e task_id_e -> The ID of the kernel to be launched.
 *
 *  @return GPUART_SUCCESS if kernel launch has been successfully.
 *  @return GPUART_ERROR_NOT_READY if launch request is already active.
 */
GPUart_Retval gpuI_runJob(kernel_task_id_e task_id_e)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	uint32 eventQueueCntHost_u32_l;
	uint32 kernelStatus = ((volatile uint32 *)perKer_kernelTasksRunningStates_u32_host)[task_id_e];



	if((kernelStatus == C_KERNEL_SUSPENDED)||
	   (kernelStatus == C_KERNEL_READY)||
	   (kernelStatus == C_KERNEL_INIT))
	{
		perKer_kernelTasksRunningStates_u32_host[task_id_e] = C_KERNEL_ACTIVE;


//		//Reset Preemption flag
		if(device_preemption_flags_a[task_id_e] != NULL)
		{
//			printf("-> Setze PreemptionFlag zurueck fue Kernel %d", task_id_e);
			**device_preemption_flags_a[task_id_e] = C_FALSE;
		}



		//Reset state machine
		if((kernelStatus == C_KERNEL_READY)||(kernelStatus == C_KERNEL_INIT))
		{
			//Do not reset Kernel SM if kernel has been preempted
			if(device_kernel_task_SM_a[task_id_e] != NULL)
			{
				//**device_kernel_task_SM_a[task_id_e] = 0; --> Old. Now, all SMs of an Kernel are set to zero
				memset((void *)*device_kernel_task_SM_a[task_id_e], 0, nb_of_StateMachines_in_kernel_a[task_id_e] * sizeof(sint32));
			}
		}

		//Calculate next position in persistent kernel event queue
		eventQueueCntHost_u32_l = (perKer_eventQueueCntHost_u32_host[0] + 1)
												% C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH;


		//Set kernel call event
		perKer_eventQueue_s32_host[eventQueueCntHost_u32_l] = task_id_e;


		//Make new event visible
		*perKer_eventQueueCntHost_u32_host = eventQueueCntHost_u32_l;

		if((eventQueueCntHost_u32_l == UINT32_MAX )||(eventQueueCntHost_u32_l > C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH))
		{
			printf("\nFEHLER: Host Counter falsch");
		}
	}
	else
	{
		retval = GPUART_ERROR_NOT_READY;
	}

	return retval;
}

/*************************************************************************************************
Function: 		gpuI_preemptJob
Description:	Issue preemption of a specific kernel task
*/
GPUart_Retval gpuI_preemptJob(kernel_task_id_e task_id_p)
{
	GPUart_Retval retval = GPUART_SUCCESS;

	//Check if kernel task is preemptive
	if(preemption_enabled_a[task_id_p] == C_TRUE)
	{
		//Set preemption flag
		**device_preemption_flags_a[task_id_p] = C_TRUE;
	}
	else
	{
		//Kernel task is not preemptive -> no operation
		retval = GPUART_ERROR_NO_OPERTATION;
	}

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_queryKernelIsRunning
Description:	Query kernel running status.
				Returns GPUART_SUCCESS if kernel task is not running.
				Returns GPUART_ERROR_NOT_READY if kernel task is still running.

*/
uint32 gpuI_queryKernelIsRunning(kernel_task_id_e task_id_e)
{
	uint32 retval = C_TRUE;

	//Query stream whether there is a running operation
	if((perKer_kernelTasksRunningStates_u32_host[task_id_e] == C_KERNEL_TERMINATED_SUCESSFUL)||
		(perKer_kernelTasksRunningStates_u32_host[task_id_e] == C_KERNEL_SUSPENDED)||
	   (perKer_kernelTasksRunningStates_u32_host[task_id_e] == C_KERNEL_INIT))
	{
		//Kernel task is not running -> success
		retval = C_FALSE;
	}
	else
	{
		//Kernel is still running
		retval = C_TRUE;
	}

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_queryKernelTerminatedSuccessful
Description:	Query kernel running status.
				Returns GPUART_SUCCESS if kernel task is not running.
				Returns GPUART_ERROR_NOT_READY if kernel task is still running.

*/
uint32 gpuI_queryKernelTerminatedSuccessful(kernel_task_id_e task_id_e)
{
	uint32 retval = C_TRUE;

	//Query stream whether there is a running operation
	if(perKer_kernelTasksRunningStates_u32_host[task_id_e] == C_KERNEL_TERMINATED_SUCESSFUL)
	{
		//Kernel task is not running -> success
	}
	else
	{
		//Kernel is still running
		retval = C_FALSE;
	}

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_queryKernelTerminatedSuccessful
Description:	Query kernel running status.
				Returns GPUART_SUCCESS if kernel task is not running.
				Returns GPUART_ERROR_NOT_READY if kernel task is still running.

*/
uint32 gpuI_queryKernelPreempted(kernel_task_id_e task_id_e)
{
	uint32 retval = C_TRUE;

	//Query stream whether there is a running operation
	if(perKer_kernelTasksRunningStates_u32_host[task_id_e] == C_KERNEL_SUSPENDED)
	{
		//Kernel task is not running -> success
	}
	else
	{
		//Kernel is still running
		retval = C_FALSE;
	}

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_getJobCosts
Description:	Returns the number of thread blocks, i.e. the number of Multiprocessors used for
				this kernel.
*/
uint32 gpuI_getJobCosts(kernel_task_id_e task_id_e)
{
	uint32 retval = kernel_job_costs[task_id_e];

	if(retval > max_costs_per_kernel)
	{
		retval = max_costs_per_kernel;
	}

	return retval;
}



/*************************************************************************************************
Function: 		gpuI_getJobCosts
Description:	Sets the internal status of the corresponding kernel to ready. This function is
				called after a new job has been enqueued.
*/
GPUart_Retval gpuI_SetKernelStatusReady(kernel_task_id_e task_id_e)
{
	GPUart_Retval retval = GPUART_SUCCESS;

	perKer_kernelTasksRunningStates_u32_host[task_id_e] = C_KERNEL_READY;

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_getJobCosts
Description:	Returns the number of thread blocks, i.e. the number of Multiprocessors used for
				this kernel.
*/
GPUart_Retval gpuI_get_NrOfMultiprocessors(uint32* nrOfMultprocessors, uint32 resourceFactor)
{
	GPUart_Retval retval = GPUART_SUCCESS;

	cudaDeviceProp deviceProp_s;
	CUDA_CHECK_RETURN(cudaGetDeviceProperties(&deviceProp_s, gpuI_deviceID_u8));


	*nrOfMultprocessors = deviceProp_s.multiProcessorCount * resourceFactor;
	max_costs_per_kernel =  deviceProp_s.multiProcessorCount * resourceFactor;

	printf("\nNumber of multiprocessors on the device: %d", *nrOfMultprocessors);

	if(*nrOfMultprocessors == 0)
	{
		retval = GPUART_NO_SUCCESS;
	}

	return retval;
}




/*************************************************************************************************
Function: 		gpuI_init()
Description:	Initializes GPGPU Runtime, thus it initializes command_queues, device variables 
				and host variables.
*/
GPUart_Retval gpuI_init(void)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	int deviceCount_u32 = 0;
	

	CUDA_CHECK_RETURN(cudaThreadExit());


	CUDA_CHECK_RETURN(cudaGetDeviceCount(&deviceCount_u32));
	for (int i = 0; i < deviceCount_u32; i++) {
		cudaDeviceProp prop;
		CUDA_CHECK_RETURN(cudaGetDeviceProperties(&prop, i));
		if(prop.integrated)
		{
			printf("\nDevice %d with shared physical memory selected", i);
			printf("\nMax Block Size: %d", prop.maxThreadsPerBlock);
			printf("\nRegs per SM: %d", prop.regsPerMultiprocessor);
			printf("\nShared memory per SM: %lu", prop.sharedMemPerBlock);
			gpuI_deviceID_u8 = i;
			break;
		}
	}

	CUDA_CHECK_RETURN(cudaSetDevice(gpuI_deviceID_u8));

	/* Initialize device configurations */
	CUDA_CHECK_RETURN(cudaSetDeviceFlags(cudaDeviceMapHost));



	CUDA_CHECK_RETURN(cudaDeviceSynchronize());

	/* Initialize command queues */
	CUDA_CHECK_RETURN( cudaStreamCreate(&memory_command_queue_s) );
	CUDA_CHECK_RETURN( cudaStreamCreate(&persistent_kernel_command_queue_s) );


	/* Device only variables */

	/* Sobel1 ***********************************************************************************************************/
	/* Initialize synchronization flags*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_SOB1_flags_in_u32_g,   C_SOB1_NUMBER_OF_BLOCKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_SOB1_flags_out_u32_g,  C_SOB1_NUMBER_OF_BLOCKS * sizeof(uint32)) );

	/* Initialize preemption managment variables*/
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_SOB1_flag_host, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_SOB1_flag_g, (void *)preempt_SOB1_flag_host, 0) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&preempt_SOB1_flag_internal_g, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_SOB1_sm_host, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_SOB1_sm_g, (void *)preempt_SOB1_sm_host, 0) );

	/* Initialize preemption buffer*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sob1_buffer_loop_counter_u32_g,  C_SOB1_GLOBAL_WORK_SIZE * sizeof(uint32)) );



	/* Sobel2 ***********************************************************************************************************/
	/* Initialize synchronization flags*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_SOB2_flags_in_u32_g,   C_SOB2_NUMBER_OF_BLOCKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_SOB2_flags_out_u32_g,  C_SOB2_NUMBER_OF_BLOCKS * sizeof(uint32)) );

	/* Initialize preemption managment variables*/
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_SOB2_flag_host, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_SOB2_flag_g, (void *)preempt_SOB2_flag_host, 0) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&preempt_SOB2_flag_internal_g, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_SOB2_sm_host, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_SOB2_sm_g, (void *)preempt_SOB2_sm_host, 0) );

	/* Initialize preemption buffer*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sob2_buffer_loop_counter_u32_g,  C_SOB2_GLOBAL_WORK_SIZE * sizeof(uint32)) );



	/* MatrMul *********************************************************************************************************/
	/* Initialize synchronization flags*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_MM_flags_in_u32_g,   C_MM_NUMBER_OF_BLOCKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&sync_MM_flags_out_u32_g,  C_MM_NUMBER_OF_BLOCKS * sizeof(uint32)) );

	/* Initialize preemption managment variables*/
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_MM_flag_host, sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_MM_flag_g, (void *)preempt_MM_flag_host, 0) );
	CUDA_CHECK_RETURN( cudaMallocHost( (void **)&preempt_MM_sm_host, C_MM_NUMBER_OF_BLOCKS * sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&preempt_MM_sm_g, (void *)preempt_MM_sm_host, 0) );

	/* Initialize preemption buffer*/
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&mm_buffer_blockY_g,  C_MM_NUMBER_OF_BLOCKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&mm_buffer_blockX_g,  C_MM_NUMBER_OF_BLOCKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaMalloc( (void **)&mm_buffer_M_g,  C_MM_NUMBER_OF_BLOCKS * sizeof(uint32)) );



	/* Initialize persistent kernel management variables */
	CUDA_CHECK_RETURN( cudaMallocHost( (void **) &perKer_isRunning_u32_host, sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&perKer_isRunning_u32_g, (void *)perKer_isRunning_u32_host, 0) );

	CUDA_CHECK_RETURN( cudaMallocHost( (void **) &perKer_eventQueueCntDevice_u32_host, sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&perKer_eventQueueCntDevice_u32_g, (void *)perKer_eventQueueCntDevice_u32_host, 0) );

	CUDA_CHECK_RETURN( cudaMallocHost( (void **) &perKer_eventQueueCntHost_u32_host, sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&perKer_eventQueueCntHost_u32_g, (void *)perKer_eventQueueCntHost_u32_host, 0) );

	CUDA_CHECK_RETURN( cudaMallocHost( (void **) &perKer_eventQueue_s32_host, C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH * sizeof(sint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&perKer_eventQueue_s32_g, (void *)perKer_eventQueue_s32_host, 0) );

	CUDA_CHECK_RETURN( cudaMallocHost( (void **) &perKer_kernelTasksRunningStates_u32_host, E_KTID_NUMBER_OF_KERNEL_TASKS * sizeof(uint32)) );
	CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)&perKer_kernelTasksRunningStates_u32_g, (void *)perKer_kernelTasksRunningStates_u32_host, 0) );




	/* Initialize global device application variables */
	for(int i = 0; i < E_GM_TOTAL_NR_OF_GLOB_MEM_VARIABLES; i++ )
	{
#ifdef S_USE_ZERO_COPY_FOR_GLOBAL_APPLICATION_MEMORY
		CUDA_CHECK_RETURN( cudaMallocHost( (void **)global_memory_list_a[i].host_ptr, global_memory_list_a[i].mem_size) );
		CUDA_CHECK_RETURN( cudaHostGetDevicePointer( (void **)global_memory_list_a[i].mem_ptr, (void *) *global_memory_list_a[i].host_ptr, 0) );
#else
		CUDA_CHECK_RETURN( cudaMalloc((void **)global_memory_list_a[i].mem_ptr, global_memory_list_a[i].mem_size) );
#endif
	}


	//Initialize status variables
	*perKer_isRunning_u32_host = 0;
	*perKer_eventQueueCntDevice_u32_host = 0;
	*perKer_eventQueueCntHost_u32_host = 0;


	for(int i = 0; i < E_KTID_NUMBER_OF_KERNEL_TASKS; i++)
	{
		perKer_kernelTasksRunningStates_u32_host[i] = C_KERNEL_INIT;
		if(device_preemption_flags_a[i] != NULL)
		{
			**device_preemption_flags_a[i] = C_FALSE;
		}

		if(device_kernel_task_SM_a[i] != NULL)
		{
			**device_preemption_flags_a[i] = C_FALSE;
		}
	}


	return retval;
}

//TODO:Wird der persistent Kernel gestartet, so sollte ein Flag gesetzt werden, was das Schreiben von COnstanten variablen ablehnt
/*************************************************************************************************
Function: 		gpuI_start()
Description:	Start execution of persistent GPUart kernel.
*/
GPUart_Retval gpuI_start(void)
{
	GPUart_Retval retval = GPUART_SUCCESS;

	*perKer_isRunning_u32_host = C_TRUE;	//After setting this flag constant memory writes are disabled


	CUDA_CHECK_RETURN(cudaDeviceSynchronize());

	GPUart_Persistent_Kernel <<<1, 1, 0, persistent_kernel_command_queue_s>>>
	(
		perKer_isRunning_u32_g,
		perKer_eventQueueCntDevice_u32_g,
		perKer_eventQueueCntHost_u32_g,
		perKer_eventQueue_s32_g,
		perKer_kernelTasksRunningStates_u32_g,


		//Sobel1 variables
		sob1_matrix_in_s32_g,
		sob1_matrix_out_s32_g,

		//Sobel2 variables
		sob2_matrix_in_s32_g,
		sob2_matrix_out_s32_g,

		//MM variables
		mm_matrix_A_f32_g,
		mm_matrix_B_f32_g,
		mm_matrix_C_f32_g,

		//Synchronization variables
		sync_SOB1_flags_in_u32_g,
		sync_SOB1_flags_out_u32_g,
		sync_SOB2_flags_in_u32_g,
		sync_SOB2_flags_out_u32_g,
		sync_MM_flags_in_u32_g,
		sync_MM_flags_out_u32_g,

		//Preemption variables
		preempt_SOB1_flag_g,
		preempt_SOB1_flag_internal_g,
		preempt_SOB1_sm_g,
		preempt_SOB2_flag_g,
		preempt_SOB2_flag_internal_g,
		preempt_SOB2_sm_g,
		preempt_MM_flag_g,
		preempt_MM_sm_g,

		//Buffer variables

		//SOB1
		sob1_buffer_loop_counter_u32_g,
		//SOB2
		sob2_buffer_loop_counter_u32_g,
		//MM
		mm_buffer_blockY_g,
		mm_buffer_blockX_g,
		mm_buffer_M_g

	);

	printf(".. started");
	fflush(stdout);



	return retval;
}

/*************************************************************************************************
Function: 		gpuI_stop()
Description:	Stop execution of persisten GPUart kernel. 
*/
GPUart_Retval gpuI_stop(void)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	
	uint32 eventQueueCntHost_u32_l;

	printf("\nSTOP PERSISTENT KERNEL");


	//Calculate next position in persistent kernel event queue
	eventQueueCntHost_u32_l = (*perKer_eventQueueCntHost_u32_host + 1) % C_PERSISTENT_KERNEL_EVENT_QUEUE_LENGTH;

	//Set termination event
	perKer_eventQueue_s32_host[eventQueueCntHost_u32_l] = C_PERSISTENT_KERNEL_TERMINATE;

	//Make new event visible
	*perKer_eventQueueCntHost_u32_host = eventQueueCntHost_u32_l;

	return retval;
}


/*************************************************************************************************
Function: 		gpuI_destroy()
Description:	Terminates GPUart. 
				Free dedicated or shared device memory. Destroy command_queues.
*/
GPUart_Retval gpuI_destroy(void)
{
	GPUart_Retval retval = GPUART_SUCCESS;
	
	CUDA_CHECK_RETURN(cudaDeviceSynchronize());



	/* Free global device variables */
	for(int i = 0; i < (int)E_GM_TOTAL_NR_OF_GLOB_MEM_VARIABLES; i++ )
	{
#ifdef S_USE_ZERO_COPY_FOR_GLOBAL_APPLICATION_MEMORY
		CUDA_CHECK_RETURN( cudaFreeHost(*global_memory_list_a[i].host_ptr) );
#else
		CUDA_CHECK_RETURN( cudaFree(*global_memory_list_a[i].mem_ptr) );
#endif
	}

	/* Destroy device only variables */


	/* Destroy persistent kernel variables */
	CUDA_CHECK_RETURN(cudaFreeHost((void *)perKer_isRunning_u32_host));
	CUDA_CHECK_RETURN(cudaFreeHost((void *)perKer_eventQueueCntDevice_u32_host));
	CUDA_CHECK_RETURN(cudaFreeHost((void *)perKer_eventQueueCntHost_u32_host));
	CUDA_CHECK_RETURN(cudaFreeHost((void *)perKer_eventQueue_s32_host));
	CUDA_CHECK_RETURN(cudaFreeHost((void *)perKer_kernelTasksRunningStates_u32_host));



	/* Destroy command queues */
	CUDA_CHECK_RETURN( cudaStreamDestroy(memory_command_queue_s) );
	CUDA_CHECK_RETURN( cudaStreamDestroy(persistent_kernel_command_queue_s) );



	CUDA_CHECK_RETURN( cudaDeviceReset());

	return retval;
}




