#include <stdlib.h>
#include <stdio.h>
#include <iomanip>
#include <memory.h>
#include <fstream>
#include <iostream>
#include <cstring>
#include "device_launch_parameters.h"  //ͬ�������Ĳ����߲�������
#include "device_functions.h"
#include "dirent.h" 
#include <cmath>
#include <time.h> 
#include "Timer.h" 
#include "cublas_v2.h"
#include<cuda_runtime.h>
#include "cusparse.h"

#define CLEANUP(s)   printf ("%s\n", s)   //cusparse�ģ�ÿ�����֮��Ҫfree�����������еı�������������ٿ���                           
#define CUBLAS_ERROR_CHECK(sdata) if(CUBLAS_STATUS_SUCCESS!=sdata){printf("ERROR at:%s:%d\n",__FILE__,__LINE__);}//exit(-1);}  
#pragma comment(lib,"cublas.lib")
#pragma comment(lib,"cusparse.lib")

 using namespace std;


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

__global__ void init_AD(long N, float *AD)
{
	int tid = blockDim.x*blockIdx.x+threadIdx.x;  //����һά�ģ�
	for (int i = tid; i<N; i+=blockDim.x*gridDim.x) 
		AD[i] = i;
}
 //�������
__global__ void vvplus (long N, float *result, float *v0, double alpha, float *v1, double beta)    //���������ӷ�
 {
	 const int blockid   = blockIdx.x;
	 const int threadid  = threadIdx.x;
	 int offset;  	 
	 for(offset=threadid+blockid*threadnum; offset<N; offset+=threadnum*gridDim.x)
		 result[offset]=(alpha*v0[offset]+beta*v1[offset]);
 }
/**********�������ܣ���Գơ�ϡ�����������������Ķȣ��������ηֱ�Ϊ��ƫ�ơ��кš�Ԫ��ֵ��Ntemp*Ntemp*********************/
      
 double Lead_Vector_GPU(int *R, int *C, float *V, long Ntemp,double *v)  //beta�����ò��ÿ��� ��beta��d_u0,d_uu��ϵ���ˣ���
{
	
	//��������
    cudaError_t cudaStat1,cudaStat2,cudaStat3,cudaStat4,cudaStat5,cudaStat6,cudaStat7;
	//int* d_AD_init;
	long M=R[Ntemp]/2.0;//	Ntemp�Ǿ�������У�M��ϡ���ĸ�����һ�룡��
	int* d_r; 
    int* d_c;
	float* d_v;
	float* d_u;
	float* d_u0;
	float * d_vector;
	float* y;  
	
	long long i = 0, j = 0;

	cusparseStatus_t status;
	cusparseHandle_t cushandle;
	cusparseMatDescr_t descrA=0;
	const float alpha_mv= 1.0;
	const float beta_mv= 0.0;

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


	float err1 = 1, err2 = 1;
	int ITER = 0;
	float vNorm = 0;
	float temp2= -1;
	float temp1=0;

 //   double v_k;
	//��һ��  ����ռ䣻��ʼ��d_u���൱�ڵ�����ʽ�е�x[k]�����������R,C����GPU��
	cudaStat1= cudaMalloc( (void**) &d_v, sizeof(float) * (2*M));
	cudaStat2= cudaMalloc( (void**) &d_r, sizeof(int) * (Ntemp + 1));
	cudaStat3= cudaMalloc( (void**) &d_c, sizeof(int) *(2*M));
	cudaStat4= cudaMalloc( (void**) &d_u, sizeof(float) * Ntemp);
	cudaStat5= cudaMalloc( (void**) &d_u0, sizeof(float) * Ntemp);
	cudaStat6= cudaMalloc( (void**) &y, sizeof(float) * Ntemp);	
	cudaStat7= cudaMalloc( (void**) &d_vector, sizeof(float) * Ntemp);
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
	//�ڶ�������Ԫ��ֵ����gpu;
	
		cudaStat1 = cudaMemcpy(d_v, V, 
                           (size_t)(2*M*sizeof(d_v[0])), 
                           cudaMemcpyHostToDevice);
	if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Host to Device failed");
    }
	
	                                         //wocao�����ֵ�����ˣ�������        //soga!��ǰ��һ�£��������������õ��Ƕ�����
	//��������ѭ��;<1>Y(k) = X(k)/�U X(k)�U��;<2>X(k+1) = AY(k) k=0,1,2,��;<3>�жϣ���k��ִ�ʱ���򵱨U X(k)- X(k+1)�U <��ʱ������ѭ��;<4>�����Y(k)��V1,max |Xj(k)| �� ��1 ,1��j��nΪx(k)�ĵ�j������
	while (err1 > Epsilon &&  err2 > Epsilon && ITER < MAX_ITER)
	{	  		
          //3.1�Ȱ�d_u����d_u0
		  cublasScopy(handle, (int) Ntemp, d_u, 1 ,d_u0, 1 );
         //3.2ѭ����һ�� ��һ��	   
		  cublasSnrm2(handle, Ntemp, d_u, 1, &vNorm);            //˼�룺���ܳ������ַ�������������������������һ������ͬ�ģ�
		  temp1=1/vNorm;                                          //du����du�ķ�����Ŀ����Ϊ�˷�ֹ������ʧ�������ַ�������,��֤������2����
		  cublasSscal (handle, (int) Ntemp, &temp1, d_u, 1);   //Normalize v, v[i] = v[i]/vNorm Ŷ�������v��i���������Լ��ķ�������һ����      
	    cudaStat1= cudaMemcpy(v,d_u, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost) ;//���������յ�����ˣ�
		if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Device to Host failed");
       }
	
		  //ע����һ����ʱ�䣬�Ż�ʱ�����Ż���
		 //3.3ѭ���ڶ��� �����������
		  status= cusparseScsrmv(cushandle,  transA,  Ntemp,  Ntemp,  2*M, 

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
	    cublasSnrm2(handle, Ntemp, d_vector, 1, &err1);   //xk-x��k-1���ķ���
		vvplus<<<blocknum, threadnum>>>((long) Ntemp, d_vector, d_u, 1.0, d_u0, 1.0);
		cublasSnrm2(handle, Ntemp, d_vector, 1, &err2);   //xk+x��k-1���ķ���                    //��Щ��������������Ҫ�Ĳο������ǰٶȰٿ�
				 
		ITER++;
	}	 
	cout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t'<<"eigenvalue:\t"<<vNorm<<'\t';
//	fout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t';
	
	//���Ĳ�:�ͷ��ڴ棬�������ֵ
	cublasDestroy(handle);
	cudaFree(y);
	cudaFree(d_r);
	cudaFree(d_c);
	cudaFree(d_u);
	cudaFree(d_vector);
	cudaFree(d_v);
	cusparseDestroyMatDescr(descrA);
    cusparseDestroy(cushandle);
//	double *v = new double [Ntemp];
	double *v0 = new double [Ntemp];
//	checkCudaErrors( cudaMemcpy( v, d_u, sizeof(double) * Ntemp , cudaMemcpyDeviceToHost) ); 
	cudaStat1= cudaMemcpy(v0,d_u0, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost) ;
	if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Device to Host failed");
    }
	return vNorm ; 
	

} 
int main(int argc, char * argv[]){

	//step 1��file in
	 DIR *dp;
	struct dirent *dirp;
	if (NULL == (dp = opendir(argv[1])))
	{
		printf("can't open %s", argv[1]);
		exit (1);
	}
	int FileNumber = 0;
	string filenametmp;
	while((dirp = readdir(dp)) != NULL)
	{
		filenametmp = string(dirp->d_name);
		
		if (filenametmp.find_last_of('.') == -1)
			continue;
		if(filenametmp.length()>4 && filenametmp.substr(filenametmp.find_last_of('.'),4).compare(".csr") == 0 && filenametmp.size() - filenametmp.find_last_of('.') - 1 == 3)
		{
			FileNumber++;
		}
	}
	cout<<FileNumber<<" files to be processed."<<endl;

	closedir(dp);
	string *filename = new string[FileNumber];
	dp = opendir(argv[1]);
	int i = 0;
	while((dirp = readdir(dp)) != NULL)
	{
		filenametmp = string(dirp->d_name);
		if (filenametmp.find_last_of('.') == -1)
			continue;
		if(filenametmp.length()>4 && filenametmp.substr(filenametmp.find_last_of('.'),4).compare(".csr") == 0 && filenametmp.size() - filenametmp.find_last_of('.') - 1 == 3)
		{
			filename[i++] = filenametmp;
		}
	}

	string isolated_v_file = string(argv[1]).append("\\").append("isolated_v_mark.txt");
	ofstream iso_file;
	iso_file.open(isolated_v_file.c_str(), ios::out);

	for (int i = 0; i < FileNumber; i++)
	{
		string a = string(argv[1]).append("\\").append(filename[i]);
		cout<<"\ncalculating eigenvalue centrality for "<<a.c_str()<<" ..."<<endl;
		ifstream fin(a.c_str(), ios_base::binary);
		if (!fin.good())
		{	cout<<"Can't open\t"<<a.c_str()<<endl;	return 0;}

		// Read x.csr
		int Rlength = 0, Clength = 0, Clength1=0;
		fin.read((char*)&Rlength, sizeof(int));
		int * R = new int [Rlength];
		fin.read((char*)R, sizeof(int) * Rlength);
		fin.read((char*)&Clength, sizeof(int));
		int * C = new int [Clength];
		fin.read((char*)C, sizeof(int) * Clength);
		fin.read((char*)&Clength1, sizeof(int));
		float * V = new float [Clength];
		fin.read((char*)V, sizeof(float) * Clength);
		fin.close();
		int N = Rlength - 1;
		//step 2��use leading_vector function
		double *v = new double [N];
		//float *V=NULL;
	    Setup(0);
		Start(0);
		float  x=Lead_Vector_GPU(R, C, V, N,v);
		Stop(0);
		cout<<"calculate time: "<<GetElapsedTime(0)<<" s."<<endl;
		//step 3��file out
	   // Parse file name
		string X_cp = a.substr(0, a.find_last_of('.') + 1).append("ec");
		string X_cp_mas = a.substr(0, a.find_last_of('.')).append("_ec.txt");
		cout<<"Save eigenvector centrality for each node as "<<X_cp.c_str()<<endl;
		ofstream fout;
		fout.open(X_cp.c_str(), ios::binary|ios::out);
		fout.write((char*)&N, sizeof(int));
		fout.write((char*)v, sizeof(double) * N);
		fout.write((char*)&x, sizeof(float));
		fout.close();
		FILE *fp=fopen(X_cp_mas.c_str(),"w");
		fprintf(fp,"the eigenvector centrality for each node is \n");
		for(long w=0;w<N;w++)
		{
			fprintf(fp,"%.15lg\n",v[w]);
		}
		fclose(fp);

}
}