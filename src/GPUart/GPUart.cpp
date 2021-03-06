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
* File:			GPUart.cpp
* Created by: 	Christoph Hartmann
* Institute:	Technische Hochschule Ingolstadt
* Date:			11.05.2017								*/
/********************************************************
*   ___   ___    ___                   ___ 3      ___   *
*  |     |   |  |   |  |\  /|  |   |  |      |   |      *
*  |___  |   |  |___|  | \/ |  |   |  |___   |   |      *
*  |     |   |  |\     |    |  |   |      |  |   |      *
*  |     |___|  |  \   |    |  |___|   ___|  |   |___   *
*                                                       *
*********************************************************/

/*!	@file 	GPUart.cpp
 *
 * 	@brief 	Manages the status and context of GPUart.
 *
 * 			The inferface to init, start, stop, and destroy GPUart.
 * 			Provides also the interface to trigger scheduler of GPUart
 * 			(The prototype of GPUart schedules by polling).
 *
 * 	@author	Christoph Hartmann
 *  @date	Created on: 11 May 2017
 */


/************************************************************************************************/
/* Includes																						*/
/************************************************************************************************/
#include "../GPUart_Impl/GPUart_Impl.h"
#include "../GPUart_Abstraction/GPUart_Abstraction.h"
#include "../GPUart_Scheduler/GPUart_Scheduler.h"



/************************************************************************************************/
/* General GPUart function																		*/
/************************************************************************************************/


/*! @brief	Initialize all layers of GPUart.
 *
 * 			This function calls the init-functions of the Implementation, Scheduling, and Abstraction layers
 * 			to initialize GPUart related context.
 * 			Call this function before GPUart_start().
 *
 * 	@param 	void
 * 	@return	void
 */
void GPUart_init(void)
{
	GPUART_CHECK_RETURN( gpuI_init() );
	GPUART_CHECK_RETURN( gpuS_init() );
	GPUART_CHECK_RETURN( gpuA_init() );
}


/*! @brief	Enable kernel execution on the GPU.
 *
 * 			This function calls the Implementation layer to launch the persistent GPU thread,
 * 			which is used to reduce kernel launch latencies.
 * 			Call this function after GPUart_init().
 *
 * 	@param 	void
 * 	@return	void
 */
void GPUart_start(void)
{
	GPUART_CHECK_RETURN( gpuI_start() );
}


/*! @brief	Disable kernel execution on the GPU.
 *
 * 			This function calls the Implementation layer to terminate the persistent GPU thread.
 * 			Call this function before GPUart_destroy().
 *
 * 	@param 	void
 * 	@return	void
 */
void GPUart_stop(void)
{
	GPUART_CHECK_RETURN( gpuI_stop() );
}

/*! @brief	Destroy all GPUart related context.
 *
 * 			This function calls the destroy-functions of the Implementation, Scheduling, and Abstraction layers
 * 			to destroy GPUart related context.
 * 			Call this function after GPUart_stop().
 *
 * 	@param 	void
 * 	@return	void
 */
void GPUart_destroy(void)
{
	GPUART_CHECK_RETURN( gpuI_destroy() );
	GPUART_CHECK_RETURN( gpuS_destroy() );
	GPUART_CHECK_RETURN( gpuA_destroy() );
}

/*! @brief	Trigger the scheduler of GPUart to process the scheduling decision.
 *
 * 			Trigger the scheduler of GPUart to process the scheduling decision
 * 			(The prototype of GPUart schedules by polling).
 *
 * 	@param 	void
 * 	@return	void
 */
void GPUart_schedule(void)
{
	GPUART_CHECK_RETURN( gpuS_schedule() );
}
