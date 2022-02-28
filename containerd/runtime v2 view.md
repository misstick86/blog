上一篇介绍了`runtime v2`的设计实现, 但最终的产物是我们的系统同存在一个`containerd-shim-runc-v2`的可执行文件,  对于 **containerd** 来说我们需要一个封装了的上述可执行文件的函数实现来调用这个命令.

使用 *bcc* 工具包的*execsnoop* 可以查看系统中的命令调用, 一下是执行*ctr run* 后系统中的命令执行结果.

```shell
sudo             26794  26776    0 /usr/bin/sudo ctr run -d --cpu-quota 20000 docker.io/library/ubuntu:21.04 ubuntu-1
ctr              26795  26794    0 /usr/bin/ctr run -d --cpu-quota 20000 docker.io/library/ubuntu:21.04 ubuntu-1
containerd-shim  26805  26688    0 /usr/bin/containerd-shim-runc-v2 -namespace default -address /run/containerd/containerd.sock -publish-binary /usr/bin/containerd -id ubuntu-1 start
containerd-shim  26813  26805    0 /usr/bin/containerd-shim-runc-v2 -namespace default -id ubuntu-1 -address /run/containerd/containerd.sock
runc             26823  26813    0 /usr/local/sbin/runc --root /run/containerd/runc/default --log /run/containerd/io.containerd.runtime.v2.task/default/ubuntu-1/log.json --log-format json create --bundle /run/containerd/io.containerd.runtime.v2.task/default/ubuntu-1 --pid-file /run/containerd/io.containerd.runtime.v2.task/default/ubuntu-1/init.pid ubuntu-1
exe              26830  26823    0 /proc/self/exe init
runc             26840  26813    0 /usr/local/sbin/runc --root /run/containerd/runc/default --log /run/containerd/io.containerd.runtime.v2.task/default/ubuntu-1/log.json --log-format json start ubuntu-1
bash             26833  26813    0 /usr/bin/bash
```

> bcc 工具包 : [https://github.com/iovisor/bcc/blob/master/tools/execsnoop.py](https://github.com/iovisor/bcc/blob/master/tools/execsnoop.py)

让我们简单梳理一下上面的调用流程:

1. 用户使用 `ctr run` 来启动一个容器.
2. `containerd` 接受后调用系统中的 `containerd-shim-runc-v2` 命令启动一个shim. 启动的命令后面会加上`start` 参数.
3. 再次调用 `containerd-shim-runc-v2` 命令这次是不加上`start`参数.
4. 调用`runc`命令创建创建一个容器, 命令为: `runc xxx create xxx name`
5. 执行`runc init` 命令.
6. 执行`runc start` 命令启动一个容器.

从上面的流程可以看到, containerd 需要负责执行**containerd-shim-runc-v2**命令.  而实际上每个runtime都实现了对应的封装. 具体的源码分析可以参考: [runtime manager](./runtime-manager.md)