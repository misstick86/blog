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

