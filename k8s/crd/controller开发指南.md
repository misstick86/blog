## 编写控制器

kubernetes控制器是一个主动的协调过程. 也就是说, 监控某个对象并使当前对象达到期望的状态.

一个简单的实现就如下循环:

```go
for {
  desried := getDesiredState()
  current := getCurrentState()
  makeChanges(desried, current)
}
```

## 指南

一下是你在写一个controller的指导和建议:

1. **如果使用`workqueue.Interface`,一次只操作一个元素.**  你可以更改特定资源的队列，然后将其放到多个**gofunc**的`worker`中,要保证一个**gofunc*同时处理同一个元素.

许多的controller会触发多个资源(如果Y发生改变检查X). 因此几乎所有的controller都可以根据理论将其关联到**检查x队列**. 例如, Replicatset controller 需要管理删除的pod, 它只需要关心**ReplicaSets**相关的队列.

2. **资源之间随机排序.**  当controller queue中有多重类型的资源时,不需要关系资源的顺序.

3. **水平触发,而非边缘触发.** 就像一个shell脚本不会一直运行一样, controller可以随时关闭.

4. **使用*shareInformers*.**  *shareInformers*提供一个钩子在接收到"ADD","Update","Delete"通知对于特定的资源.它还提供访问共享缓存和缓存何时就绪等功能.

使用*Factory*可以确保一个资源共享同一个缓存实例. 这减少了重复的API连接,服务端重复序列化,controller端的反序列化和controller端的重复缓存.

5. **永远不要改变原始对象**. 缓存在控制器之间共享.如果该边了它将影响其他控制.

最常见的错误是做浅copy,之后试图改变一个map,如: **Annotations**, 使用`api.Scheme.copy`来做深copy.

6. **等待二级缓存**. 许多controller都分为主资源和次资源. 主资源是你将为其更新状态的资源,次资源是你将要用于管理和查找的资源.

在开始主资源同步函数之前使用`framework.WaitForCacheSync`函数等待次资源缓存. 这可以避免使用过期的信息.

7. **系统并非只有一个controller**, 因为你没有改变一个对象并不意味着别人不会更改.

不要忘记当前状态可能随时改变--仅仅观察自己期望的状态是不够的. 如果你认为自己期望的状态是资源删除前的状态,确保你的代码没有bug.

8. **向顶层报错以保持一致性重新入队.** 使用`workqueue.RateLimitingInterface`允许合理的重新入队.

当需要重新入队时,主控制应该返回一个错误. 如果不是错误, 应该使用`utilruntime.HandlerError`处理并返回nil代替. 这边方便之后的排查错误并确信你的controller不会意外的丢失应该重试的内容.

9. **watches**和**informer**应该定期"SYNC". 集群会定期将资源同步给你的**Update**方法.  当你需要对对象做一些额外的操作时这是非常好的,但是通常不会做任何操作.

如果确定在没有更新的情况不需要重新排队, 你可以比较新老资源的版本. 如果相同可以不用入队操作. 但这样做要格外小心,如果在资源失败时没有入队, 可能之后再也不会入队了.

10. 如果你的控制器正在协调的资源状态中支持**ObserveredGeneration**. 确保设置正确的元数据. 

 让客户端知道控制器已经处理了资源. 确保你的控制是负责这个资源的主控制器, 否则,你需要通过你的控制器观察,在资源的状态中创建一个不同类型的**ObservedGeneration**

11. 考虑到对应创建者在其创建的资源中使用**owner references**.例如: 在pod中ReplicaSet的结果. 以此, 一旦你管理的控制器资源被删,你可以确保其子资源被垃圾回收.

## 大体结构

如上,一个controller应该如下:

```go
type Controller struct {
	// podLister is secondary cache of pods which is used for object lookups
	podLister cache.StoreToPodLister

	// queue is where incoming work is placed to de-dup and to allow "easy"
	// rate limited requeues on errors
	queue workqueue.RateLimitingInterface
}

func (c *Controller) Run(threadiness int, stopCh chan struct{}) {
	// don't let panics crash the process
	defer utilruntime.HandleCrash()
	// make sure the work queue is shutdown which will trigger workers to end
	defer c.queue.ShutDown()

	glog.Infof("Starting <NAME> controller")

	// wait for your secondary caches to fill before starting your work
	if !framework.WaitForCacheSync(stopCh, c.podStoreSynced) {
		return
	}

	// start up your worker threads based on threadiness.  Some controllers
	// have multiple kinds of workers
	for i := 0; i < threadiness; i++ {
		// runWorker will loop until "something bad" happens.  The .Until will
		// then rekick the worker after one second
		go wait.Until(c.runWorker, time.Second, stopCh)
	}

	// wait until we're told to stop
	<-stopCh
	glog.Infof("Shutting down <NAME> controller")
}

func (c *Controller) runWorker() {
	// hot loop until we're told to stop.  processNextWorkItem will
	// automatically wait until there's work available, so we don't worry
	// about secondary waits
	for c.processNextWorkItem() {
	}
}

// processNextWorkItem deals with one key off the queue.  It returns false
// when it's time to quit.
func (c *Controller) processNextWorkItem() bool {
	// pull the next work item from queue.  It should be a key we use to lookup
	// something in a cache
	key, quit := c.queue.Get()
	if quit {
		return false
	}
	// you always have to indicate to the queue that you've completed a piece of
	// work
	defer c.queue.Done(key)

	// do your work on the key.  This method will contains your "do stuff" logic
	err := c.syncHandler(key.(string))
	if err == nil {
		// if you had no error, tell the queue to stop tracking history for your
		// key. This will reset things like failure counts for per-item rate
		// limiting
		c.queue.Forget(key)
		return true
	}

	// there was a failure so be sure to report it.  This method allows for
	// pluggable error handling which can be used for things like
	// cluster-monitoring
	utilruntime.HandleError(fmt.Errorf("%v failed with : %v", key, err))

	// since we failed, we should requeue the item to work on later.  This
	// method will add a backoff to avoid hotlooping on particular items
	// (they're probably still not going to work right away) and overall
	// controller protection (everything I've done is broken, this controller
	// needs to calm down or it can starve other useful work) cases.
	c.queue.AddRateLimited(key)

	return true
}
```



