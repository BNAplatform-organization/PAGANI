#ifndef  _HASH_SET_H_
#define  _HASH_SET_H_ 
#include <stdlib.h>
#include <string>
#include <iostream>
#include <vector>
using namespace std;

const _ULonglong a = 11400714819323198485;

//enum Status//����״̬������
//{
//    EMPTY,
//	EXIST,        
//};

//template<class K, class V>
//struct KeyValue//�ֵ�
//{
//	    K _key;
//		V _value;
//		KeyValue(const K& key = K(), const V& value = V())
//		//����K()��V()Ϊ���޲γ�ʼ��
//	    :_key(key), _value(value) {}
//};

//static size_t BKDRHash(const char * str)//�ַ�����ϣ�㷨
//{
//    unsigned int seed = 131; // 31 131 1313 13131 131313
//    unsigned int hash = 0;
//    while (*str)
//    {
//        hash = hash * seed + (unsigned int)(*str++);
//    }
//    return (hash & 0x7FFFFFFF);
//}

_ULonglong GetKey(_ULonglong v1, _ULonglong v2)
{
	return v1<v2 ? ((v1<<32) | v2) : ((v2<<32) | v1);
}

static size_t FibonacciHash(const _ULonglong & x)
{
	return a*x;
}

//Ĭ�Ϲ�ϣ����ʵ��
template<class K>
struct DefaultHashFuncer//��������
{
    size_t operator()(const K& key)
    {
        return key;
    }
};

template<>
struct DefaultHashFuncer<_ULonglong>      //string����--ģ����ػ�
{
    size_t operator()(const _ULonglong & x)
    {
        return FibonacciHash(x);
    }
};



template<class K, class HashFuncer = DefaultHashFuncer<K>>
class HashSet
{
    protected:
        size_t _size;//��ϣ���й�ϣ���ĸ���
       	size_t _capacity;//��ϣ��Ĵ�С
		K* _table;//��Ź�ϣ��
        //Status* _status;//���״̬������
    
	public://���и�������ʵ��--������ɾ���
		HashSet():_table(NULL), _size(0), _capacity(0), total_count(0),find_cnt(0) {}
		HashSet(size_t size, double loadfactor_inv = 2.0): 
			_size(0), 
			_capacity((size_t)(loadfactor_inv*size)),
			_table(new K[_capacity]),
			total_count(0),
			find_cnt(0)
		{
			memset(_table, 0, sizeof(K)*_capacity);
		}
		
		~HashSet()
		{
		    if (_table)
		    {
		        delete[] _table;
		        //delete[] _status;
		        _size = 0;
		        _capacity = 0;
		    }
		}
		
		size_t HashFunc(const K& key)             //���key�ڹ�ϣ���е�λ��
		{
    		HashFuncer hp;
    		return hp(key)%_capacity;//hp(key)���÷º���
		}
		
		/*size_t HashFunc0(const K& key)
		{
    			return HashFunc(key);//����HashFunc�������ҵ�����̽�������λ��
		}		
		
		size_t HashFunci(size_t index, size_t i)
		{
    			return index + (2 * i - 1);//�Ż�����㷨
		}*/
		
		size_t Find(const K& key)
		{
			//size_t cnt = 0;
			find_cnt++;
			size_t index = HashFunc(key);
			while (_table[index] != 0)
			{
        		if ( _table[index] == key )
        		{
            		return index;
        		}
				++index;
				total_count++;
				if (index == _capacity)//�����ϣ�����������һλ���ͷ��ص���һλ���й�ϣ
    			{
    			    index = 0;
    			}
			}
			return _capacity;
		}		
		
		bool exist(const K& key){
			return (Find(key) != _capacity);
		}

		bool Insert(const K& key) //��ֹ������bool
		{
    		//CheckCapacity(_size + 1);//�����������������
			//����̽��
			find_cnt++;
			size_t index = HashFunc(key);
			while (_table[index] != 0 && _table[index] != _ULLONG_MAX)//�����ΪEMPTY��DELETE�Ͳ����ڴ�λ�ô�����key�����ڹ�ϣ��ͻ
			{
				if (_table[index] == key)//���key�Ѵ��ڣ��Ͳ���ʧ��
    			{
    			    return false;
    			}
    			++index;
				++total_count;
    			if (index == _capacity)//�����ϣ�����������һλ���ͷ��ص���һλ���й�ϣ
    			{
    			    index = 0;
    			}
    		}
    		++_size;
    		_table[index] = key;
    		//_table[index]._value = value;
    		//_status[index] = EXIST;
    		return true;
    		//����̽��
    		//size_t i = 0;
			//size_t index = HashFunc0(key);
			//while (_status[index] == EXIST)//�����ΪEMPTY��DELETE�Ͳ����ڴ�λ�ô�����key�����ڹ�ϣ��ͻ
    		//{
        	//	if (_table[index]._key == key && _table[index]._value == value)//���key�Ѵ��ڣ��Ͳ���ʧ��
        	//	{
            //			return false;
        	//	}
        	//	index = HashFunci(index, ++i);
        	//	if (index >= _capacity)//�����ϣ����λ�ó������������һλ���ʹ���λ��ʼ�����Ӧλ��
        	//	{
            //			index = index - _capacity;
        	//	}
    		//}
    		//_table[index]._key = key;
    		//_table[index]._value = value;
    		//_status[index] = EXIST;
    		//_size++;
    		//return true;;
		}	

		bool Remove(const K& key)
		{
    			size_t pos = Find(key);
				if (pos == _capacity)//����_capacity��ʾ����ʧ��
    			{
        			return false;
    			}
				//_status[pos] = EMPTY;
				_table[pos] = _ULLONG_MAX;
				--_size;
    			return true;
		}
		
		size_t size(){
			return _size;
		}

		void GetValVector(vector<K> &vec)
		{
			//vector<K> vec;
			//vec.reserve(_size+1);
			for(size_t i = 0; i < _capacity; i++)
			{
				if(_table[i] != 0 && _table[i] != _ULLONG_MAX){
					vec.push_back(_table[i]);	
					//cout<<_table[i]._value<<endl;
				}
			}
			//return vec;
			return;
		}		

		size_t total_count;
		size_t find_cnt;

};


#endif
