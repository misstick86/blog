## kube-scheduer 调度解析（一）

之前在学习`kubenetes`时就知道调度一个pod是通过`k8s`的控制面板中的一个**kube-scheduer**组件工作的, 一直都认为对一个pod的调度是通过**预选**和**优选**两个函数来完成的. 但最近在阅读新版本**kubenetes**的源码时发现,已经更新了多个版本,而且引用了新的调度框架.

> 引入调用框架的主要目标是解决调度的可扩展性.

#### 调度框架

调度框架中定义几个概念. 分别为: **调度周期**, **绑定周期**, **扩展点**, **插件**.

![scheduling-framework-extensions](../../static/images/k8s/scheduling-framework-extensions.png)

上图表示一个pod在被调度的整个流程, 被称为`调度上下文`。  POD从优先级队列中首先进入**调度周期**,然后在进入**绑定周期**.

**调度周期** 的主要工作是在一组Node中选择一个Node,并将此Node信息传递给 *绑定周期* 使用.

**绑定周期** 的主要工作是根据传递的Node更新上pod的信息模板中`spec.nodeName`字段并上报api-server.

###### 调度周期

在调度中期中定义了两个大阶段分别是: **Filter** 和 **Score** 这两个阶段中又分别定义了多个扩展点。

1. preFilter: 预处理Pod信息,检查pod或者集群是否满足条件. 如果 PreFilter 插件返回错误,则调度周期将终止.
2. Filter: 过滤出不能运行该 Pod 的节点, 对于每个Node都会经历该扩展点上定义的插件进行赛选.
3. PostFilter: 该阶段主要用于没有可用的Node为其pod提供调度, 一个典型的场景就是抢占式调度
4. preScore: 前置评分插件用于执行 “前置评分” 工作，即生成一个可共享状态供评分插件使用。
5. Score:  评分主要分为两个阶段. 首先, 调度器调用每个插件为每个node进行评分, 并进行排名;其次是“normalize scoring”, 标准化评分插件用于在调度器计算节点的排名之前修改分数。 
6. Reserve: 这是调度周期的最后一步, 该阶段用于管理运行时状态的插件. 
7. Permit: 这个扩展点主要用户阻止或者延迟Pod的绑定 , 通常有三种情况: **approve**,**deny**,**wait**.

###### 绑定周期

在面**调度周期**的Permit阶段中,一旦一个pod被批准绑定后将立刻进入绑定周期. 绑定周期内定义了如下扩展点:

1. preBind: 预绑定插件用于执行 Pod 绑定前所需的任何工作。 例如，一个预绑定插件可能需要提供网络卷并且在允许 Pod 运行在该节点之前 将其挂载到目标节点上。
2. Bind: 指定pod绑定
3. postBind: pod绑定后执行清理相关操作.

#### 插件

每个扩展点的实现都是通过插件的形式, 那么插件是如何和扩展点对应上的呢? 答案就是*plugin APi* .  扩展点的定义具有以下的接口:

```go
type Plugin interface {
   Name() string
}

type QueueSortPlugin interface {
   Plugin
   Less(*PodInfo, *PodInfo) bool
}


type PreFilterPlugin interface {
   Plugin
   PreFilter(CycleState, *v1.Pod) *Status
}
```

源码上的定义如下: [kube-scheduler plugin](https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/interface.go#L268)

以**PreFilterPlugin**为例,插件必须实现**PreFilterPlugin** 和 **PreFilterExtensions** 方法.

#### 插件生命周期

###### 初始化

插件的初始化总共分为两个步骤,第一步: 插件的注册;第二步: 调度程序根据配置决定哪些插件被实例化.

> 如果插件被多个扩展点引用，也只会被实例化一次.

###### 并行

插件在一下情况下会被并行调用.

1. 评估多个节点时,一个插件可能会被调用多次
2. 插件可能会被多个调度上下问题调用

> 在一个调度上下文中，每一个扩展点都是串行执行。

在整个调度上下文中, 调度周期是串行执行,而绑定周期可以并行绑定. 其中`Permit` 也是一个单独的线程在处理. 在开启下一个调度上下文时, 任何扩展点包括**Permit** 都必须完成.

![](../static/images/k8s/scheduling-framework-threads.png)

#### 插件注册

每一个插件都必须提供一个构造方法实现插件的注册, 这些代码被硬编码到注册表上. 例如:

```go
type PluginFactory = func(runtime.Unknown, FrameworkHandle) (Plugin, error)

type Registry map[string]PluginFactory

func NewRegistry() Registry {
   return Registry{
      fooplugin.Name: fooplugin.New,
      barplugin.Name: barplugin.New,
      // New plugins are registered here.
   }
}
```

#### 插件配置

每个插件的配置允许此插件是 *启用* 或者 *禁用* .  默认的插件配置如下:

[scheduler default register](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/algorithmprovider/registry.go#L71)

#### 自定义插件

**Kube-scheduler** 支持以`Out of Tree`的方法集成你自己的插件.  开发者只需要编写自己的代码,然后修改*kube-scheduler**的main** 方法将自己编写的插件注册进来既可.  

```go
func NewSchedulerCommand(registryOptions ...Option) *cobra.Command
```

可以看到, 在实例化scheduler对象时允许你传递自己的**registry**.

一个简单的示例如下:

[scheduler-plugin ](https://github.com/kubernetes-sigs/scheduler-plugins/blob/master/cmd/scheduler/main.go#L46)

[scheduler-plugins]: https://github.com/kubernetes-sigs/scheduler-plugins
[Kubernetes scheduing framework ]: https://kubernetes.io/zh/docs/concepts/scheduling-eviction/scheduling-framework/
[624-scheduling-framework]: https://github.com/kubernetes/enhancements/tree/master/keps/sig-scheduling/624-scheduling-framework







