这边文章将根据源码介绍 *runtime* 中包含的组件和涉及的结构体.  此外我们也将根据创建一个容器的操作来梳理一下整个流程.

containerd中将创建runc容器的概念转换为 **container** 和 **Task**, 我们首先要创建一个**Container**, 然后再启动一个**Task**, 涉及的命令分别如下:

```
➜  ~ ctr c create  docker.io/library/ubuntu:21.04  ubuntu-20
➜  ~ ctr t start ubuntu-20
```

其中创建container部分和runtime没有什么太大关系,只是在container的元信息存储中写入要创建的容器信息也就是metadata数据.

`ctr t start` 用来启动一个task 容器, 这里会包含两个阶段,分别为创建一个task和启动一个task.

[https://github.com/containerd/containerd/blob/main/cmd/ctr/commands/tasks/start.go#L93](https://github.com/containerd/containerd/blob/main/cmd/ctr/commands/tasks/start.go#L93)

对于这个两个操作分别对应Task RPC 服务端的**Create**, **Start**方法.

[https://github.com/containerd/containerd/blob/main/services/tasks/local.go#L156](https://github.com/containerd/containerd/blob/main/services/tasks/local.go#L156)

## Create Requets

对于上面Task的**Create**方法, 它是containerd的grpc服务端的实现, 但对于runtime来说它又是客户端, 它会根据设置的 runtime 来选择对应的shim实现, 默认是`io.containerd.runc.v2`.

**create** 函数做的事情也比较简单,根据传递过来的参数封装**runc**的请求参数, 也就是**CreateOpts**.  然后再根据定义的runtime获取到runtime实例.  

从代码可以看到获取获取runtime的shim实例是同过一个map数据结构中获得的, 这也就是说在task plugin启动之初就已经将系统中所有支持的 runtime 注册时进来.

```go
  // 获取plugin的runtime
  rtime, err := l.getRuntime(container.Runtime.Name)
```

```go
  // 获取所有的runtime
  https://github.com/containerd/containerd/blob/main/services/tasks/local_unix.go#L38
```

在介绍shim和shim Task 时,  我们介绍了启动了一个shim的过程, 这是由*Task Manager* 的create函数, 而对于containerd Task 来说, 它获取到对应的runtime后便调用对应runtime的*create*函数.

这个函数主要做了两个两个事情:

1. 创建shim, 这个也就是我们之前说的[runtime-command](../runtime-command.md)的start command.
2. 封装create request 请求, 向第一步启动的ttrpc服务发送create请求.

封装create请求的比较简单,这个就不简单介绍了, 我们介绍一下服务端接受到create请求后要做的事情.

[https://github.com/containerd/containerd/blob/main/runtime/v2/shim.go#L325](https://github.com/containerd/containerd/blob/main/runtime/v2/shim.go#L325)

## Task Service

从包的组织结构上来看,Task service更像是runc的ttrpc服务端,  而shim则是ttrpc的客户端.  Task Service也是以Plugin的方式在 *container-shim-runc-v2* 编译时注册到插件系统的中, 它调用的是 *NewTaskService* 这个函数.

**TaskService**提供实现了很多的接口, 这里我们主要看一下**create**, **start**, **Delete**函数.

- **create** : 表示创建一个runc容器.
- **start** : 表示启动一个已经创建好的runc容器
- **delete**:  表示删除一个runc容器和终止它的init进程.

到目前为止, 后面更多则是和runc命名的交互, 上面的那些命令本质上来说也是对**runc create**, **runc start**, **runc delete**的二次封装而已.

#### Create

create方法的实际工作是由**NewContainer** 这个函数完成的,  该函数会在内部初始化一个init结构体, 这个结构体的主要作用是容器中init进程的一个表述, 它也包含着要创建的runc结构. 之后会调用init结构体实现的Create方法, 这个Create方法便是根据配置调用**runc create**命令. 

值得注意的是**runc**的所有命令都封装到了[go-runc](https://github.com/containerd/go-runc) 这个项目里面.

以上函数的调用流程如下: `NewContainer()` --> `p = NewInit()` --> `p.create()` --> `go-runc.Create()` --> `runc create command`.

#### Start

start 函数的最终目的也是执行`runc start` 命令,  不过在内部将已经Create的进程定义了几种状态: `createdState`, `runningState`, `pausedState`, `stoppedState`,`createdCheckpointState`. 这些状态之间可以相互转换, 如当前的start其实就是下将`createdState` 装换为 `runningState`. 

```go
func (s *createdState) Start(ctx context.Context) error {
	if err := s.p.start(ctx); err != nil {
		return err
	}
	return s.transition("running")
}
```

#### Delete

delete 的操作就比较简单, 就是根据进程的状态调用`Delete`方法, 实际都是执行`runc delete` 命令.