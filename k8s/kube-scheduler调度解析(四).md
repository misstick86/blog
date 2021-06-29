这篇文章主要介绍一下**kube-scheduler**中的各个plugin和扩展点.

在调度解析的第一篇文章中我们介绍了扩展点, 插件. 其中插件是实现一个或多个扩展点.  默认所有的插件都存放在一下目录下:
[https://github.com/kubernetes/kubernetes/tree/release-1.21/pkg/scheduler/framework/plugins](https://github.com/kubernetes/kubernetes/tree/release-1.21/pkg/scheduler/framework/plugins)

**kube-scheduler**中默认启用的插件如下, 我们将一一讲解每个插件的作用和对应的扩展点实现.

## 插件

#### PrioritySort 插件

扩展点: QueueSort

提供对pod默认的基于优先级的排序,当优先级相等时根据时间戳判断.

#### SelectorSpread 插件

扩展点: `PreScore`, `Score`. 

**SelectorSpread** 对于属于`service`,`ReplicaSets` 和` StatefulSets`的 Pod，偏好跨多个节点部署。 换句话说也就是让当前pod尽量多节点部,提高pod的可用性.

###### PreScore 扩展点

获取当前pod的*lable*集合并将其写入到**cycleState**中供之后的*Score*,*NormalizeScore*扩展点使用.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/selectorspread/selector_spread.go#L195](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/selectorspread/selector_spread.go#L195)

###### Score 扩展点

计算当前pod和每个Node的得分,  也就是说对于一个pod每一个Node都会执行这个函数,返回值则是这个pod在这个Node上的分. 计算的规则就是拿当前节点上的Pod的标签和当前Pod的标签做匹配如果相等就加一.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/selectorspread/selector_spread.go#L227](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/selectorspread/selector_spread.go#L227)

###### NormalizeScore 扩展点

这个阶段会涉及到一个**zone**的概念, 先不展开详细讲解了. 请记住,*NormalizeScore*是一个修正分数的阶段, 它的计算规比较麻烦.

#### ImageLocality 插件

扩展点: `Score`

选择已经存在 Pod 运行所需容器镜像的节点。

#### TaintToleration 插件

扩展点：`Filter`，`Prescore`，`Score`。

实现了污点和容忍度.

> 关于污点和容忍度请先细读该文章: [污点和容忍度](https://kubernetes.io/zh/docs/concepts/scheduling-eviction/taint-and-toleration/)

###### Filter 扩展点

对于每个Node都执行一次这个函数, 过滤出pod不能容忍污点的Node.

###### Prescore 扩展点

统计所有容忍度操作为 *空* 或者为*PreferNoSchedule* 的`容忍列表`(即:`tolerations`),并保持到到*cycleState*中. 

###### Score 扩展点

基于*cycleState*为每个Node打分,每个的Node打分的规则是:  首先,过滤掉Node的影响为*PreferNoSchedule*的污点;其次

就是一一对比Node上的污点和Pod污点.

#### NodeName 插件

扩展点: `Filter`

检查 Pod 指定的节点名称与当前节点是否匹配, 就是让pod在一个指定的Node上运行.

#### NodePorts插件

扩展点: `PreFilter`，`Filter`。

检查 Pod 请求的端口在节点上是否可用。

###### PreFilter 扩展点

计算出一个Pod的所有*Containers*, 并取出这些*Containers*的所有*Ports*字段放在一个列表中,最后存入*cycleState*中.

###### Filter 扩展点

过滤pod上所有监听的端口已经在Node中存在的Node。

#### NodeAffinity 插件

扩展点：`preFilter`, `Filter`, `PreScore`,`Score`.

###### preFilter 扩展点

此阶段主要是获取Pod中的**NodeSelector** 和 **NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution**的值并保持到*cycleState*中.

###### Filter 扩展点

在*Filter*扩展点,将pod的**NodeSelector**和**Affinity**对每个Node做匹配; 

###### preScore 扩展点

取Pod中的preferredNodeAffinity数据并保持到*cycleState*中供之后的打分阶段使用.

###### Score 扩展点

#### InterPodAffinity 插件

扩展点:  `PreFilter`，`Filter`，`PreScore`，`Score`

实现节点选择器和节点亲和性. PodAffinityh和NodeAffinity工作方式基本相同, 这里就不详细介绍了.

#### AzureDiskLimits 插件,  GCEPDLimits 插件, EBSLimits 插件

检查该节点是否满足各个云厂商 Azure GCPPD, EBS 的卷限制, 这里暂时先不展开介绍了.

#### DefaultBinder 插件

扩展点: Bind

提供默认的绑定机制。

#### 介绍一些跟plugin相关概念

#### algorithm Provider

kube-scheduler提供了一个参数`--algorithm-provider string` 来让用自己选择*algorithm Provider*, 虽然在最新版本的kubenetes中已经弃用了这个参数, 但还是要介绍一下这个概念.

*algorithm Provider*提供了两个,分别是`ClusterAutoscalerProvider` 和 `DefaultProvider`, 通过传递不同的值来调度不同的`Provider`. 我们来简单看一下.

一个`Provider`对应一个`Config`, 从名字来都可以看出来`ClusterAutoscalerProvider`是对`DefaultProvider`的扩展, 默认的config配置如下:

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/algorithmprovider/registry.go#L71](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/algorithmprovider/registry.go#L71)

可以看到这里配置了每个扩展点启用的插件. 

#### 几个数据结构

**Plugin** 该数据结构包含一个Plugin的名称和权重.

**PluginSet** 对于每一个扩展点, 该数据结构包含一个`Enabled` 和 `Disabled`的列表集合.

**Plugins** 是一个包含多个扩展点的PluginSet集合.

**Registry** 从数据结构来上来看,registry是一个map数据结构,它记录每个算法提供商和*Plugins*的关联关系.

在实例化*scheduler*的时候就会调用**NewRegistry**方法将上面的两个*provider*初始化,并保存到**Registry**中.

## 扩展点

扩展点时在`frameworkImpl`中定义实现的,它暴露了一个数据结构接口:

```go
type extensionPoint struct {
  // 可以配置在这个扩展点的所有插件列表
	// the set of plugins to be configured at this extension point.
	plugins config.PluginSet
  // 运行这个扩展点的具体实现
	// a pointer to the slice storing plugins implementations that will run at this
	// extension point.
	slicePtr interface{}
}
```

## 从头捋一下

这一部分我们一默认的`Provider`为列,在源码中从头捋一下和扩展点以及Plugin有关的代码. 

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L175](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/scheduler.go#L175)

从这一部分我们可以看到设置了默认的`profile`, 也就是`Default-scheduler`;  以及选择默认的`AlgorithmProvider`为`DefaultProvider`.  

注意:  这两默认值都会以**FUNCTIONAL OPTIONS**的方式重新赋值.值根据命令行传入的自定义参数.

```go
// 初始化传递的参数	
scheduler.WithProfiles(cc.ComponentConfig.Profiles...),
scheduler.WithAlgorithmSource(cc.ComponentConfig.AlgorithmSource),

// 使用 FUNCTIONAL OPTIONS 模式修改默认参数
for _, opt := range opts {
		opt(&options)
	}
```

之后便是注册树内插件和合并树外插件.

以默认的 `DefaultProvider` 流程走下去,之后便是创建scheduler. 之前说过所有的Plugin都是注表内管理的.  在上层默认又提供了`DefaultProvider` 和 `ClusterAutoscalerProvider` 两个`Provider`, 这是一个Map数据结构, 我们以`DefaultProvider`为列便取出了所有的Plugin.  然后就是将默认的Plugin和用户自定定的Pulgin合并到一起统一放在**Configurator**的profiles中.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/factory.go#L196](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/factory.go#L196)

在根据*profile*创建 **frameworkImpl** 时便将扩展点和Plugin关联起来了,我们看看这个流程:

1、 从profile中获取所有的需要的Plugin

```go
	// get needed plugins from config
	pg := f.pluginsNeeded(profile.Plugins)
// 方便理解 这里给出 profile.Plugins 的数据结构如下
/*{
      QueueSort: schedulerapi.PluginSet{
        Enabled: []schedulerapi.Plugin{
          {Name: queuesort.Name},
        },
      },
      PreFilter: schedulerapi.PluginSet{
        Enabled: []schedulerapi.Plugin{
          {Name: noderesources.FitName},
          {Name: nodeports.Name},
          {Name: podtopologyspread.Name},
          {Name: interpodaffinity.Name},
          {Name: volumebinding.Name},
          {Name: nodeaffinity.Name},
        },
      },
		}
*/
// pluginsNeeded 函数的具体实现
func (f *frameworkImpl) pluginsNeeded(plugins *config.Plugins) map[string]config.Plugin {
	// 这里保存着这个profile启用的所有的插件,因为插件可以应用多个扩展点,但插件本身只需要保留一份,算是去重操作
  pgMap := make(map[string]config.Plugin)
  // 此处的数据结构如下:
  /*
   {
   		'PrioritySort': {"name": "PrioritySort", weight: 1}
   }
  */
	if plugins == nil {
		return pgMap
	}

	find := func(pgs config.PluginSet) {
		for _, pg := range pgs.Enabled {
			pgMap[pg.Name] = pg
		}
	}
  
	for _, e := range f.getExtensionPoints(plugins) {
    // 拿到每个扩展点的extensionPoint数据结构时只保存所有启用的Plugin.
		find(e.plugins)
	}
	return pgMap
}

// 定义 extensionPoint 的数据结构
type extensionPoint struct {
	// the set of plugins to be configured at this extension point.
	plugins config.PluginSet
	// a pointer to the slice storing plugins implementations that will run at this
	// extension point.
	slicePtr interface{}
}

// 这个函数看起来更像是一个构造函数
func (f *frameworkImpl) getExtensionPoints(plugins *config.Plugins) []extensionPoint {
	return []extensionPoint{
		{plugins.PreFilter, &f.preFilterPlugins},
		{plugins.Filter, &f.filterPlugins},
		{plugins.PostFilter, &f.postFilterPlugins},
		{plugins.Reserve, &f.reservePlugins},
		{plugins.PreScore, &f.preScorePlugins},
		{plugins.Score, &f.scorePlugins},
		{plugins.PreBind, &f.preBindPlugins},
		{plugins.Bind, &f.bindPlugins},
		{plugins.PostBind, &f.postBindPlugins},
		{plugins.Permit, &f.permitPlugins},
		{plugins.QueueSort, &f.queueSortPlugins},
	}
  // 此处返回的数据结构如下, 以QueueSort为列
  /*
  [ 
   {
      plugins: {
         Enabled: []schedulerapi.Plugin{
          {Name: queuesort.Name},
           },
          }
      slicePtr: []framework.QueueSortPlugin
      // 这是一个结构，对应于QueueSortPlugin的具体实现
   },
   {
    ..........
   }
  ]
  */
}
```

将每个插件放到每个**frameworkImpl** 的每个扩展点上便是最后一件事情. 

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L310](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/runtime/framework.go#L310)

这里解析一下每个参数,并以**QueueSort** 插件为列介绍一下大致的流程:

```go
args, err := getPluginArgsOrDefault(pluginConfig, name)
// 此处根据插件名称获取每个插件定义的参数或者默认参数
```

```go
p, err := factory(args, f)

```

调用每个插件的工厂方法开始实例化这个插件, 以QueueSort为列便是执行这个方法.

[https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/queuesort/priority_sort.go#L48](https://github.com/kubernetes/kubernetes/blob/release-1.21/pkg/scheduler/framework/plugins/queuesort/priority_sort.go#L48)

工厂方法会实例化所有的插件对象并保存在一个map的数据结构中.



[kube-scheduler 参数]: https://kubernetes.io/zh/docs/reference/command-line-tools-reference/kube-scheduler/
[调度插件]: https://kubernetes.io/zh/docs/reference/scheduling/config/#scheduling-plugins

