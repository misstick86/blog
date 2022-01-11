对于containerd的使用者来说我们可以用ctr快速的测试新功能特性和学习. containerd也提供一个面向编程的API, 开发者可以很方便的在项目中集成containerd. 

这篇文章我们将介绍通过使用containerd的client api在Ubuntu服务器上启动一个containerd容器, 这包括拉取镜像(pull image)、创建容器(create container)、创建task(create task)等操作.

## 前期准备

- 一台Ubuntu服务器, 并且已经安装了go环境; 
- 该服务器已经配置好containerd服务,并启动.

## 连接containerd服务

containerd服务是通过grpc向外部暴露自己的服务, 默认containerd会创建一个`/run/containerd/containerd.sock` unix sock,然而官方也封装了一堆函数以方便调用者使用.  如下是连接containerd的客户端代码.

```go
package main

import (
        "github.com/containerd/containerd"
)

func main() {
        client, err := containerd.New("/run/containerd/containerd.sock")
        if err != nil {
                return err
        }
        defer client.Close()
}
```

以上,我们同过默认的unix sock 文件创建一个containerd client. 还需要为此创建一个context用于和containerd的GRPC交互. Containerd为每个客户端调用者还提供namespace, 这样可以确保调用在使用容器,镜像等资源时避免发生冲突.

```go
ctx := namespaces.WithNamespace(context.Background(), "demo")
```

## 拉取镜像

我们可以使用这个客户端对象从一个hub上拉取镜像, 以下是拉取一个`redis`镜像的操作.

```go
	image, err := client.Pull(ctx, "docker.io/library/redis:5.0", containerd.WithPullUnpack)
	if err != nil {
		return err
	}
```

client对象的很多操作都是同过Opts模式参数参数, 这里传递一个`containerd.WithPullUnpack`参数表示将镜像下载到 *content store*里面并解压到 *snapshotter* 中以作为rootfs.

代码如下:

```go
func main() {
        client, err := containerd.New("/run/containerd/containerd.sock")
        if err != nil {
                panic(err)
        }
        ctx := namespaces.WithNamespace(context.Background(), "demo")
        image, err := client.Pull(ctx, "docker.io/library/redis:5.0", containerd.WithPullUnpack)
        if err != nil {
                panic(err)
        }
        log.Printf("Successfully pulled %s image\n", image.Name())
        defer client.Close()
}
```

 ```shell
 ➜  containerd-demo go mod init containerd-demo
 ➜  containerd-demo go mod tidy
 ➜  containerd-demo go build demo.go
 ➜  containerd-demo ./demo
 2022/01/11 16:23:06 Successfully pulled docker.io/library/redis:5.0 image
 #  ctr 命令也可以查看到
 ➜  containerd-demo ctr -n demo i ls -q
 docker.io/library/redis:5.0
 ```

## 创建容器

在基于上面的镜像我们可以创建一个redis容器, 我们需要可以生成一个OCI的运行规范,containerd根据这个规范来创建一个新的容器. OCI规范有一个默认值,containerd根据 *Opts* 参数来修改这个默认值. 如下是一个创建容器的代码:

````go
        container, err := client.NewContainer(
                ctx,
                "redis-server",
                containerd.WithNewSnapshot("redis-server-snapshot", image),
                containerd.WithNewSpec(oci.WithImageConfig(image)),
            )
        if err != nil {
                panic(err)
        }
````

*containerOpts* 提供一个可以使用自己的spec方法: `containerd.WithSpec(spec)` 设置自定的containerd.

```go
➜  containerd-demo ./demo
2022/01/11 16:50:57 Successfully pulled docker.io/library/redis:5.0 image
2022/01/11 16:50:57 Successfully created container with ID redis-server and snapshot with ID redis-server-snapshot
```

函数在结束时我们删除了容器，这里就不使用ctr验证了, 后面会验证.

## 创建TASK

对于用户来说,一开始应该对container 和 task 有点困惑.container是一个容器附加资源的元信息对象, Task是存在系统上的运行进程. Task在进程结束后需要销毁,而Containerk可以被重用和多次更新.

```go
task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
	if err != nil {
		return err
	}
	defer task.Delete(ctx)
```

以上便创建了一个Task,当Task运行起来便是系统的一个进程. 并且使用`cio.WithStdio` 将所有的容器io发送到我们的**demo**进程中.

如果你了解OCI的机制,当前的Task是处于"Create"状态. 这就意味着这个进程的*namespace*, *rootfs* 和容器级别的配置并已经初始化,但并没有启动. 此时用户还可以配置task的网络和使用一些工具来监控Task. 如果你配置*metrics*的地址, 此时可以同过一下命令查看:

```shell
curl 127.0.0.1:1338/v1/metrics
```

## 启动TASK

启动task的是*task.Start()*函数,  但在启动task之前,我们必须使用*task.Wait()*函数来等待task的退出.

```go
exitStatusC, err := task.Wait(ctx)
	if err != nil {
		return err
	}

	if err := task.Start(ctx); err != nil {
		return err
	}
```

## STOP TASk

官方的称呼为`kill TASK`, 我们使用`task.Kill()`函数可以杀掉一个容器.

```go
	time.Sleep(3 * time.Second)

	if err := task.Kill(ctx, syscall.SIGTERM); err != nil {
		return err
	}

	status := <-exitStatusC
	code, exitedAt, err := status.Result()
	if err != nil {
		return err
	}
	fmt.Printf("redis-server exited with status: %d\n", code)
```

以下是所有代码, 在Task 启动后我们要sleep 200s， 以方便我们验证.

```go
import (
        "fmt"
        "github.com/containerd/containerd/cio"
        "github.com/containerd/containerd/oci"
        "log"
        "context"
        "github.com/containerd/containerd"
        "github.com/containerd/containerd/namespaces"
        "syscall"
        "time"
)

func main() {
        client, err := containerd.New("/run/containerd/containerd.sock")
        if err != nil {
                panic(err)
        }
        defer client.Close()
        ctx := namespaces.WithNamespace(context.Background(), "demo")
        image, err := client.Pull(ctx, "docker.io/library/redis:5.0", containerd.WithPullUnpack)
        if err != nil {
                panic(err)
        }
        log.Printf("Successfully pulled %s image\n", image.Name())
        container, err := client.NewContainer(
                ctx,
                "redis-server",
                containerd.WithNewSnapshot("redis-server-snapshot", image),
                containerd.WithNewSpec(oci.WithImageConfig(image)),
            )
        if err != nil {
                panic(err)
        }
        defer container.Delete(ctx, containerd.WithSnapshotCleanup)
        log.Printf("Successfully created container with ID %s and snapshot with ID redis-server-snapshot", container.ID())

        task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
            if err != nil {
                panic(err)
            }
	    defer task.Delete(ctx)

        log.Printf("Successfully created task with ID %s and pid is: %d", task.ID(), task.Pid())

        exitStatusC, err := task.Wait(ctx)
        if err != nil {
                fmt.Println(err)
        }

        if err := task.Start(ctx); err != nil {
		        panic(err)
	     }
        log.Printf("Successfully start task ..")
        time.Sleep(200 * time.Second)

        if err := task.Kill(ctx, syscall.SIGTERM); err != nil {
               panic(err)
        }

        status := <-exitStatusC
        code, _, err := status.Result()
        if err != nil {
                panic(err)
        }
        fmt.Printf("redis-server exited with status: %d\n", code)
        
}
```



```shell
➜  containerd-demo ./demo
2022/01/11 17:32:09 Successfully pulled docker.io/library/redis:5.0 image
2022/01/11 17:32:09 Successfully created container with ID redis-server and snapshot with ID redis-server-snapshot
2022/01/11 17:32:10 Successfully created task with ID redis-server and pid is: 28478
2022/01/11 17:32:10 Successfully start task ..
1:C 11 Jan 2022 09:32:10.593 # oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
1:C 11 Jan 2022 09:32:10.593 # Redis version=5.0.14, bits=64, commit=00000000, modified=0, pid=1, just started
1:C 11 Jan 2022 09:32:10.593 # Warning: no config file specified, using the default config. In order to specify a config file use redis-server /path/to/redis.conf
1:M 11 Jan 2022 09:32:10.594 # You requested maxclients of 10000 requiring at least 10032 max file descriptors.
1:M 11 Jan 2022 09:32:10.594 # Server can't set maximum open files to 10032 because of OS error: Operation not permitted.
1:M 11 Jan 2022 09:32:10.594 # Current maximum open files is 1024. maxclients has been reduced to 992 to compensate for low ulimit. If you need higher maxclients increase 'ulimit -n'.
1:M 11 Jan 2022 09:32:10.600 * Running mode=standalone, port=6379.
1:M 11 Jan 2022 09:32:10.600 # WARNING: The TCP backlog setting of 511 cannot be enforced because /proc/sys/net/core/somaxconn is set to the lower value of 128.
1:M 11 Jan 2022 09:32:10.600 # Server initialized
1:M 11 Jan 2022 09:32:10.600 # WARNING overcommit_memory is set to 0! Background save may fail under low memory condition. To fix this issue add 'vm.overcommit_memory = 1' to /etc/sysctl.conf and then reboot or run the command 'sysctl vm.overcommit_memory=1' for this to take effect.
1:M 11 Jan 2022 09:32:10.600 # WARNING you have Transparent Huge Pages (THP) support enabled in your kernel. This will create latency and memory usage issues with Redis. To fix this issue run the command 'echo never > /sys/kernel/mm/transparent_hugepage/enabled' as root, and add it to your /etc/rc.local in order to retain the setting after a reboot. Redis must be restarted after THP is disabled.
1:M 11 Jan 2022 09:32:10.601 * Ready to accept connections

# 打开另一个终端使用ctr验证 container 和 task 都已经创建
➜  ~ ctr -n demo container ls
CONTAINER       IMAGE                          RUNTIME
redis-server    docker.io/library/redis:5.0    io.containerd.runc.v2

➜  ~ ctr -n demo task ls
TASK            PID      STATUS
redis-server    28478    RUNNING
```

