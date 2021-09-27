## 什么是 Informer

**Informer**是**clinet-go**和api-server通信的核心组件,  它实现了kubernetes中事件的**可靠性**、**实时性**、**顺序性**.

informer有三大核心组件:

- Reflector: 用于Watch kuberentes系统中的资源的变化,并将事件的变更存储在本地DeltaFIFO中.
- DeltaFIFO: 一个先进先出队列, 该队列保存着每个资源变更的事件类型
- Indexer: 本地存储，用于快速检索kubernetes中的资源,减少API-Server的压力.

以上三大组件会在后续展开解释.

## basic Informer

官方给的workqueue示例上使用的是一个最基本的informer示例, 它接收如下参数进行实例化:

-  lw :  watch你想要的资源类型事件
- objType: 你希望接收的资源对象
- resyncPeriod: -
- h: 处理各个事件的回调函数

一下是一段简单的代码:

```go
	// create the pod watcher
	podListWatcher := cache.NewListWatchFromClient(clientset.CoreV1().RESTClient(), "pods", v1.NamespaceDefault, fields.Everything())

	// create the workqueue
	queue := workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter())

	// Bind the workqueue to a cache with the help of an informer. This way we make sure that
	// whenever the cache is updated, the pod key is added to the workqueue.
	// Note that when we finally process the item from the workqueue, we might see a newer version
	// of the Pod than the version which was responsible for triggering the update.
	indexer, informer := cache.NewIndexerInformer(podListWatcher, &v1.Pod{}, 0, cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			key, err := cache.MetaNamespaceKeyFunc(obj)
			if err == nil {
				queue.Add(key)
			}
		},
		UpdateFunc: func(old interface{}, new interface{}) {
			key, err := cache.MetaNamespaceKeyFunc(new)
			if err == nil {
				queue.Add(key)
			}
		},
		DeleteFunc: func(obj interface{}) {
			// IndexerInformer uses a delta queue, therefore for deletes we have to use this
			// key function.
			key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
			if err == nil {
				queue.Add(key)
			}
		},
	}, cache.Indexers{"byNode":UserIndexFunc})
```

## Share Informer

Share informer采用工厂模式创建对应的informer对象, share inform主要解决太多的informer同时ListWatch时会导致APi Server的压力变大问题. 对于不同的资源我们使用不同的informer, 同一种资源我们就使用单例模式来解决这个问题.

我们来看看这个工厂结构有哪些数据结构:

```go
type sharedInformerFactory struct {
  // 根据 kubeconnfig 实例化k8s客户端, 如: clientset
	client           kubernetes.Interface
  // 要操作的namesace
	namespace        string
  // 暂不知道
	tweakListOptions internalinterfaces.TweakListOptionsFunc
  // 实例化一把锁,用于处理抢占资源
	lock             sync.Mutex
  // 
	defaultResync    time.Duration
	customResync     map[reflect.Type]time.Duration
	// 一个MAP数据结构保存所有资源的Informer 
	informers map[reflect.Type]cache.SharedIndexInformer
	// startedInformers is used for tracking which informers have been started.
	// This allows Start() to be called multiple times safely.
  // 用于记录那些资源的informer已经开始运行了
	startedInformers map[reflect.Type]bool
}
```

对于实例化一个Factory也比较简单,  一下便是实例化一个Factory, 注意此时我们还没有构造出资源的InFormer.

```go
kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, time.Second*30)
```

Share informer在创建对应的Factory时采用了funtional option的模式, 参数`customResync`, `tweakListOptions` `namespace`都是通过此模式进行实例化的,  可以参考耗子叔的这篇文章:[GO 编程模式：FUNCTIONAL OPTIONS](https://coolshell.cn/articles/21146.html)

```go
	// Apply all options
	for _, opt := range options {
		factory = opt(factory)
	}


```

**Share Informer** 实现了kuberentes中所有已知资源的`Infomer`,这是通过链式调用的方式实现的;以Deployment资源为例, **ShareInformerFactory**实现了**APPS**这个组的接口,  而**APPS**这个组又实现了**V1**,**V1beta1**,**V1beta2**的所有版本, 而在每个版本中又实现了每个组下面的资源,如Deployment,StatefulSet 等等.  

这里我们以Deployment为例, 看看一个是如何实现该资源的Informer.

Deployment 资源的Informer上实现了一个Informer方法和一个Listen方法. 代码如下:

```go
type DeploymentInformer interface {
	Informer() cache.SharedIndexInformer
	Lister() v1beta1.DeploymentLister
}
```

**Informer()** 方法返回的是一个**SharedIndexInformer**,该结构体就是报错**Reflector**的三大组件:ListWatch、Index、DeltaFIFO. 

**Lister()** 方法返回的是**DeploymentLister**, 该接口通过Index获取对应的资源.



