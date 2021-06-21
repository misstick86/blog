## 什么是indexer

Kubernetes中提供了两个存储接口, 一个是比较底层的store接口，一个是在其基础上继承的indexer接口. 不过他们底层都依赖于一个**ThreadSafeMap**对象实现. 所以,我们先来看一下这个结构.



#### 线程安全的map(ThreadSafeMap)

**threadSafeMap**是一个底层的存储, 其定义如下:

```go
type threadSafeMap struct {
	lock  sync.RWMutex
	items map[string]interface{}

	// indexers maps a name to an IndexFunc
	indexers Indexers
	// indices maps a name to an Index
	indices Indices
}
```



如何保证是一个线程安全的map呢？ 主要是在每次对map的操作时候都会加锁，以保证数据的一致性. 并且**threadSafeMap**并不会写入磁盘,是一个基于内存的存储.

**items**是存储数据的结构, 其中key是通过**Keyfunc**函数计算而来的,默认是一个\<namespace\>/\<name\>格式的key.

**Indexers**和**Indices**是一个用来快速索引的数据结构, **Indexers**是关联一组索引方法,**Indices**是关联一组索引数据.



与之对应的是**ThreadSafeStore**的接口, 该接口定义了实现一个**threadSafeMap**结构所需要实现的各个方法.

###### 与map有关的方法

`Add`,  `Update` , `Delete`,  `Get`,  `List`,  `ListKeys`,  `Replace`,`Resync`

###### 与索引有关的函数

`Index`,`IndexKeys`,  `GetIndexers `, `ListIndexFuncValues`, `ByIndex`,`updateIndices`,`deleteFromIndices`



看几个比较重要的方法:

`Index`:   根据索引函数过滤符合存储在**threadSafeMap**的items

`ByIndex`:  和`Index`类似, 接收一个索引名称和一个indexKey(通过过滤函数`IndexFunc`计算而得) 过滤符合存储在**threadSafeMap**的items

`updateIndices`: 更新**indices**中的数据.



**threadSafeMap** 并不直接对外提供存储功能, 在其基础上又定义了一个结构体(**cache**). 该结构如下所示: 

```go
// `*cache` implements Indexer in terms of a ThreadSafeStore and an
// associated KeyFunc.

type cache struct {
	// cacheStorage bears the burden of thread safety for the cache
	cacheStorage ThreadSafeStore
	// keyFunc is used to make the key for objects stored in and retrieved from items, and
	// should be deterministic.
	keyFunc KeyFunc
}
```

cache根据**ThreadSafeStore**(负责线程安全并发)和**keyFunc**(负责计算obj的key)来实现一个`indexer`.



**keyFunc** 是一个计算object的**key**的函数,他返回的值的格式是\<namespace\>/\<name\>.



#### 理解一下indices和indexer这两个数据结构

 kubernetes中与存储相关的功能定义了四种类型:

```go
// IndexFunc knows how to compute the set of indexed values for an object.
type IndexFunc func(obj interface{}) ([]string, error)
// 自定义索引函数, 接收一个obj,返回一个字符串数组

// Indexers maps a name to a IndexFunc
type Indexers map[string] IndexFunc
// 将我们自定义的indexFunc函数以key-value(map)形式保存在字典中, 快速查找对应的indexFunc

---------------------------------------------------------------------

// Index maps the indexed value to a set of keys in the store that match on that value
type Index map[string]sets.String

// 官方给的注释就是: Index将映射一个key到Store匹配到的key作为value. 
// 个人理解：比如查找某个Node节点下所有的pod, 那么key就是indexFunc计算后的得到的值, value则是store中运行在这个node上所有的pod通过keyfunc计算后key.

// Indices maps a name to an Index
type Indices map[string]Index

// 存储缓存器， key为缓存器的名称(这个key一版来说和indexers的key对应),value为缓存的数据
```



上面的四个类型, **IndexFunc**和**Indexers**还是比较好理解的, 我在详细讲解一下**Index**和**Indices**. 之后我还会以一个简单的列子介绍一下indexers各个类型的具体作用.

**Index**类型的具体实现:

```go
type Index map[string]sets.String
```

在源码中定义**Index**是一个map类型的数据结构,key是一个string类型,value则是一个Set集合的数据结构。 注意: Set本质上和Slice相同,但Set中不存在相同的元素.  由于Go的标准库里面并没有提供Set类型的数据结构, 所以kubernetes使用map数据结构中的key作为Set数据结构,实现Set中没有重复数据. (因为map中的key也是唯一的)。



```go
type String map[string]Empty
```

所以, index中存储的数据如下所示:

![image-20210426235208525](/Users/xiaosongsong/Library/Application Support/typora-user-images/image-20210426235208525.png)



我们以pod资源为例, 通过自定义缓存函数实现一个查找node节点上的pod功能具体描述一下.

1. 首先,我们需要定义个**indexFun**函数, 这个接收一个pod obj 并返回这个pod运行在哪个Node上的列表,这便用到了**IndexFunc**数据结构
2. 在是实例化Indexer的时候将我们定义的函数以map形式作为参数传给Indexer. 这便是**Indexers**
3. indexers在接收到新来对的pod对象后会开始更新缓存数据, 首先, 会根据**Indices**中得到映射找到实际的**index**, **Indices**的*key*一版为**Indexers**的key, value上面定义的Index数据结构.
4. Index数据结构本身也是一个map, *key*为**indexFun**函数返回值列表中的每个item, *value*为每个pod obj通过**keyFunc**计算而来的值.



#### Store 接口

- Store是一个简单的实现存储了的接口, 要求必须实现与**ThreadSafeMap**相关的map所有方法。

- Indexer是一个索引的接口, 因为在**Indexer**在定义时继承了**Store**接口,可以看出**Indexer**是**Store**更上层的封装.

在实例化时Store和Indexer区别也是是否有对应的**indexers**.



首先,在编译阶段就强制限制了cache这个结构必须实现所有的Store接口. 

```go
var _ Store = &cache{}
```

所以我们可以在`store.go`文件中看到定义了如下的方法:

`Add`,  `Update` , `Delete`,  `Get`,  `List`,  `ListKeys`,  `Replace`,  `Index`,  `IndexKey`,  `GetIndexers `, `ListIndexFuncValues`, `ByIndex`,  `GetIndexers`



在`NewInformer`函数中，client-go创建了一个`NewStore`对象.

```go
	// This will hold the client state, as we know it.
	clientState := NewStore(DeletionHandlingMetaNamespaceKeyFunc)
```



**cache**根据`ThreadSafeStore`和相关的`KeyFunc`函数实现对应的indexer. 在实例化store时这个`KeyFunc`是`DeletionHandlingMetaNamespaceKeyFunc`.

``DeletionHandlingMetaNamespaceKeyFunc``是一个**function types**类型.



#### Indexer接口

```go
type Indexer interface {
	Store
	// Index returns the stored objects whose set of indexed values
	// intersects the set of indexed values of the given object, for
	// the named index
	Index(indexName string, obj interface{}) ([]interface{}, error)
	// IndexKeys returns the storage keys of the stored objects whose
	// set of indexed values for the named index includes the given
	// indexed value
	IndexKeys(indexName, indexedValue string) ([]string, error)
	// ListIndexFuncValues returns all the indexed values of the given index
	ListIndexFuncValues(indexName string) []string
	// ByIndex returns the stored objects whose set of indexed values
	// for the named index includes the given indexed value
	ByIndex(indexName, indexedValue string) ([]interface{}, error)
	// GetIndexer return the indexers
	GetIndexers() Indexers

	// AddIndexers adds more indexers to this store.  If you call this after you already have data
	// in the store, the results are undefined.
	AddIndexers(newIndexers Indexers) error
}
```

首先,从上面我们可以看出indexer这个接口继承了Store接口,所以,它是一个存储,只是带着一个索引，这中情况你可以理解像数据库一样。





