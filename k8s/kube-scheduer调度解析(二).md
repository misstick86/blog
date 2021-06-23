这一部分主要根据源码走一下**kube-scheduer**的整个调度过程.

**Kube-scheduer** 所做的事情就是为一个pod选择一个合适的Node,然后将pod调度到这个Node运行. 仔细想想,什么是一个合适的Node呢？ 或者说如果我们认为总有用不完的Node,每次调度总有一个`新机器` Node使用, 那么**kube-scheduer**这个组件可以完全不需要,在pod调度的时候我们只需一下伪代码:

```go
func bind(pod, new_node){
  pod.spec.nodeName = new_node.name
}
```

从某个角度来说,我们让一个Node运行更多的pod而且能够保证机器不出现严重的负载情况便是一个好的调度程序,当然,实际调度时还需要考虑很多因素,如pod和pod的亲和性, pod和Node的亲和性等等. 我们一个看看官方的**kube-scheduler**如何实现的.

## 调度器架构

代码定义: [https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L62](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L62)

代码中定义了一下数据结构:

**SchedulerCache internalcache.Cache**

保存集群中的状态信息,

**Algorithm core.ScheduleAlgorith**

调度算法

**NextPod func() *framework.QueuedPodInfo**

从pod的优先级队列中获取一个调度的pod

**StopEverything <-chan struct{}**

关闭调度队列的型号

**SchedulingQueue internalqueue.SchedulingQueue**

调度队列,存储所有待调度的pod

**Profiles profile.Map**

保存所有的默认plugin

**client clientset.Interface** 

和api-server交互的客户端.

和其他组件一样,**kube-scheduler** 使用 ```cobra``` 这个命令行库, 程序的最开始入口为**runCommand**函数. 

[https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/server.go#L120](https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/server.go#L120)

从代码可以看出主要执行了两个函数.  **Setup** 和 **Run**, 我们深入这两个函数.

## Setup 函数

**Setup** 主要是基于命令行参数创建一个`completed config`  和一个 `scheduler`. 

[https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/server.go#L304](https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/server.go#L304)

```go
	c, err := opts.Config()
	if err != nil {
		return nil, nil, err
	}
```

此部分是设置一个调度器的配置对象.  比如根据**config** 创建一个`clientset`客户端 , 准备事件管理器将调度产出的事件上报给**api-server**; 如果启用领导者选举功能还要初始化一些领导者注册的配置.   最后返回的就是一个scheduler config的对象.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/options/options.go#L254](https://github.com/kubernetes/kubernetes/blob/release-1.21/cmd/kube-scheduler/app/options/options.go#L254)

```go
schedulerCache := internalcache.New(30*time.Second, stopEverything)
```

