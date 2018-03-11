#include <stdlib.h>
#include <stdio.h>
#include <iomanip>
#include <memory.h>
#include <fstream>
#include <iostream>
#include <cstring>
#include "dirent.h" 
#include "device_launch_parameters.h"  //ͬ�������Ĳ����߲�������
#include "device_functions.h"
#include "modularity_GPU.cuh"
#include <cmath>
#include <time.h> 
#include "cublas_v2.h"
#include "cusparse.h"
#define CLEANUP(s)   printf ("%s\n", s)   //cusparse�ģ�ÿ�����֮��Ҫfree�����������еı�������������ٿ���                           
#define CUBLAS_ERROR_CHECK(sdata) if(CUBLAS_STATUS_SUCCESS!=sdata){printf("ERROR at:%s:%d\n",__FILE__,__LINE__);}//exit(-1);}  
#pragma comment(lib,"cublas.lib")
#pragma comment(lib,"cusparse.lib")

const int MAX_ITER=10000 ;			// The maximum iteration times in the power method
const int ITERNUMBER=500;
const double BETA_Adjust = 0;		// An optional parameter for quicker convergence. Its effect is uncertain
const double Epsilon = 0.000001;	// If |x - x0| < Epsilon, quit iteraion 
const double LAMBDA = 0.01;		// if labmda > LAMBDA, initiate the division
const int MIN_GROUP = 1;

const int threadnumx = 16;
const int threadnumy = 16;
const int  threadnum = 256;
const int blocknum    = 48;
extern ofstream fout;

__global__ void init_AD(long N, double *AD)
{
	int tid = blockDim.x*blockIdx.x+threadIdx.x;  //����һά�ģ�
	for (int i = tid; i<N; i+=blockDim.x*gridDim.x) 
		AD[i] = i;
}
__global__ void init_unweightednet(long nnz, double *V)
{
	int tid = blockDim.x*blockIdx.x+threadIdx.x;  
	for (int i = tid; i<nnz; i+=blockDim.x*gridDim.x) 
		V[i] = 1;
}
 //�������
 __global__ void vvplus (long N, double *result, double *v0, double alpha, double *v1, double beta)    //���������ӷ�
 {
	 const int blockid   = blockIdx.x;
	 const int threadid  = threadIdx.x;
	 int offset;  	 
	 for(offset=threadid+blockid*threadnum; offset<N; offset+=threadnum*gridDim.x)
		 result[offset]=(alpha*v0[offset]+beta*v1[offset]);
 }
/**********�������ܣ���Գơ�ϡ�����������������Ķȣ��������ηֱ�Ϊ��ƫ�ơ��кš�Ԫ��ֵ��Ntemp*Ntemp*********************/
      
double Lead_Vector_GPU(int *R, int *C, int *V, long Ntemp,double *v)  //beta�����ò��ÿ��� ��beta��d_u0,d_uu��ϵ���ˣ���
{
	
	//��������
    cudaError_t cudaStat1,cudaStat2,cudaStat3,cudaStat4,cudaStat5,cudaStat6,cudaStat7;
	//int* d_AD_init;
	long M=R[Ntemp]/2;//	Ntemp�Ǿ�������У�M��ϡ���ĸ�����һ�룡��
	int* d_r; 
    int* d_c;
	double* d_v;
	double* d_u;
	double* d_u0;
	double * d_vector;
	double* y;  
	
	long long i = 0, j = 0;

	cusparseStatus_t status;
	cusparseHandle_t cushandle;
	cusparseMatDescr_t descrA=0;
	const double alpha_mv= 1.0;
	const double beta_mv= 0.0;

	//cublas��һЩ������ʼ��
	cudaError_t cudaStat;
	cublasStatus_t stat;
	cublasHandle_t handle;
	
	stat = cublasCreate(&handle) ;
	//cusparse��һЩ������ʼ���������Ӣ��ע���������й��е�
	//initialize cusparse library 
	status= cusparseCreate(&cushandle); 
	if (status != CUSPARSE_STATUS_SUCCESS) 
	{  printf("CUSPARSE Library initialization failed");
	   cusparseDestroy(cushandle); 
	} 
	//create and setup matrix descriptor 
	status= cusparseCreateMatDescr(&descrA); 
	if (status != CUSPARSE_STATUS_SUCCESS) 
	{  printf("Matrix descriptor initialization failed"); 
	   cusparseDestroyMatDescr(descrA);
	   return 1;                   
	} 
	cusparseSetMatType(descrA,CUSPARSE_MATRIX_TYPE_GENERAL); 
	cusparseSetMatIndexBase(descrA,CUSPARSE_INDEX_BASE_ZERO); 
	// another parameters 
	cusparseOperation_t transA= CUSPARSE_OPERATION_NON_TRANSPOSE;


	double err1 = 1, err2 = 1;
	int ITER = 0;
	double vNorm = 0;
	double temp2= -1;
	double temp1=0;

    double v_k;
	//��һ��  ����ռ䣻��ʼ��d_u���൱�ڵ�����ʽ�е�x[k]�����������R,C����GPU��
	cudaStat1= cudaMalloc( (void**) &d_v, sizeof(double) * (2*M));
	cudaStat2= cudaMalloc( (void**) &d_r, sizeof(int) * (Ntemp + 1));
	cudaStat3= cudaMalloc( (void**) &d_c, sizeof(int) *(2*M));
	cudaStat4= cudaMalloc( (void**) &d_u, sizeof(double) * Ntemp);
	cudaStat5= cudaMalloc( (void**) &d_u0, sizeof(double) * Ntemp);
	cudaStat6= cudaMalloc( (void**) &y, sizeof(double) * Ntemp);	
	cudaStat7= cudaMalloc( (void**) &d_vector, sizeof(double) * Ntemp);
	if( (cudaStat1 != cudaSuccess)||
			(cudaStat2 != cudaSuccess)||
			(cudaStat3 != cudaSuccess)||
			(cudaStat4 != cudaSuccess)||
			(cudaStat5 != cudaSuccess)||
			(cudaStat6 != cudaSuccess)||
			(cudaStat7 != cudaSuccess))
	{
	 CLEANUP(" Device malloc failed");
	}	
    init_AD<<<blocknum,threadnum>>>(Ntemp, d_u);
	cudaStat1 = cudaMemcpy(d_r, R, 
                           (size_t)((Ntemp+1)*sizeof(d_r[0])), 
                           cudaMemcpyHostToDevice);
    cudaStat2 = cudaMemcpy(d_c, C, 
                           (size_t)(2*M*sizeof(d_c[0])), 
						    cudaMemcpyHostToDevice);
	if ((cudaStat1 != cudaSuccess) ||
        (cudaStat2 != cudaSuccess) 
        ) {
        CLEANUP("Memcpy from Host to Device failed");
        return 1;
    }
	//�ڶ������ж��Ƿ�Ϊ��Ȩ���磬���ǣ���Ԫ��ֵ����gpu�������ǣ���gpuֱ������Ԫ��ֵ
	if(*V==NULL)  //����Ȩ ��ʼ��Ϊ1
	{
	init_unweightednet<<<blocknum,threadnum>>>(2*M, d_v);
	}
	else   //��Ȩ ����ȥ
	{
		cudaStat1 = cudaMemcpy(d_v, V, 
                           (size_t)(2*M*sizeof(d_v[0])), 
                           cudaMemcpyHostToDevice);
	if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Host to Device failed");
    }
	}
	                                         //wocao�����ֵ�����ˣ�������        //soga!�ѵ���ǰ��һ�£���������
	//��������ѭ��;<1>Y(k) = X(k)/�U X(k)�U��;<2>X(k+1) = AY(k) k=0,1,2,��;<3>�жϣ���k��ִ�ʱ���򵱨U X(k)- X(k+1)�U <��ʱ������ѭ��;<4>�����Y(k)��V1,max |Xj(k)| �� ��1 ,1��j��nΪx(k)�ĵ�j������
	while (err1 > Epsilon &&  err2 > Epsilon && ITER < MAX_ITER)
	{	  		
          //3.1�Ȱ�d_u����d_u0
		  cublasDcopy(handle, (int) Ntemp, d_u, 1 ,d_u0, 1 );
         //3.2ѭ����һ�� ��һ��	   
		  cublasDnrm2(handle, Ntemp, d_u, 1, &vNorm);            //˼�룺���ܳ������ַ�������������������������һ������ͬ�ģ�
		  temp1=1/vNorm;                                          //du����du�ķ�����Ŀ����Ϊ�˷�ֹ������ʧ�������ַ�������,��֤������2����
		  cublasDscal (handle, (int) Ntemp, &temp1, d_u, 1);   //Normalize v, v[i] = v[i]/vNorm Ŷ�������v��i���������Լ��ķ�������һ����      
	     checkCudaErrors( cudaMemcpy(v,d_u, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost) );
		  //ע����һ����ʱ�䣬�Ż�ʱ�����Ż���
		 //3.3ѭ���ڶ��� �����������
		  status= cusparseDcsrmv(cushandle,  transA,  Ntemp,  Ntemp,  2*M, 

		&alpha_mv,  descrA,  d_v,  d_r,      //��Ϊ���d_vҪ�����double ����ǰ�涼�øĳ�double��
		d_c,  d_u,  &beta_mv,  y);
	if (status != CUSPARSE_STATUS_SUCCESS) 
	{ 
		CLEANUP("Matrix-vector multiplication failed");
		//	return 1; 
	} 
	cudaStat1 = cudaMemcpy(d_u, y, 
		(size_t)(Ntemp*sizeof(d_v[0])), 
                           cudaMemcpyDeviceToDevice);
	if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Device to Device failed");
    }
       //3.4 �ж�
		vvplus<<<blocknum, threadnum>>>((long) Ntemp, d_vector, d_u, 1.0, d_u0, -1.0);
	    cublasDnrm2(handle, Ntemp, d_vector, 1, &err1);   //xk-x��k-1���ķ���
		vvplus<<<blocknum, threadnum>>>((long) Ntemp, d_vector, d_u, 1.0, d_u0, 1.0);
		cublasDnrm2(handle, Ntemp, d_vector, 1, &err2);   //xk+x��k-1���ķ���                    //��Щ��������������Ҫ�Ĳο������ǰٶȰٿ�
				 
		ITER++;
	}	 
	cout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t';
	fout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t';
	
	//���Ĳ�:�ͷ��ڴ棬�������ֵ
	cublasDestroy(handle);
	cudaFree(y);
	cusparseDestroyMatDescr(descrA);
    cusparseDestroy(cushandle);
//	double *v = new double [Ntemp];
	double *v0 = new double [Ntemp];
//	checkCudaErrors( cudaMemcpy( v, d_u, sizeof(double) * Ntemp , cudaMemcpyDeviceToHost) ); 
	checkCudaErrors( cudaMemcpy(v0,d_u0, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost) );
/*		long long max_index = 0;
	for (i = 0; i < Ntemp; i++)
		if (fabs(v0[i]) > fabs(v0[max_index]))
			max_index = i;  */
	return vNorm ;   //what ??????????
	//return v0[max_index];
//	for (i = 0; i < Ntemp; i++)
//		v[i]/=v[max_index];
}
void main(){
	  /* create the following sparse test matrix in CSR format */
    /* |0.0     1.0 1.0|
       |    0.0 1.0    |
       |1.0 1.0 0.0 1.0|
       |1.0     1.0 0.0| */
	int C[10]={2,3,2,0,1,3,0,2};
	int R[5]={0,2,3,6,8};
	float x;
	double *v = new double [4];
	int V=NULL;
	x=Lead_Vector_GPU(R, C, &V, 4,v);
	 for(int i=0;i<4;i++)   {   
		 printf("\n%f\n",v[i]);
	 }
	 printf("eigenvalue is %f\n",x);
}
