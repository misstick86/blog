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

实例化调度缓存,该函数是一个*goroutine* 每隔一分钟运行一次, 

```go
registry := frameworkplugins.NewInTreeRegistry()
```

注册树内插件, 也就是**kube-scheduler** 中已经集成的插件。 可参考如下链接: [调度插件](https://kubernetes.io/zh/docs/reference/scheduling/config/#scheduling-plugins)

```go
	if err := registry.Merge(options.frameworkOutOfTreeRegistry); err != nil {
		return nil, err
	}
```

将我们自定的插件(也称树外插件)集成到对应的`registry`中.

```go
snapshot := internalcache.NewEmptySnapshot()
```

初始化一个空的`snapshot`,  `snapshot`主要保存的是当前集群中的Node信息. 

之后便是初始化调度器的配置**Configurator** , 然后在根据配置算法的来源来创建对应的策略; 最后在通过*create*方法创建**scheduler**对象.  

```go
addAllEventHandlers(sched, informerFactory)
```

**addAllEventHandlers** 就是处理和**api-server** 交互的地方, 主要做的事情有: *将pod添加到缓存中*, *将pod添加到待调度队列里*, *将Node添加到缓存中* 等等. 

以上便是实例化一个调度对应的所有流程, 下面我们看看如何运行这个调度器。

## Run 函数

**Run函数** 主要是启动一个*schuduler*调度程序,  首先要启动事件管理器, 如果配置了**leader**选举, 此时将判断当前节点是否为**leader**节点;  其次便是启动**informer**组件并从`api-server`获取到当前集群中的所有状态信息.

最后通过 ```sched.Run(ctx)``` 启动当前的scheduler调度程序.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L314](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L314)

`scheduler`的运行主要分为两个两个部分, 第一步启动两个*goroutine*将pod放到**ActiveQ**中,第二步启动*scheduleOne* 调度主逻辑.

注: **ActiveQ** 是一个堆,保存的是当前待调度的所有pod.

#### scheduleOne 主逻辑

调度大致可以分为三个部分, 第一步从队列里面取出一个待调度的pod; 第二步为pod应用调度策略, 第三部将pod绑定到某个选出来的Node.

###### 取出待调度Pod

```go
podInfo := sched.NextPod()
```

通过**NextPod**函数获取到当前待调度的pod信息, 该函数是在*scheduler*初始化时映射的**MakeNextPodFunc**函数,  可以看到其实也就是调用*Pop*取出当前队列的第一个元素.

###### 调度策略

首先, 获取当前pod定义的调度策略,默认情况下k8s提供的调度名称为:```default-scheduler``. 我们也可以自定义自己的调度名称.

其次, 验证pod当前是否可以跳过调度. 这里有两种情况,第一种是pod已经被删除,第二中是pod被assumed.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L634](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L634)

###### 调度周期

在每一次调度中,调度周期是同步进行的, 主要的代码如下:

```go
scheduleResult, err := sched.Algorithm.Schedule(schedulingCycleCtx, fwk, state, pod)
```

我们主要来看一下这个函数做了什么. 代码地址:

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/core/generic_scheduler.go#L97](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/core/generic_scheduler.go#L97)

调度器定义了一下接口, 在 **kube-scheduler **中实现调度的是*genericScheduler*. 所以正在运行*Schedule*函数的也是*genericScheduler*该结构体实现的方法.

```go
type ScheduleAlgorithm interface {
	Schedule(context.Context, framework.Framework, *framework.CycleState, *v1.Pod) (scheduleResult ScheduleResult, err error)
	// Extenders returns a slice of extender config. This is exposed for
	// testing.
	Extenders() []framework.Extender
}
```

首先, 调度器获取当前集群内的*snapshot()* 保存当前的状态到缓存中. 主要是更新当前集群的Node信息。

```go
	if err := g.snapshot(); err != nil {
		return result, err
	}
```

其次,执行优选函数,从当前Node中过滤掉所有可以用的Node. 返回一个可以的列表.

```go
feasibleNodes, diagnosis, err := g.findNodesThatFitPod(ctx, fwk, state, pod)
```

当然这里面如果返回的的Node列表为0则表示没有可用Node,此次调度也就失败了,如果返回的只有一个Node,那么这个Node也就是最优的Node.

我们来看一下*findNodesThatFitPod*这个函数.

优选也可以叫做过滤,会执行 `preFilter`, `Filter`, `postFilter`对应扩展点的所有插件.

```go
	// Run "prefilter" plugins.
	s := fwk.RunPreFilterPlugins(ctx, state, pod)
	// 运行所有的PreFilter插件.
```

```go
feasibleNodes, err := g.evaluateNominatedNode(ctx, pod, fwk, state, diagnosis)
```

对于抢占式的pod来说会验证当前的pod的*Status.NominatedNodeName*字段, 如果这个提名的Node通过了所有filter插件,那么这个Node就会被认为是最合适的Node.

```go
feasibleNodes, err := g.findNodesThatPassFilters(ctx, fwk, state, pod, diagnosis, allNodes)
// 运行所有的Filter插件.
```

```go
feasibleNodes, err = g.findNodesThatPassExtenders(pod, feasibleNodes, diagnosis.NodeToStatusMap)
// 将过滤出的所有feasibleNodes在Extenders插件中在过滤一次
```

以上得到的Node列表便是通过优选后的所有Node列表,之后便是优选阶段.

```go
priorityList, err := g.prioritizeNodes(ctx, fwk, state, pod, feasibleNodes)
```

执行优选函数,此阶段可以看做是调度器的preScore,Score阶段. 我们来看看这个函数.

优选阶段中每一个Node都会调用*RunScorePlugins*函数计算出这个node在此评分插件上的得分,这个Node上的所有插件评分都会被添加到一起,最后得到一个加权评分.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/core/generic_scheduler.go#L406](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/core/generic_scheduler.go#L406)

```go
host, err := g.selectHost(priorityList)
```

*selectHost*会根据前面优选函数得到的主机列表`priorityList`选择一个合适的pod。

**以上便是调度的主逻辑程序,但是对于每一次的调度pod不一定会拿到一个合适的主机进行调度, 那么将尝试抢占式调度.**

抢占式调度是在**postFilter**扩展点上运行的, 对于postFilter上的插件,如果有一个插件运行成功就表示抢占成功.

最终的结果就是将当前调度的pod的*Status.NominatedNodeName*设置为抢占的pod的Node. 抢占的逻辑有很多,这里我们就不一一探讨了。

```go
	if nominatedNode != "" {
		podCopy.Status.NominatedNodeName = nominatedNode
	}
```

最后,将是更新缓存和运行*reserve*, *Permit*插件. 



###### 绑定周期

绑定周期是异步的,在大规模集群中同一时间内可能会有大量的pod待调度,此处异步也主要是为了提高效率。

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L554](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L554)

绑定的逻辑比较简单,这里简单的解释一下:

1. 同步等待*permit*扩展点允许当前的pod可以调度.
2. 执行preBind扩展点上的所有插件
3. 执行绑定,绑定也是通过*plugins*,优先级是先执行extenders然后才是plugins.

如果绑定成功,将执行执行最后一个扩展点*PostBind*. 

```go
			// Run "postbind" plugins.
			fwk.RunPostBindPlugins(bindingCycleCtx, state, assumedPod, scheduleResult.SuggestedHost)
```

如果执行失败,将进入*un-reserve*扩展点. 

```go
			// trigger un-reserve plugins to clean up state associated with the reserved Pod
			fwk.RunReservePluginsUnreserve(bindingCycleCtx, state, assumedPod, scheduleResult.SuggestedHost)
```

[kube-scheduler 源码分析（scheduler 01）]: https://zhuanlan.zhihu.com/p/344909204
[Kube-scheduler 调度框架]: https://github.com/kubernetes/kubernetes/tree/release-1.21/pkg/scheduler

