介绍Plugin的时候就说过containerd中的大多数组件都是以插件的形式注册到系统中的, `runtime`也不列外.  从导入包的路径可以看出它的*init*函数路径.

```go
import (
	_ "github.com/containerd/containerd/runtime/v2"
)
```

*runtime* 注册执行的init 函数如下:

[https://github.com/containerd/containerd/blob/main/runtime/v2/manager.go#L50](
https://github.com/containerd/containerd/blob/main/runtime/v2/manager.go#L50)

和其他Plugin类似,  验证依赖的上层插件是否注册,然后返回这个插件的主入口.

## Task Manger

`Init`函数的返回是一个**TaskManager**的结构体,  **TaskManager** 是一个管理`runtime`整个生命周期的实例, 一般我们称之为一个Task.  它定义了一些接口:

```go
type PlatformRuntime interface {
	// ID of the runtime
	ID() string
	// Create creates a task with the provided id and options.
	Create(ctx context.Context, taskID string, opts CreateOpts) (Task, error)
	// Get returns a task.
	Get(ctx context.Context, taskID string) (Task, error)
	// Tasks returns all the current tasks for the runtime.
	// Any container runs at most one task at a time.
	Tasks(ctx context.Context, all bool) ([]Task, error)
	// Delete remove a task.
	Delete(ctx context.Context, taskID string) (*Exit, error)
}
```

Task Manger的结构体如下:

```go
// Task Manger 间接上也是封装了shim Manger的client端.
type TaskManager struct {
	manager *ShimManager
}
```

## Shim Manger

shim Manger 是一个container shim 的实际管理器,  shim manger主要是启动一个shim并清理已经退出实例的资源, 它只对上层提供消费而不关心下层的服务.

Shim Manger定义的结构体如下:

```go
type ShimManager struct {  
 root string  
 state string  
 containerdAddress string  
 containerdTTRPCAddress string  
 schedCore bool  
 shims *runtime.TaskList  
 events *exchange.Exchange  
 containers containers.Store  
 // runtimePaths is a cache of `runtime names` -> `resolved fs path` runtimePaths sync.Map  
}
```

从某种意义上来说, Shim Manger只是**containerd-shim-runc-v2** 这个可执行文件的二进制封装和管理.  其中, 较为主要的接口函数是**Create** 和 **Delete**.

这里介绍一下**create**函数的实现:

1. 创建一个bundle的实例, 包括初始化各种目录
2. 启动一个shim实例, 也就是执行`containerd-shim-runc-v2 xx start` 命令, 这一步会根据指定的runtime翻译成系统中存在的二进制文件. 
3. 封装一个ShimTask结构,  这个结构体包含当前的shim和一个Task Service的客户端.
4. 将当前 shim Task 添加到shim 列表中.

## Shim And ShimTask

shim和shimTask本质上没有什么区别,  可以认为Shim Task 是shim的一种包含ttrpc客户端的扩展. shim 和 ShimTask 的结构体如下:

```go
type shim struct {
	bundle *Bundle
	client *ttrpc.Client
}
```

```go
type shimTask struct {
	*shim
	task task.TaskService
}
```

shim结构体的初始化是在调用`containerd-shim-runc-v2` 启动之后, 根据输出我们可以获取到当前shim的ttrpc地址, 之后便在这个*start* 函数完成shim结构的赋值并返回.

shimTask比shim多一个关于ttrpc的结构, 在shim里面我们拿到了关于 ttrpc client 的信息, 在shim Manger里面我们在将其复制到ShimTask里面.

ShimTask实际上还是一个ttrpc客户端的客户端,  对于每个启动的 shim 或者说是container实例, 都会启动一个ttrpc服务, 同过此种方式来管理这个容器.  关于shim task的接口定义如下:

[https://github.com/containerd/containerd/blob/main/runtime/task.go#L63](https://github.com/containerd/containerd/blob/main/runtime/task.go#L63)

从shim Manger的源码可以看出现在已经启动了一个shim,  之后便是同过shim调用它的**Create**方法,  而这个**Create**其实只可以ttrpc的客户端,最终由ttrpc的服务端来完成.