这篇文件主要介绍的是**kube-scheduler**的具体实现framework.

在官方的最新调度器提案中定义了一个调度器应该是插件形式运行的, 具体的流程官方也给了一个比较形象的图片. 那么这些都是怎么实现的呢. 这篇文件将根据源码一一揭晓.

![](../static/images/k8s/scheduling-framework-extensions.png)

框架的接口定义在*pkg/scheduler/framework/interface.go*这个文件里面.

[https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/interface.go#L463](https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/interface.go#L463)

可以看到它要去每个框架的实现者必须具有以下功能:

1. 要讲调度队列里面的pod进行排序
2. 配置运行`preFilter`,`Filter`,`postFilter`插件到对应的扩展点上
3. 配置运行`PreScore`,`Score`插件在对应的扩展点上
4. 配置运行`PreBind`,`Bind`,`PostBind`插件在对应的扩展点上
5. 配置运行`Permit`,`Reserve`,`Unreserve`插件在对应的扩展点上
6. 判断是否有`Filter`,`PostFilter`,`Score`插件
7. 列出所有配置到扩展点的插件
8. 当一个pod处在延迟调度情况下, 需要延迟改pod的调度

## Framework实现

以上边上*Framework*定义的接口,也就是说如果我们需要自定义自己的调度框架也需要按照这个接口在实现,在**kube-scheduler**中的实现是`frameworkImpl`结构.

详细的来看一下这个结构:

[https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/runtime/framework.go#L73](https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/runtime/framework.go#L73)

```go
type frameworkImpl struct {
  // 调度插件注册表，所有的插件都是注册到注册表后在使用
	registry             Registry
  // 这个是为实现Handle.SnapshotSharedLister()接口准备的，是创建frameworkImpl时传入.
	snapshotSharedLister framework.SharedLister
  // 这是为实现Handle.GetWaitingPod/RejectWaitingPod/IterateOverWaitingPods()接口准备的。
	waitingPods          *waitingPodsMap
  // 每个插件都有一个权重,这里保存的是所有插件和权重的映射
	scorePluginWeight    map[string]int
  // 一下所有的*Plugins都是对应到每个扩展点的插件. 
	queueSortPlugins     []framework.QueueSortPlugin
	preFilterPlugins     []framework.PreFilterPlugin
	filterPlugins        []framework.FilterPlugin
	postFilterPlugins    []framework.PostFilterPlugin
	preScorePlugins      []framework.PreScorePlugin
	scorePlugins         []framework.ScorePlugin
	reservePlugins       []framework.ReservePlugin
	preBindPlugins       []framework.PreBindPlugin
	bindPlugins          []framework.BindPlugin
	postBindPlugins      []framework.PostBindPlugin
	permitPlugins        []framework.PermitPlugin

  // 与apiserver交互的一些必须信息, 如kubeconfig,clientset等
	clientSet       clientset.Interface
	kubeConfig      *restclient.Config
	eventRecorder   events.EventRecorder
	informerFactory informers.SharedInformerFactory

	metricsRecorder *metricsRecorder
  // 每个profile的名称, 默认的叫做default-scheduler; 
	profileName     string
  // 每个
	extenders []framework.Extender
	framework.PodNominator

	parallelizer parallelize.Parallelizer

	// Indicates that RunFilterPlugins should accumulate all failed statuses and not return
	// after the first failure.
  // 是否运行所有的Filter插件,即使某个Filter插件失败也无所谓
	runAllFilters bool
}

```

## Framework的构造函数

```go
func NewFramework(r Registry, profile *config.KubeSchedulerProfile, opts ...Option) (framework.Framework, error)
```

在创建一个Framework结构时, 它接收两个参数和一个可变参数. 其中`Registry`是在创建*scheduler*时定义的插件注册表, `profile`也是在实例化*scheduler*定义的.

变长参数*opts*是一个使用*FUNCTIONAL OPTIONS*进行实例化**编程模式**, 这里需要引用另一个结构体*frameworkOptions*. 一般来说,我们想实例化一个结构体是如果它的字段或其他额外字段非常多时,我们可以引用其*Options*额外的结构体来提前准备好数据, 从某种角度来说也是一种编程模型.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L143](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L143)

我们看看如何实例化这个frameworkOptions. 

代码中定义了一个默认的实例化*Options*的函数, 然后其他额外需要配置的字段都是通过*FUNCTIONAL OPTIONS*模式添加进来的.

```go
	for _, opt := range opts {
		opt(&options)
	}
```

这里的*opt*可变参数便是通过**NewMap**函数传递过来的. 

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/factory.go#L138](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/factory.go#L138)

> 有关 FUNCTIONAL OPTIONS 的编程模式请参考: [GO 编程模式：FUNCTIONAL OPTIONS](https://coolshell.cn/articles/21146.html)

从frameworkImpl的实例化可以看出, frameworkImpl的大量属性字段都来自与Option所提供的数据.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L251](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L251)

## 什么是registry(注册表)

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/registry.go#L58](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/registry.go#L58)

**Registry**是所有可用插件的集合,调度框架使用一个*Registry*启动被配置插件, 在调度框架被初始化前所有的插件需要要注册到注册表中.

注册表本身是一个map数据结构, *key*是该插件的名称, *value*是对应插件的构造方法,一版叫做**New function Name**.

通过**NewInTreeRegistry**函数将注册所有的*树内插件*(也叫做内部插件).  已注册的内部插件如下所示:
[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/registry.go#L56](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/registry.go#L56)

注: **registry**的初始化是在*scheduler*阶段就开始的,通过参数传给了*Framework*构造函数。

## 什么是snapshotSharedLister

该结构的定义了一个接口**SharedLister**,该接口主要和操作Node有关的数据结构和方法有关.  真正实现这两个接口的是**snapshot**结构. **SharedLister**的定义如下:

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/listers.go](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/listers.go)

这一部分主要和缓存有关,我会在另一篇中详细探讨.

## 什么是waitingPods

**waitingPods**主要在*premit*扩展点用于记录延迟pod的数据结构. *waitingPods*是一个指针类型的数据结构,也就是说我们每次操作的都是统一个数据, 并且这是一个线程安全的**Map**.

## 什么是extenders

**extenders**应该是社区比较早的方案来扩展kubenetes的调度方案, 它是一个外部的进程,支持 Filter、Preempt、Prioritize 和 Bind 的扩展，scheduler 运行到相应阶段时，通过调用 Extender 注册的 webhook 来运行扩展的逻辑，影响调度流程中各阶段的决策结果。

以 Filter 阶段举例，执行过程会经过 2 个阶段: 

​	1、scheduler 会先执行内置的 Filter 策略，如果执行失败的话，会直接标识 Pod 调度失败。

 	2、如何内置的 Filter 策略执行成功的话，scheduler 通过 Http 调用 Extender 注册的 webhook, 将调度所需要的 Pod 和 Node 的信息发送到到 Extender，根据返回 filter 结果，作为最终结果。

## 什么是profile

在 Kubernetes Scheduler 的代码中有两个和 Profile 字样相关的对象：KubeSchedulerProfile 和 Profile。他们是两个完全不同的对象，但是又有一些关联关系。

- ***KubeSchedulerProfile*** 是提供给用户进行配置的界面,他是一个数组,一个调度程序可以有多个*KubeSchedulerProfile*, 默认提供的叫做*default-scheduler*. Pod 可以通过设置其关联的*scheduler name*来选择在特定配置文件下进行调度。

参考: [https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L175](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L175)

- ***Profile*** 是由 KubeSchedulerProfile 创建而来，用于执行具体的调度操作。每个Framework对应一个 Profile。

参考: [https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/profile/profile.go#L65](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/profile/profile.go#L65)

[Kube-scheduler 源码]: https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler
[进击的 Kubernetes 调度系统（一）：Scheduling Framework]: https://www.infoq.cn/article/lYUw79lJH9bZv7HrgGH5
[KubeSchedulerProfile]: https://github.com/derekguo001/understanding-kubernetes/blob/master/kube-scheduler/component/kube-scheduler-profile.md

