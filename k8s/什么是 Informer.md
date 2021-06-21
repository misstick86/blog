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

Share informer采用工厂模式创建对应的informer对象, share inform主要解决太多的informer同时ListWatch时会导致APi Server的压力变大. 对于不同的资源我们使用不同的informer, 同一种资源我们就使用单例模式来解决这个问题.

Share informer是在官方提供的simple-controller示例中引用的.

```go
kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, time.Second*30)
deploymentInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: controller.handleObject,
		UpdateFunc: func(old, new interface{}) {
			newDepl := new.(*appsv1.Deployment)
			oldDepl := old.(*appsv1.Deployment)
			if newDepl.ResourceVersion == oldDepl.ResourceVersion {
				// Periodic resync will send update events for all known Deployments.
				// Two different versions of the same Deployment will always have different RVs.
				return
			}
			controller.handleObject(new)
		},
		DeleteFunc: controller.handleObject,
	})
```



Share informer在创建对应的Factory时采用了funtional option的模式, 可以参考耗子叔的这篇文章:[GO 编程模式：FUNCTIONAL OPTIONS](https://coolshell.cn/articles/21146.html)

我们来看看这个工厂是如何构造的。

```go
// NewSharedInformerFactoryWithOptions constructs a new instance of a SharedInformerFactory with additional options.
func NewSharedInformerFactoryWithOptions(client kubernetes.Interface, defaultResync time.Duration, options ...SharedInformerOption) SharedInformerFactory {
	factory := &sharedInformerFactory{
		client:           client,
		namespace:        v1.NamespaceAll,
		defaultResync:    defaultResync,
		informers:        make(map[reflect.Type]cache.SharedIndexInformer),
		startedInformers: make(map[reflect.Type]bool),
		customResync:     make(map[reflect.Type]time.Duration),
	}

	// Apply all options
	for _, opt := range options {
		factory = opt(factory)
	}

	return factory
}
```



