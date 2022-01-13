##  Plugin 介绍
containerd 所有组件都是同过Plugin的方式注册到主程序的, 还允许你使用定义的多个接口进行扩展, 这包括自定义的runtime, snapshotter,content store, 甚至GRPC接口.

在containerd启动的时候, 从日志可以看到加载的很多Plugin.  同过这些插件containerd确保了内部的实现是稳定和解耦的. 可以使用一下命令查看Plugin的状态.

```shell
➜  ~ ctr plugins ls
TYPE                            ID                       PLATFORMS      STATUS
io.containerd.content.v1        content                  -              ok
io.containerd.snapshotter.v1    aufs                     linux/amd64    ok
io.containerd.snapshotter.v1    btrfs                    linux/amd64    skip
io.containerd.snapshotter.v1    devmapper                linux/amd64    error
io.containerd.snapshotter.v1    native                   linux/amd64    ok
io.containerd.snapshotter.v1    overlayfs                linux/amd64    ok
io.containerd.snapshotter.v1    zfs                      linux/amd64    skip
io.containerd.metadata.v1       bolt                     -              ok
io.containerd.differ.v1         walking                  linux/amd64    ok
io.containerd.gc.v1             scheduler                -              ok
io.containerd.service.v1        introspection-service    -              ok
io.containerd.service.v1        containers-service       -              ok
io.containerd.service.v1        content-service          -              ok
io.containerd.service.v1        diff-service             -              ok
io.containerd.service.v1        images-service           -              ok
io.containerd.service.v1        leases-service           -              ok
io.containerd.service.v1        namespaces-service       -              ok
io.containerd.service.v1        snapshots-service        -              ok
io.containerd.runtime.v1        linux                    linux/amd64    ok
io.containerd.runtime.v2        task                     linux/amd64    ok
io.containerd.monitor.v1        cgroups                  linux/amd64    ok
io.containerd.service.v1        tasks-service            -              ok
io.containerd.internal.v1       restart                  -              ok
io.containerd.grpc.v1           containers               -              ok
io.containerd.grpc.v1           content                  -              ok
io.containerd.grpc.v1           diff                     -              ok
io.containerd.grpc.v1           events                   -              ok
io.containerd.grpc.v1           healthcheck              -              ok
io.containerd.grpc.v1           images                   -              ok
io.containerd.grpc.v1           leases                   -              ok
io.containerd.grpc.v1           namespaces               -              ok
io.containerd.internal.v1       opt                      -              ok
io.containerd.grpc.v1           snapshots                -              ok
io.containerd.grpc.v1           tasks                    -              ok
io.containerd.grpc.v1           version                  -              ok
io.containerd.grpc.v1           cri                      linux/amd64    ok
```

以上可以看到 **devmapper** 在当前系统上并不支持, 如果想查看详细的错误信息,可以使用以下命令:

```shell
➜  ~ ctr plugins ls -d id==zfs id==devmapper id==btrfs
Type:          io.containerd.snapshotter.v1
ID:            btrfs
Platforms:     linux/amd64
Exports:
               root      /var/lib/containerd/io.containerd.snapshotter.v1.btrfs
Error:
               Code:        Unknown
               Message:     path /var/lib/containerd/io.containerd.snapshotter.v1.btrfs (ext4) must be a btrfs filesystem to be used with the btrfs snapshotter: skip plugin

Type:          io.containerd.snapshotter.v1
ID:            devmapper
Platforms:     linux/amd64
Error:
               Code:        Unknown
               Message:     devmapper not configured

Type:          io.containerd.snapshotter.v1
ID:            zfs
Platforms:     linux/amd64
Exports:
               root      /var/lib/containerd/io.containerd.snapshotter.v1.zfs
Error:
               Code:        Unknown
               Message:     path /var/lib/containerd/io.containerd.snapshotter.v1.zfs must be a zfs filesystem to be used with the zfs snapshotter: skip plugin
```
在containerd的配置文件中, Plugin相关的配置参数是在*plugin*段的. 每个Plugin都可以在
**[plugins\.\<plugin id\>]** 下配置.
```yaml
[plugins]

  [plugins."io.containerd.gc.v1.scheduler"]
    deletion_threshold = 0
    mutation_threshold = 100
    pause_threshold = 0.02
    schedule_delay = "0s"
    startup_delay = "100ms"
```

以上, 这种集成在containerd源码内部的Plugin一般称之为内部插件,  containerd 还支持一种外部插件, 外部插件可以扩展当前containerd的功能,而不需要重新编译containerd.

目前, containerd支持两个方式集成外部插件:
-  同过containerd path 中的一个二进制文件
-  配置containerd代理另一个GRPC服务

代理插件的配置在containerd的配置中 **[proxy_plugins]** 字段. 这些插件同过一个本地的unix sock 文件和containerd通信. 每个插件的类型和名称的配置和内部插件一样. 以下是一个proxy plugins 的配置示例:
```yaml
[proxy_plugins]
  [proxy_plugins.customsnapshot]
    type = "snapshot"
    address = "/var/run/mysnapshotter.sock"
```

`type`  字段目前只支持*snapshot* 和 *content*.
`address` 字段必须是一个本地的 socket 文件, 并且containerd有权限访问.

实现一个外部插件就像实现一个GRPC服务一样, 下面是一个简单的demo, 使用自定义 snapshot api.

```go
package main

import (
	"fmt"
	"net"
	"os"

	"google.golang.org/grpc"

	snapshotsapi "github.com/containerd/containerd/api/services/snapshots/v1"
	"github.com/containerd/containerd/contrib/snapshotservice"
	"github.com/containerd/containerd/snapshots/native"
)

func main() {
	// Provide a unix address to listen to, this will be the `address`
	// in the `proxy_plugin` configuration.
	// The root will be used to store the snapshots.
	if len(os.Args) < 3 {
		fmt.Printf("invalid args: usage: %s <unix addr> <root>\n", os.Args[0])
		os.Exit(1)
	}

	// Create a gRPC server
	rpc := grpc.NewServer()

	// 这里我们还是使用原始的Snapshotter, 只是改变了默认的存储路径
	sn, err := native.NewSnapshotter(os.Args[2])
	if err != nil {
		fmt.Printf("error: %v\n", err)
		os.Exit(1)
	}

	// 将 snapshotter 转换为一个 gRPC service,
	// example in github.com/containerd/containerd/contrib/snapshotservice
	service := snapshotservice.FromSnapshotter(sn)

	// Register the service with the gRPC server
	snapshotsapi.RegisterSnapshotsServer(rpc, service)

	// Listen and serve
	l, err := net.Listen("unix", os.Args[1])
	if err != nil {
		fmt.Printf("error: %v\n", err)
		os.Exit(1)
	}
	if err := rpc.Serve(l); err != nil {
		fmt.Printf("error: %v\n", err)
		os.Exit(1)
	}
}
```

一下是关于自定义插件的测试:

```shell
# 启动自定义的插件
➜  custom-plugin go build demo.go
➜  custom-plugin ./demo /var/run/mysnapshotter.sock /tmp/snapshots

# 另开一个终端
➜  ~ CONTAINERD_SNAPSHOTTER=customsnapshot ctr images pull docker.io/library/alpine:latest
➜  ~ tree -L 3 /tmp/snapshots
/tmp/snapshots
|-- metadata.db
`-- snapshots
    `-- 1
        |-- bin
        |-- dev
        |-- etc
        |-- home
        |-- lib
        |-- media
        |-- mnt
        |-- opt
        |-- proc
        |-- root
        |-- run
        |-- sbin
        |-- srv
        |-- sys
        |-- tmp
        |-- usr
        `-- var
```

