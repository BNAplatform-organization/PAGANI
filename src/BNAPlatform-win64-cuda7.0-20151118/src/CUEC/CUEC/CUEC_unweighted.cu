#include <stdlib.h>
#include <stdio.h>
#include <iomanip>
#include <memory.h>
#include <fstream>
#include <iostream>
#include <cstring>
#include "device_launch_parameters.h"  //同步函数的波浪线不管他了
#include "device_functions.h"
#include "dirent.h" 
#include <cmath>
#include <time.h> 
#include "Timer.h" 
#include "cublas_v2.h"
#include<cuda_runtime.h>
#include "cusparse.h"

#define CLEANUP(s)   printf ("%s\n", s)   //cusparse的！每步完成之后都要free东西，等所有的变量都定义完后再看吧                           
#define CUBLAS_ERROR_CHECK(sdata) if(CUBLAS_STATUS_SUCCESS!=sdata){printf("ERROR at:%s:%d\n",__FILE__,__LINE__);}//exit(-1);}  
//#pragma comment(lib,"cublas.lib")
//#pragma comment(lib,"cusparse.lib")

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

__global__ void init_AD(long N, double *AD)
{
	int tid = blockDim.x*blockIdx.x+threadIdx.x;  
	for (int i = tid; i<N; i+=blockDim.x*gridDim.x) 
		AD[i] = i;
}
__global__ void init_unweightednet(long nnz, double *V)
{
	int tid = blockDim.x*blockIdx.x+threadIdx.x;  
	for (int i = tid; i<nnz; i+=blockDim.x*gridDim.x) 
		V[i] = 1;
}
 //vector addition
 __global__ void vvplus (long N, double *result, double *v0, double alpha, double *v1, double beta)    
 {
	 const int blockid   = blockIdx.x;
	 const int threadid  = threadIdx.x;
	 int offset;  	 
	 for(offset=threadid+blockid*threadnum; offset<N; offset+=threadnum*gridDim.x)
		 result[offset]=(alpha*v0[offset]+beta*v1[offset]);
 }
/**********calculate eigenvector，input: CSR matrix(Row offset index, column, velue, node#),*********************/
      
 double Lead_Vector_GPU(int *R, int *C,long Ntemp,double *eigen_v)  
{
	
	cudaError_t cudaStat1,cudaStat2,cudaStat3,cudaStat4,cudaStat5,cudaStat6,cudaStat7;
	//int* d_AD_init;
	long M=R[Ntemp]/2.0; //half nnz
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

	//cublas preparation
	cudaError_t cudaStat;
	cublasStatus_t stat;
	cublasHandle_t handle;
	
	stat = cublasCreate(&handle) ;
	//cusparse preparation
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

 //   double v_k;
	//1. Initialize
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

	init_unweightednet<<<blocknum,threadnum>>>(2*M, d_v);  //binary network
	                                        
	//2. <1>Y(k) = X(k)/║ X(k)║∞; <2>X(k+1) = AY(k) k=0,1,2,…; <3> k reaches limit times or ║ X(k)- X(k+1)║ <ε, break; <4> Y(k)≈V1,max |Xj(k)| ≈ λ1,
	while (err1 > Epsilon &&  err2 > Epsilon && ITER < MAX_ITER)
	{	  		
		cublasDcopy(handle, (int) Ntemp, d_u, 1 ,d_u0, 1 );
        cublasDnrm2(handle, Ntemp, d_u, 1, &vNorm);            
		temp1=1/vNorm;                                          
		cublasDscal (handle, (int) Ntemp, &temp1, d_u, 1);   
		//cudaStat1= cudaMemcpy(v,d_u, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost); // eigenvector, further optimize
		//if (cudaStat1 != cudaSuccess){
		//	CLEANUP("Memcpy from Device to Host failed");
		//}		  
		status= cusparseDcsrmv(cushandle,  transA,  Ntemp,  Ntemp,  2*M, 
								&alpha_mv,  descrA, d_v,  d_r,      
								d_c,  d_u,  &beta_mv,  y);
		if (status != CUSPARSE_STATUS_SUCCESS){ 
			CLEANUP("Matrix-vector multiplication failed");
			//	return 1; 
		} 
		cudaStat1 = cudaMemcpy(d_u, y, (size_t)(Ntemp*sizeof(d_v[0])), cudaMemcpyDeviceToDevice);
		if (cudaStat1 != cudaSuccess){
	        CLEANUP("Memcpy from Device to Device failed");
		}
       //3.4 
		vvplus<<<blocknum, threadnum>>>((long) Ntemp, d_vector, d_u, 1.0, d_u0, -1.0);
	    cublasDnrm2(handle, Ntemp, d_vector, 1, &err1);   //║xk-x(k-1)║
		vvplus<<<blocknum, threadnum>>>((long) Ntemp, d_vector, d_u, 1.0, d_u0, 1.0);
		cublasDnrm2(handle, Ntemp, d_vector, 1, &err2);   //║xk+x(k-1)║			 
		ITER++;
	}	 
	cout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t'<<"eigenvalue:\t"<<vNorm<<'\t';
//	fout<<"Iterations:\t"<<ITER<<'\t'<<"residual:\t"<<min(err1, err2)<<'\t';
	
	//Release memory
	cublasDestroy(handle);
	cudaFree(y);
	cudaFree(d_r);
	cudaFree(d_c);
	cudaFree(d_u);
	cudaFree(d_vector);
	cudaFree(d_v);
	cusparseDestroyMatDescr(descrA);
    cusparseDestroy(cushandle);
	cudaStat1= cudaMemcpy(eigen_v, d_u0, sizeof(double) * Ntemp,  cudaMemcpyDeviceToHost) ;
	if (cudaStat1 != cudaSuccess) 
      {
        CLEANUP("Memcpy from Device to Host failed");
    }
	return vNorm ; 
} 
int main(int argc, char * argv[]){

	//step 1：file in
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

	//string isolated_v_file = string(argv[1]).append("\\").append("isolated_v_mark.txt");
	//ofstream iso_file;
	//iso_file.open(isolated_v_file.c_str(), ios::out);

	for (int i = 0; i < FileNumber; i++)
	{
		string a = string(argv[1]).append("\\").append(filename[i]);
		cout<<"\ncalculating eigenvalue centrality for "<<a.c_str()<<" ..."<<endl;
		ifstream fin(a.c_str(), ios_base::binary);
		if (!fin.good())
		{	cout<<"Can't open\t"<<a.c_str()<<endl;	return 0;}

		// Read x.csr
		int Rlength = 0, Clength = 0;
		fin.read((char*)&Rlength, sizeof(int));
		int * R = new int [Rlength];
		fin.read((char*)R, sizeof(int) * Rlength);
		fin.read((char*)&Clength, sizeof(int));
		int * C = new int [Clength];
		fin.read((char*)C, sizeof(int) * Clength);
		fin.close();
		int N = Rlength - 1;
		//step 2：use leading_vector function
		double *v = new double [N];
	    Setup(0);
		Start(0);
		float  x=Lead_Vector_GPU(R, C, N,v);
		Stop(0);
		cout<<"calculate time: "<<GetElapsedTime(0)<<" s."<<endl;
		//step 3：file out
	   // Parse file name
		string X_ec = a.substr(0, a.find_last_of('.') ).append("_ec.nm");
		string X_evalue = a.substr(0, a.find_last_of('.')).append("_evalue.txt");
		cout<<"Save eigenvector centrality for each node as "<<X_ec.c_str()<<endl;
		ofstream fout;
		fout.open(X_ec.c_str(), ios::binary|ios::out);
		fout.write((char*)&N, sizeof(int));
		float * vf = new float [N];
		for (int k = 0; k < N; k++)
		{
			vf[k] = (float) v[k];
			//cout<<v[k]<<"    "<<vf[k]<<endl;   //debug
		}
		fout.write((char*)vf, sizeof(float) * N);  //eigenvector centrality
		
		//fout.write((char*)&x, sizeof(float));           
		fout.close();
		//fout.open(X_cp_mas.c_str(),ios::trunc); //ios::trunc overwrite
		//fout<<"the eigenvector centrality for each node is "<<endl;
		
		fout.open(X_evalue.c_str(), ios::out);
		fout<<setprecision(6)<<x<<endl;
		fout.close();

}
}