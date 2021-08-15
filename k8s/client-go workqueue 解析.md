![cient-go 框架图](../static/images/k8s/client-go-controller-interaction.jpeg)

以上是client-go各个组件的交互图, 今天我们要讨论的是关于**Workqueue** 这个组件如何设计和工作的.

## Workqueue的设计

**Workqueue**本质上来说还是一个队列, 入队和出对是对`队列`的基本使用. **Workqueue**的实现上有多层,分别在不同层上有着不同的功能. 我们先来看看基础的数据结构 **FIFO**队列.

#### FIFO 队列

定义在如下文件: [https://github.com/kubernetes/client-go/blob/master/util/workqueue/queue.go](https://github.com/kubernetes/client-go/blob/master/util/workqueue/queue.go)

**Interaface**接口定义了实现一个队列结构改支持的方法;分别如下:

- **Add**:   给队列添加元素
- **Len**:   获取队列的长度
- **Get**:    获取队列头部的第一个元素
- **Done**:  标记队列中的元素已被处理
- **Shutdonw**: 关闭队列
- **Shutingdown**:  查看队列是否正在关闭

实现该接口的结构体叫做**Type**,它的定义如下:

```go
type Type struct {
  
  // queue 是一个有序的队列, queue中的元素应该在dirty集合中而不是在processing结合.
	queue []t

  // dirty 是所有需要被处理的元素集合. 主要用于去重,保证元素只处理一次.
	dirty set

  // processing 当前正在被处理的元素集合. 它们同时也可能在 dirty 集合里. 元素被处理完成后会从集合中删除, 如果元素还在 dirty 集合中将会重新添加到 queue 队列里。
	processing set

	cond *sync.Cond

	shuttingDown bool

	metrics queueMetrics

	unfinishedWorkUpdatePeriod time.Duration
	clock                      clock.Clock
}
```

**FIFO**队列是一个最简单的数据结构,在此基础上又实现了一个延迟队列.

#### 延迟队列

定义的文件如下: [https://github.com/kubernetes/client-go/blob/master/util/workqueue/delaying_queue.go](https://github.com/kubernetes/client-go/blob/master/util/workqueue/delaying_queue.go)

延迟队列在其接口上新增了一个**AddAfter** 方法,其原理是每个插入的元素都带有一个延迟时间, 在插入数据是根据延迟时间再将元素添加到FIFO队列中.

延迟队列的数据结构和FIFO的数据结构一个最大差异的字段是**waitingForAddCh**;他是一个缓存的通道(channel). 在实例化时默认初始值为1000, 通过AddAfter函数向队列里面插入元素时, 如果延迟时间小于等于0,会被立即插入队列中,  否则就会进入这个延迟通道. 

```go
	// immediately add things with no delay
	if duration <= 0 {
		q.Add(item)
		return
	}

	select {
	case <-q.stopCh:
		// unblock if ShutDown() is called
	case q.waitingForAddCh <- &waitFor{data: item, readyAt: q.clock.Now().Add(duration)}:
	}
```

这个**waitingForAddCh**通道还有一个**waitingLoop**一直在监听消费, 这里面又用到了一个优先级队列.  从通道里面取出来的数据如果时间到了就立即插入到FIFO队列中, 否者就会写入到这个优先级队列. 优先级队列中的数据也会被遍历择时写入FIFO队列中.

#### 限速队列

定义的文件如下: [https://github.com/kubernetes/client-go/blob/master/util/workqueue/rate_limiting_queue.go](https://github.com/kubernetes/client-go/blob/master/util/workqueue/rate_limiting_queue.go)

限速队列利用了延迟队列的特性实现的,从接口的定义来看,它继承了延迟队列,并在原有的功能基础上增加了**AddRateLimited**, **Forget**,**NumRequeues**方法. 其原理是通过延迟某个队列的添加时间已达到限速的目的.

限速队列的主要实现在于它提供的四种限速算法接口. 其定义在如下文件:  [https://github.com/kubernetes/client-go/blob/master/util/workqueue/default_rate_limiters.go](https://github.com/kubernetes/client-go/blob/master/util/workqueue/default_rate_limiters.go)

限速接口的定义如下:

```go
type RateLimiter interface {
	// 获取指定元素应该等待的时间
	When(item interface{}) time.Duration
	// 释放某个元素,清空排队数
	Forget(item interface{})
	// 获取指定的排队数
	NumRequeues(item interface{}) int
}

```

在次接口之上,client-go定义了四种限速算法:

-  **BucketRateLimiter** 令牌桶算法
- **ItemExponentialFailureRateLimiter** 排队指数算法
- **ItemFastSlowRateLimiter** 计数器算法
- **NewMaxOfRateLimiter** 混合模式

## WorkQueue的使用

**Client-go**的源码示例里有一个关于**Workqueue**的简单使用, 这里简单的说明一下.

#### 生产者

在**Informer**的文章讲解过,实例化一个Informer需要为这个Informer添加对应的资源处理函数.  资源处理的方式就是在触发对应的 **ADD** , **UPDATE** , **DELETE** 方法时回调对应的函数, 这里我可以直接在回调函数里面处理,也可以将资源对象添加到队列中后续从队列里面取出来处理.

```go
	indexer, informer := cache.NewIndexerInformer(podListWatcher, &v1.Pod{}, 0, cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			key, err := cache.MetaNamespaceKeyFunc(obj)
			if err == nil {
        // 这里便是入队操作
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
	}, cache.Indexers{})
```

#### 消费者

在编写自己的controller示例中, **processNextWorkItem**用于处理一个资源对象并返回这个对象是否处理成功.  其中如下代码便是从队列中获取数据:

```go
key, quit := c.queue.Get()
```

队列中定于的存储数据可以是任何类型, 这里我们通过入队的是资源的key, 例如: default/nginx-deploy, 后续在从Indexer中获取对应的资源.   这一步分别对应于土中的**process Item**, **Handle object**, **Indexer Reference**.

