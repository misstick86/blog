在前面介绍了RUNC的基本操作, 但是,在实际中我们不可能将runc这种命令直接交给用户使用. 基于runc我们还有一层shim, 用来代理runc的所有操作.

## runtime 介绍

在官方提供的runtime版本中一共提供了两个,**v1**和**v2**. **v1** 在1.4之后已经不再被使用, 官方也建议使用v2版本.

用官方的话来说, **runtime v2** 是作者为containerd提供的第一类shim api. shim api 表示是最小的并且只限于容器的执行生命周期.

创建一个容器使用的默认是**io.containerd.runc.v2**, 我们可以使用以下参数来改变它.

```shell
> ctr run --runtime io.containerd.runc.v1
```

上面指定的runtime包含了名称和版本, 在运行时将会被转换为shim的二进制名称.

```shell
io.containerd.runc.v1 -> containerd-shim-runc-v1
```

我们可以使用 `ps aux | grep containerd-shim` 命令查看系统中已经运行的shim.

下面, 将通过多个方面介绍一下 *runtime* 的设计.

### Commands

shim 提供容器的信息有两种方式: **OCI Runtime Bundle** 和 **Create RPC request**.

##### start command

每个shim都必须实现 `start` 命令, 者用来启动一个shim. `start` 命令必须接受一下参数:
- `-namespace` 容器的命名空间
- `-address` containerd 主sock的地址
- `-publish-binary` 将事件传回给containerd的地址
- `-id` containerd 的ID

`start` 命令必须向shim 返回一个地址以便 containerd 为容器操作发出 API 请求也可以根据shim的逻辑将地址返回给现有的shim.

##### delete command

每个shim必须实现一个`delete`命令, 这个命令允许containerd删除任何容器创建的资源, 这通常发生在一个容器被SIGKIll. containerd和shim失去联系也会执行该操作. 

`delete` 命令必须接受一下命令:
- `-namespace` 容器的命名空间
- `-address` containerd 的主sock
- `-publish-binary` 介绍事件的containerd二进制路径
- `-id` 容器的id
- `-bundle` 要删除的容器bundle.

在Linux系统上, 运行一个容器所产生的各种资源我们称之为`cwd`.  `start` 和 `delete` 命令都是在其`cwd`下执行的. 对于一个已经创建的容器可以看到包含一下资源:

```shell
➜  ubuntu-10 ls
address  config.json  init.pid  log  log.json  options.json  rootfs  runtime  work
```

## Config

shim 不提供主机级别的配置但提供了容器级别的配置.

在create请求时, `protobuf` 定义了一个通用的类型允许用户来自定义配置. 这个客户就可以使用.

```go
message CreateTaskRequest {
	string id = 1;
	...
	google.protobuf.Any options = 10;
}
```

#### IO config

容器的I/O 是由客户端同过Linux的fifo, windows上的pipe或者磁盘的log文件提供给shim的.  这些文件在路径在**create**或者**exec**初始化时提供.

```go
message CreateTaskRequest {
	string id = 1;
	bool terminal = 4;
	string stdin = 5;
	string stdout = 6;
	string stderr = 7;
}
```

```go
message ExecProcessRequest {
	string id = 1;
	string exec_id = 2;
	bool terminal = 3;
	string stdin = 4;
	string stdout = 5;
	string stderr = 6;
}
```

终端的交互可以同过配置文件中将 `terminal` 字段设置为`true`, 数据是以非交互方式同过`fifo`, `pipe` 进行复制.

#### root filesystem

容器的`root filesystem` 由`create` rpc提供. shim的职责是在容器的生命周期内管理`mount`的生命周期.

```go
message CreateTaskRequest {
	string id = 1;
	string bundle = 2;
	repeated containerd.types.Mount rootfs = 3;
	...
}
```

Mount 的 protbuf 定义如下:

```go
message Mount {
	// Type defines the nature of the mount.
	string type = 1;
	// Source specifies the name of the mount. Depending on mount type, this
	// may be a volume name or a host path, or even ignored.
	string source = 2;
	// Target path in container
	string target = 3;
	// Options specifies zero or more fstab style mount options.
	repeated string options = 4;
}
```

shim 负责将*bundle*的 rootfs 挂载、卸载到目录中. 

#### Event

`runtime v2` 支持异步事件模型. 为了让上游调用者(如: docker)以正确的顺序获取这些事件, `runtime v2` 必须实现那些`Compliance=MUST` 的事件. 这避免了 shim 和 shim 客户端之间的竞争条件. 例如: 对 Start 的调用可以在返回 Start 调用的结果之前发出 TaskExitEventTopic 信号。有了 Runtime v2 shim 的这些保证，需要调用 Start 来发布异步事件 TaskStartEventTopic，然后 shim 才能发布 TaskExitEventTopic。

**task**

Topic | Complince | Description
------------ | ------------ | ------------
`runtime.TaskCreateEventTopic` | Must | task 成功创建
`runtime.TaskStartEventTopic`|MUST (follow `TaskCreateEventTopic`)|task 成功启动
`runtime.TaskExitEventTopic`| MUST (follow `TaskStartEventTopic`)| task 退出
`runtime.TaskDeleteEventTopic` | MUST (follow `TaskExitEventTopic`  or `TaskCreateEventTopic` if never started) | 从shim中删除一个task
`runtime.TaskPausedEventTopic` | SHOULD | task 被暂停
`runtime.TaskResumedEventTopic` | SHOULD (follow `TaskPausedEventTopic`) |  Task 被恢复
`runtime.TaskCheckpointedEventTopic` | SHOULD | Task 被checkpoint
`runtime.TaskOOMEventTopic` | SHOULD | Task 发生OOM


**Execs**

Topic | Complince | Description
------------ | ------------ | ------------
`runtime.TaskExecAddedEventTopic` | MUST (follow `TaskCreateEventTopic` ) | 执行exec操作
`runtime.TaskExecStartedEventTopic` | MUST (follow `TaskExecAddedEventTopic`)| 启动exec 操作
`runtime.TaskExitEventTopic` | MUST (follow `TaskExecStartedEventTopic`) | exec 操作退出
`runtime.TaskDeleteEventTopic` | SHOULD (follow `TaskExitEventTopic` or `TaskExecAddedEventTopic` if never started) | 当exec操作被删除

#### logging

shim 也可以同过 log url 的方式支持插件, 当前支持的方案如下:

- fifo: linux
- binary: linux & windows
- file: linux & windows
- npipe: windows

