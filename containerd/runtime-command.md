在 containerd 的release包中我们可以看到包含着一个**containerd-shim-runc-v2**的二进制文件,  它是启动一个shim的核心, 这篇文件将介绍它的源码和执行 `containerd-shim-runc-v2 xx start` 命令的过程.

##  启动
```shell
➜  ~ containerd-shim-runc-v2 --help
Usage of containerd-shim-runc-v2:
  -address string
    	grpc address back to main containerd
  -bundle string
    	path to the bundle if not workdir
  -debug
    	enable debug output in logs
  -id string
    	id of the task
  -namespace string
    	namespace that owns the shim
  -publish-binary string
    	path to publish binary (used for publishing events) (default "containerd")
  -socket string
    	socket path to serve
  -v	show the shim version and exit
```

`containerd-shim-runc-v2` 命令在main文件中比较简单, 如下:

```go
shim.RunManager(context.Background(), manager.NewShimManager("io.containerd.runc.v2"))
```

**RunManager** 是初始化和运行一个shim server. 实际的调用是**run** 函数解析.  

首先, 会解析命令行传递过来的执行参数, 之后从环境变量里面获取到对应的**ttrpcAddress**地址, 这个地址在runtime manger 的 `start` 方法中调用这个命令时传递进来.

根据传递的 **action**  会解析对步骤,  这里我们以*start*参数为例.

## start command

start 命令调用shim manager的**Start**方法,   这个方法会再一次封装`containerd-shim-runc-v2`的命令,不过这次不在添加任何的启动命令.

- `newcommand` 函数封装出对应的**containerd-shim-runc-v2** 命令,添加了*namesapce*, *id*, *address* 参数.
- 读取 *config.json* 文件, 来获取grouping数据.
- 封装当前的container shim地址, 格式为: `unix:///run/containerd/s/+md5`并根据地址实例化一个socket文件.
- 将这个地址写入到容器根目录的address文件
- 调用*cmd.start()* 启动这个命令.
- 根据输出结果设置一下cgroups的参数并调整一下OOM的值.

start 命令做的事情就是在执行一次 **containerd-shim-runc-v2** 这个命令, 不过这次将不带任何的参数. 

不带任何action的命令执行入口还是 **run** 函数.

[https://github.com/containerd/containerd/blob/main/runtime/v2/shim/shim.go#L342](https://github.com/containerd/containerd/blob/main/runtime/v2/shim/shim.go#L342)

从代码中我们可以看出,  主要是创建一个ttrpc服务. 但这个ttrpc的服务时同过Plugin的方实现的, 我们可以在`containerd-shim-runc-v2` 的`main`函数中看到它注册了一个type为**io.containerd.ttrpc.v1**的插件. 

**io.containerd.ttrpc.v1** 的插件依赖于和*Event* 和 *Internal* 两个插件, 所以在代码的开头会先注册这个插件. 我们简单梳理一下这个流程:

1.  注册*Event* 和 *Internal* 两个插件, 为*ttrpc*插件使用.
2.  遍历插件, 执行每个插件的 init 函数.
3.  实例化一个ttrpc服务(server)
4.  注册ttrpc
5.  启动ttrpc服务

每个启动的shim 都自带一个ttrpc的服务, 这个服务管理这整个容器的生命周期, 如容器的创建, 启动, 删除.

实现上述ttrpc的服务端接口是task service结构体.

[https://github.com/containerd/containerd/blob/main/runtime/v2/runc/task/service.go#L102](https://github.com/containerd/containerd/blob/main/runtime/v2/runc/task/service.go#L102)

## Delete command

start 命令表示启动一个shim, 与之对应的就是delete,或者是stop停止一个shim.  这里先暂时不介绍.





