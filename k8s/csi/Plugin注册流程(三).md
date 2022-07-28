根据CSI基础可知, 用户写的Driver需要事先注册到kubernetes系统中, 这篇文章主要介绍用户写的驱动如何和 **node-driver-register**,  **kubelet** 交互, 并最终注册到Kubernetes系统中.

这里会以 [alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver) 的Disk Plugin 插件做分析,也算是对于这部分的源码解读.


### 部署

Kubernetes 提供了一个叫做CSIDriver的资源,如果我们想将DISK这个插件注册到kubernetes的CSI中,需要先创建对应的CSI Driver对象。

```yaml
apiVersion: storage.k8s.io/v1beta1
kind: CSIDriver
metadata:
  name: diskplugin.csi.alibabacloud.com
spec:
  attachRequired: true
  podInfoOnMount: true
```

**node-driver-register** 是官方提供注册的一个组件, 他和用户写的驱动程序一起以Demonset的方式部署在kubernetes之上.对于用户每开发一个新的Driver都必须部署一个**node-driver-register** sidecar 容器, 可以看到阿里云部署了三个Sidecar容器. 分别是 **DiskPlugin**, **OSSPlugin**, **NasPlugin**. 

[https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver/blob/master/deploy/disk/disk-plugin.yaml#L9](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver/blob/master/deploy/disk/disk-plugin.yaml#L9)



#### 流程

在上一节介绍 [node-driver-registrar](https://github.com/kubernetes-csi/node-driver-registrar) 时, [node-driver-registrar](https://github.com/kubernetes-csi/node-driver-registrar) 会在 `/registration/` 目录下创建一个以插件名命名的sock文件, 而 `kubelet` 组件中会有一个叫做 **PluginManager** 的子组件, 它会监听这个目录下面的文件创建、删除事件, 来处理后续的 CSI 注册任务.



### Kubelet Plugin Manager 源码解析

源码中的注释是这样解释的: **Plugin Manager** 是一个异步的循环, 它知道哪些插件是要注册的, 哪些插件取消注册并使其注册或取消.

对于 `Plugin Manager` 来说又有四个子组件, 分别是 **Cache** , **Plugin Watch**, **reconciler**, **operationexecutor**. 

首先, 来看一下 **Plugin Manager** 的接口和结构体:

```go
type PluginManager interface {
	// 启动PluginManager 和它控制的所有异步循环
	Run(sourcesReady config.SourcesReady, stopCh <-chan struct{})

	// AddHandler 根据给定的handler类型添加一个Hander, 
	AddHandler(pluginType string, pluginHandler cache.PluginHandler)
}
```



```go
// pluginManager implements the PluginManager interface
type pluginManager struct {
	// desiredStateOfWorldPopulator (the plugin watcher 插件观察) 一个异步循环器来维护desiredStateOfWorld的状态
	desiredStateOfWorldPopulator *pluginwatcher.Watcher

	// reconcile 是一个定期运行的循环, 他协调actualStateOfWorld向desiredStateOfWorld的状态改变
	reconciler reconciler.Reconciler
  // actualStateOfWorld 是一个包含当前插件实际状态的结构体. 例如哪些插件是已经注册的. 该结构体状态是在插件注册、取消注册成功后修改
	actualStateOfWorld cache.ActualStateOfWorld

  // desiredStateOfWorld 是一个包含当前插件期望达到状态的结构体. 例如什么插件需要注册, 该结构体的数据由 Plugin watch 改变
	desiredStateOfWorld cache.DesiredStateOfWorld
}
```

#### Plugin Watch

**Plugin Watch** 是一个观察某个目录下创建、删除事件的观察器.  他使用 **[fsnotify](https://github.com/fsnotify/fsnotify)** 包来实现. 结构体如下:

```go
// Watcher is the plugin watcher
type Watcher struct {
  // 需要 watch 的目录
	path                string
  // 文件系统操作的接口
	fs                  utilfs.Filesystem
  // fsnotify watch 的对象实例
	fsWatcher           *fsnotify.Watcher
  // 期望的状态, 当 watch 的目录发生事件后更改状态
	desiredStateOfWorld cache.DesiredStateOfWorld
}
```

#### Cache 

`Cache` 是一个缓存当前系统中插件状态的组件,他分别定义了两个**状态**(也可以称之为缓存): **ActualStateOfWorld** 和 **DesiredStateOfWorld**。 

**ActualStateOfWorld** 和 **DesiredStateOfWorld** 的结构体是一样的, 但对于这两种状态所有进行的操作是不一样的. 他们的结构体如下:

```go 
type desiredStateOfWorld or ActualStateOfWorld struct {

	// socketFileToInfo 是一个包含当前已经注册的所有插件的集合, key 是插件 socket 文件路径, Value则是Plugin组成Info结构体
	socketFileToInfo map[string]PluginInfo
	sync.RWMutex
}

```

>  PluginInfo 是一个包含当前插件所有信心的结构体, 如: 插件的名字， 路径， 注册时间.

###### ActualStateOfWorld 

**ActualStateOfWorld** 简称 ASW, 当前插件系统中插件的实际状态,  ASW定义了一下接口:

- GetRegisteredPlugins(): 获取当当前插件系统中的所有插件, 返回的是一个列表
- AddPlugin(): 向插件系统中添加一个给定的插件
- RemovePlugin(): 根据插件的路径移除一个插件
- PluginExistsWithCorrectTimestamp(): 根据时间戳检查一个插件是否存在

###### DesiredStateOfWorld

**DesiredStateOfWorld** 简称 DSW, 当前插件系统中插件的期望状态,  DSW定义了一下接口:

- AddOrUpdatePlugin():  如果插件不存在则向`DesiredStateOfWorld`中添加插件,如果存在，则更新插件的时间戳
- RemovePlugin(): 根据给定的路径删除一个插件
- GetPluginsToRegister(): 获取当前插件系统中所有期望状态下的插件
- PluginExists() : 判断一个插件是否存在.

#### operationexecutor 

**operationexecutor** 定义了一组注册或取消注册插件的集合, 并同过 `NewGoRoutineMap` 进行执行. `NewGoRoutineMap` 将防止在同一个sock文件路径上触发多个操作.

对于注册和取消注册应该该是幂等的, 例如: **RegisterPlugin**应该返回成功如果一个插件已经注册了. 然而这依赖插件的 **handler** 实现这一行为.

一旦插件注册成功, **actualStateOfWorld** 的状态将会立即的更新表明这个插件注册或取消.

由于是异步执行的, 一旦发生错误将会记录在日志里面, goroutine 也会立即退出停止更新**actualStateOfWorld**状态.

要实现一个**operationexecutor**功能需要实现一下接口:

```go
type OperationExecutor interface {
	// RegisterPlugin registers the given plugin using the a handler in the plugin handler map.
	// It then updates the actual state of the world to reflect that.
	RegisterPlugin(socketPath string, timestamp time.Time, pluginHandlers map[string]cache.PluginHandler, actualStateOfWorld ActualStateOfWorldUpdater) error

	// UnregisterPlugin deregisters the given plugin using a handler in the given plugin handler map.
	// It then updates the actual state of the world to reflect that.
	UnregisterPlugin(pluginInfo cache.PluginInfo, actualStateOfWorld ActualStateOfWorldUpdater) error
}
```

也就是说**OperationExecutor**是真正调用*handler*实现插件注册和取消注册的组件.  **reconciler**只是一个协调组件.

#### reconciler

**Reconciler** 是一个定期运行的控制循环, 它同过注册和取消注册插件操作协调 **ASW** 和 **DSW** 的状态. 它也提供为一种插件类型提供一个Handler. 

**Reconciler** 的接口如下:

```go
type Reconciler interface {
	// 启动一个 Reconciler 组件
	Run(stopCh <-chan struct{})

	// 为一个 plugin type 添加一个 handler. Plugin type 主要分为 CSIPlugin 和 DevicePlugin.
	AddHandler(pluginType string, pluginHandler cache.PluginHandler)
}
```

**Reconciler** 的结构体如下:

```go
type reconciler struct {
   operationExecutor   operationexecutor.OperationExecutor
   loopSleepDuration   time.Duration
   desiredStateOfWorld cache.DesiredStateOfWorld
   actualStateOfWorld  cache.ActualStateOfWorld
   handlers            map[string]cache.PluginHandler
   sync.RWMutex
}
```

以上,便是和注册有关的大多数组件, CSI的注册也是在这些组件的协同工作下维护在kubernetes系统中. 后面我们将从kubelet初始化 **Plugin Manager** 入手同过源码一点一点剖析.

### (三)源码流程

一切都要从 **Kubelet** 项目的 *NewMainKubelet* 函数说起, 它是初始化**kubelet**组件的函数, **Plugin Manager** 的初始化也是在这里. 

`RootDirectory` 是初始化kubelet的一个参数, 这个参数是设定 **kubelet** 默认的工作目录. 默认为`/var/lib/kubelet` . 

###### Plugin Manager的初始化

```go
// https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/kubelet/kubelet.go#L784	
klet.pluginManager = pluginmanager.NewPluginManager(
		klet.getPluginsRegistrationDir(), /* sockDir */
    // 这是kubenetes的一个事件管理器.
		kubeDeps.Recorder,
	)
```

*getPluginsRegistrationDir()* 函数是获取插件注册的路径， 也是 *Plugin Watch* 要监听的目录. 默认为 `/var/lib/kubelet/plugins_registry`

*NewPluginManager()* 函数就比简单了, 它就是初始化`PluginManager`结构体所需要的各个结构体: 如, `ASW, ` `DSW`, `reconciler`. 

###### Plugin Manager的运行

**Plugin Manager** 的运行是从**Kubelet** 运行开始的，这一层的逻辑还是比较复杂的. 调用链如下:

`kubelet的Run()` --> `updateRuntimeUp()` --> `initializeRuntimeDependentModules()` 

在 *initializeRuntimeDependentModules()* 中才是正则启动**Plugin Manager**.  首先是为 **Plugin Manager** 对应类型的 Plugin 添加Handler. 然后 **Plugin Manager** 的 *RUN()* 以一个 gorounte 启动. **RUN()** 函数做的事情如下:

```go
func (pm *pluginManager) Run(sourcesReady config.SourcesReady, stopCh <-chan struct{}) {
	defer runtime.HandleCrash()
  // 启动 Plugin Watch 监听 /var/lib/kubelet/plugins_registry 这个目录， 如果有文件新增就表示有插件要注册进来
	pm.desiredStateOfWorldPopulator.Start(stopCh)
	klog.V(2).InfoS("The desired_state_of_world populator (plugin watcher) starts")

	klog.InfoS("Starting Kubelet Plugin Manager")
  // 以一个携程的方式运行 reconciler. 来协调 DSW 和 ASW 的状态.
	go pm.reconciler.Run(stopCh)

	metrics.Register(pm.actualStateOfWorld, pm.desiredStateOfWorld)
	<-stopCh
	klog.InfoS("Shutting down Kubelet Plugin Manager")
}
```

以上一个**Plugin Manager** 组件的启动就完成了, 我们知道 **node-driver-registrar** 这个组件是负责向 **Plugin Watch** 这个目录中创建 SOCK 文件的, 下面 我们来分析一下当一个插件注册进来后发生了什么? (也是创建一个sock文件)。

###### 插件注册源码分析

首先是**Plugin Watch** 的 *Start()* 函数:

```go
func (w *Watcher) Start(stopCh <-chan struct{}) error {
	klog.V(2).InfoS("Plugin Watcher Start", "path", w.path)

	// Creating the directory to be watched if it doesn't exist yet,
	// and walks through the directory to discover the existing plugins.
	if err := w.init(); err != nil {
		return err
	}

	fsWatcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("failed to start plugin fsWatcher, err: %v", err)
	}
	w.fsWatcher = fsWatcher

	// Traverse plugin dir and add filesystem watchers before starting the plugin processing goroutine.
	if err := w.traversePluginDir(w.path); err != nil {
		klog.ErrorS(err, "Failed to traverse plugin socket path", "path", w.path)
	}

	go func(fsWatcher *fsnotify.Watcher) {
		for {
			select {
			case event := <-fsWatcher.Events:
				//TODO: Handle errors by taking corrective measures
				if event.Op&fsnotify.Create == fsnotify.Create {
					err := w.handleCreateEvent(event)
					if err != nil {
						klog.ErrorS(err, "Error when handling create event", "event", event)
					}
				} else if event.Op&fsnotify.Remove == fsnotify.Remove {
					w.handleDeleteEvent(event)
				}
				continue
			case err := <-fsWatcher.Errors:
				if err != nil {
					klog.ErrorS(err, "FsWatcher received error")
				}
				continue
			case <-stopCh:
				w.fsWatcher.Close()
				return
			}
		}
	}(fsWatcher)

	return nil
}
```

1. 调用 *init()* 函数创建要监听的目录
2. 实例化一个**fsnotify.NewWatcher()** 对象, 并将其赋值给**Plugin watcher** 结构下的 *fsWatcher* 对象.
3. 将目录添加到 *fsnotify* 的监听器中, 并遍历当前目录下所有目录将其加到 *fsnotify* 监听器中.
4. 启动 *fsnotify* 监听器.

当监听的目录下有事件发生时便调用对应的处理方法, 如果是 *ADD* 事件调用`handleCreateEvent()` 方法, 如果是 *DEL* 事件则调用 `handleDeleteEvent()` 方法.

**w.handleCreateEvent(event)** 的处理逻辑如下:

```go
func (w *Watcher) handleCreateEvent(event fsnotify.Event) error {
	klog.V(6).InfoS("Handling create event", "event", event)

	fi, err := os.Stat(event.Name)
	// TODO: This is a workaround for Windows 20H2 issue for os.Stat(). Please see
	// microsoft/Windows-Containers#97 for details.
	// Once the issue is resvolved, the following os.Lstat() is not needed.
	if err != nil && runtime.GOOS == "windows" {
		fi, err = os.Lstat(event.Name)
	}
	if err != nil {
		return fmt.Errorf("stat file %s failed: %v", event.Name, err)
	}

	if strings.HasPrefix(fi.Name(), ".") {
		klog.V(5).InfoS("Ignoring file (starts with '.')", "path", fi.Name())
		return nil
	}

	if !fi.IsDir() {
		isSocket, err := util.IsUnixDomainSocket(util.NormalizePath(event.Name))
		if err != nil {
			return fmt.Errorf("failed to determine if file: %s is a unix domain socket: %v", event.Name, err)
		}
		if !isSocket {
			klog.V(5).InfoS("Ignoring non socket file", "path", fi.Name())
			return nil
		}

		return w.handlePluginRegistration(event.Name)
	}

	return w.traversePluginDir(event.Name)
}

func (w *Watcher) handlePluginRegistration(socketPath string) error {
	if runtime.GOOS == "windows" {
		socketPath = util.NormalizePath(socketPath)
	}
	// Update desired state of world list of plugins
	// If the socket path does exist in the desired world cache, there's still
	// a possibility that it has been deleted and recreated again before it is
	// removed from the desired world cache, so we still need to call AddOrUpdatePlugin
	// in this case to update the timestamp
	klog.V(2).InfoS("Adding socket path or updating timestamp to desired state cache", "path", socketPath)
	err := w.desiredStateOfWorld.AddOrUpdatePlugin(socketPath)
	if err != nil {
		return fmt.Errorf("error adding socket path %s or updating timestamp to desired state cache: %v", socketPath, err)
	}
	return nil
}
```

(1): 判断新增事件是否为文件类型, 并且是否为 socket 文件。

(2): 如果是sock文件, 调用 `handlePluginRegistration()` 将插件注册到 *desiredStateOfWorld* 中.

其次是**reconciler**的**run()** 方法:

**reconciler**是协调ASW和DSW的状态, 使其达到一致. 它的逻辑如下:

(1): 确保ASW有需要取消注册的插件要取消注册掉. ASW中的每个插件和DSW的插件进行对比,如果DSW中不存在则取消注册, 如果DSW中的这个插件存在切时间戳不相同也要取消注册. 调用 rc.operationExecutor.UnregisterPlugin 做 plugin 取消注册操作.

(2): 确保DSW中的插件要全都注册.  对比 desiredStateOfWorld，如果 actualStateOfWorld 中没有该 socket 信息，则调用 rc.operationExecutor.RegisterPlugin 做 plugin 注册操作。

**reconciler**的**run()** 方法的源代码可参考:

[https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/kubelet/pluginmanager/reconciler/reconciler.go#L110](https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/kubelet/pluginmanager/reconciler/reconciler.go#L110)

插件的实际注是 **OperationExecutor** 的组件. 上面的数据结构可知它有两个接口: `RegisterPlugin`, `UnRegisterPlugin`.

###### RegisterPlugin()函数

这两个函数的调用逻辑链都比较复杂, 先整体给出一个调用逻辑链:

`rc.operationExecutor.RegisterPlugin` --> `oe.operationGenerator.GenerateRegisterPluginFunc` --> `handler.RegisterPlugin()` --> `nim.InstallCSIDriver()` --> `nim.updateNode()`

*GenerateRegisterPluginFunc()* 函数是执行注册插件的主要方法, 它的主要逻辑如下:

(1) 根据 Plugin 的 sock 地址实例化一个GRPC客户端, 调用 **node-driver-registrar** 的`Getinfo()` 方法获取Plugin的信息.

(2) 根据 `Getinfo()` 返回的信息, 确定Plugin的类型,来取得对应的 Handler.

(3) 调用 handler.ValidatePlugin()，检查已注册的 plugin 中是否有比该需要注册的 plugin 同名的或更高的版本，如有，则返回注册失败，并通知 plugin 注册失败；

(4): 向**actualStateOfWorld**新增一个Plugin.

(5): 调用 `handler.RegisterPlugin` 执行进一步的注册操作.

(6): 调用`og.notifyPlugin` 函数 通知已经该Plugin已经注册完成.

```go
	registerPluginFunc := func() error {
		client, conn, err := dial(socketPath, dialTimeoutDuration)
		if err != nil {
			return fmt.Errorf("RegisterPlugin error -- dial failed at socket %s, err: %v", socketPath, err)
		}
		defer conn.Close()

		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()

		infoResp, err := client.GetInfo(ctx, &registerapi.InfoRequest{})
		if err != nil {
			return fmt.Errorf("RegisterPlugin error -- failed to get plugin info using RPC GetInfo at socket %s, err: %v", socketPath, err)
		}

		handler, ok := pluginHandlers[infoResp.Type]
		if !ok {
			if err := og.notifyPlugin(client, false, fmt.Sprintf("RegisterPlugin error -- no handler registered for plugin type: %s at socket %s", infoResp.Type, socketPath)); err != nil {
				return fmt.Errorf("RegisterPlugin error -- failed to send error at socket %s, err: %v", socketPath, err)
			}
			return fmt.Errorf("RegisterPlugin error -- no handler registered for plugin type: %s at socket %s", infoResp.Type, socketPath)
		}

		if infoResp.Endpoint == "" {
			infoResp.Endpoint = socketPath
		}
		if err := handler.ValidatePlugin(infoResp.Name, infoResp.Endpoint, infoResp.SupportedVersions); err != nil {
			if err = og.notifyPlugin(client, false, fmt.Sprintf("RegisterPlugin error -- plugin validation failed with err: %v", err)); err != nil {
				return fmt.Errorf("RegisterPlugin error -- failed to send error at socket %s, err: %v", socketPath, err)
			}
			return fmt.Errorf("RegisterPlugin error -- pluginHandler.ValidatePluginFunc failed")
		}
		// We add the plugin to the actual state of world cache before calling a plugin consumer's Register handle
		// so that if we receive a delete event during Register Plugin, we can process it as a DeRegister call.
		err = actualStateOfWorldUpdater.AddPlugin(cache.PluginInfo{
			SocketPath: socketPath,
			Timestamp:  timestamp,
			Handler:    handler,
			Name:       infoResp.Name,
		})
		if err != nil {
			klog.ErrorS(err, "RegisterPlugin error -- failed to add plugin", "path", socketPath)
		}
		if err := handler.RegisterPlugin(infoResp.Name, infoResp.Endpoint, infoResp.SupportedVersions); err != nil {
			return og.notifyPlugin(client, false, fmt.Sprintf("RegisterPlugin error -- plugin registration failed with err: %v", err))
		}

		// Notify is called after register to guarantee that even if notify throws an error Register will always be called after validate
		if err := og.notifyPlugin(client, true, ""); err != nil {
			return fmt.Errorf("RegisterPlugin error -- failed to send registration status at socket %s, err: %v", socketPath, err)
		}
		return nil
	}
```

可以看到，从第二步获取到Handler之后,后面所有的操作都是由Handler来处理的. 这里需要解释一下这段代码的背景: `handler, ok := pluginHandlers[infoResp.Type]`.  也就是什么时候把 **pluginHandlers** 里面的数据写入进去的.

```go
	// https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/kubelet/kubelet.go#L1433
	// Adding Registration Callback function for CSI Driver
	kl.pluginManager.AddHandler(pluginwatcherapi.CSIPlugin, plugincache.PluginHandler(csi.PluginHandler))
	// Adding Registration Callback function for Device Manager
	kl.pluginManager.AddHandler(pluginwatcherapi.DevicePlugin, kl.containerManager.GetPluginRegistrationHandler())
```

可以看到 `kl.pluginManager.AddHandler` 是添加一个 Handler 的方法, kubelet 系统中提供了两类插件:

- 一个是 CSI Plugin,参数是: *pluginwatcherapi.CSIPlugin*;
- 另一个是 Device Plugin,参数是: *pluginwatcherapi.DevicePlugin*. 

这里为`CSIPlugin`,  表示注册一个*CSI Plugin* 和处理它的Handler. *plugincache.PluginHandler* 表示一个接口. 这个接口需要实现一下方法: `ValidatePlugin()`, `RegisterPlugin()`, `DeRegisterPlugin()` .

**csi.PluginHandler** 表示是实现了一个*plugincache.PluginHandler* 一个接口的组件.

根据流程, 我们来看一下`handler.RegisterPlugin()` 这个函数:

```go
https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/volume/csi/csi_plugin.go#L111

func (h *RegistrationHandler) RegisterPlugin(pluginName string, endpoint string, versions []string) error {
	klog.Infof(log("Register new plugin with name: %s at endpoint: %s", pluginName, endpoint))
  // 再次验证一下版本
	highestSupportedVersion, err := h.validateVersions("RegisterPlugin", pluginName, endpoint, versions)
	if err != nil {
		return err
	}

	// Storing endpoint of newly registered CSI driver into the map, where CSI driver name will be the key
	// all other CSI components will be able to get the actual socket of CSI drivers by its name.
  // 将CSI 信息放到一个map数据结构中, 供后面实例化 GRPC clinet 使用
	csiDrivers.Set(pluginName, Driver{
		endpoint:                endpoint,
		highestSupportedVersion: highestSupportedVersion,
	})

	// Get node info from the driver.
  // 实例化一个和csi Plugin 通信的Client
	csi, err := newCsiDriverClient(csiDriverName(pluginName))
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), csiTimeout)
	defer cancel()
  // 调用 NodeGetInfo 获取当前Node上的相关信息
	driverNodeID, maxVolumePerNode, accessibleTopology, err := csi.NodeGetInfo(ctx)
	if err != nil {
		if unregErr := unregisterDriver(pluginName); unregErr != nil {
			klog.Error(log("registrationHandler.RegisterPlugin failed to unregister plugin due to previous error: %v", unregErr))
		}
		return err
	}
  // 调用 nim.InstallCSIDriver() 做进一步的注册
	err = nim.InstallCSIDriver(pluginName, driverNodeID, maxVolumePerNode, accessibleTopology)
	if err != nil {
		if unregErr := unregisterDriver(pluginName); unregErr != nil {
			klog.Error(log("registrationHandler.RegisterPlugin failed to unregister plugin due to previous error: %v", unregErr))
		}
		return err
	}

	return nil
}
```

 根据流程, 我们看一下`nim.InstallCSIDriver()`这个函数:

[https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/volume/csi/nodeinfomanager/nodeinfomanager.go#L109](https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/volume/csi/nodeinfomanager/nodeinfomanager.go#L109)

```go
func (nim *nodeInfoManager) InstallCSIDriver(driverName string, driverNodeID string, maxAttachLimit int64, topology map[string]string) error {
	if driverNodeID == "" {
		return fmt.Errorf("error adding CSI driver node info: driverNodeID must not be empty")
	}

	nodeUpdateFuncs := []nodeUpdateFunc{
		updateNodeIDInNode(driverName, driverNodeID),
		updateTopologyLabels(topology),
	}

	err := nim.updateNode(nodeUpdateFuncs...)
	if err != nil {
		return fmt.Errorf("error updating Node object with CSI driver node info: %v", err)
	}

	err = nim.updateCSINode(driverName, driverNodeID, maxAttachLimit, topology)
	if err != nil {
		return fmt.Errorf("error updating CSINode object with CSI driver node info: %v", err)
	}

	return nil
}
```

从源码中可以看出,  该函数主要做了三件事:

- updateNodeIDInNode(): 更新 node 的annotation对象，该函数被调用时会传递该节点的Node对象, 向 node 对象的 annotation 中 key 为`csi.volume.kubernetes.io/nodeid`的值中去增加注册的 plugin 信息。最终的信息如下:

  ```yaml
    annotations:
      csi.volume.kubernetes.io/nodeid: '{"diskplugin.csi.alibabacloud.com":"i-rj957dewp2gadwaobc49","nasplugin.csi.alibabacloud.com":"i-rj957dewp2gadwaobc49","ossplugin.csi.alibabacloud.com":"i-rj957dewp2gadwaobc49"}'
  ```

  

- updateTopologyLabels():  添加 node 的Lable中和Topology有关的对象. Key是: `topology.diskplugin.csi.alibabacloud.com/zone:`  当Node 的Lable 中存在该对象时就更新失败, 只添加 不更改.

- updateCSINode(): 创建或更新 CSINode 对象。

  ```go
  func (nim *nodeInfoManager) tryUpdateCSINode(
  	csiKubeClient clientset.Interface,
  	driverName string,
  	driverNodeID string,
  	maxAttachLimit int64,
  	topology map[string]string) error {
  
  	nodeInfo, err := csiKubeClient.StorageV1().CSINodes().Get(context.TODO(), string(nim.nodeName), metav1.GetOptions{})
  	if nodeInfo == nil || errors.IsNotFound(err) {
  		nodeInfo, err = nim.CreateCSINode()
  	}
  	if err != nil {
  		return err
  	}
  
  	return nim.installDriverToCSINode(nodeInfo, driverName, driverNodeID, maxAttachLimit, topology)
  }
  ```

  所以CSI Node的对象也是在注册CSI Plugin进行创建的.

一个CSI Node 的对象如下:

```go
apiVersion: storage.k8s.io/v1
kind: CSINode
metadata:
  creationTimestamp: "2021-08-30T03:49:49Z"
  name: us-west-1.192.168.107.61
  ownerReferences:
  - apiVersion: v1
    kind: Node
    name: us-west-1.192.168.107.62
    uid: be7dfc9d-79c5-4f24-a8e6-24f66573f350
  resourceVersion: "834161524"
  uid: bccf8b11-0d75-4ebd-ad66-deecda40f5f9
spec:
  drivers:
  - name: ossplugin.csi.alibabacloud.com
    nodeID: i-rj957dewp2gxxxxxxx
    topologyKeys: null
  - name: nasplugin.csi.alibabacloud.com
    nodeID: i-rjda7dewp2gadwaobc49xxx
    topologyKeys: null
  - allocatable:
      count: 15
    name: diskplugin.csi.alibabacloud.com
    nodeID: i-rj957dewxxxxx
    topologyKeys:
    - topology.diskplugin.csi.alibabacloud.com/zone
```

###### UnRegisterPlugin()函数

取消注册的流程和注册的流程大致相同, 这里就不一一列举出来了, 下面是详细的调用链.

`rc.operationExecutor.UnregisterPlugin()` --> `oe.operationGenerator.GenerateUnregisterPluginFunc()`-->`actualStateOfWorldUpdater.RemovePlugin()`--> `pluginInfo.Handler.DeRegisterPlugin()`--> `nim.UninstallCSIDriver()`-->`nim.updateNode()`













