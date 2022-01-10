

从 kubernets1.20 版本开始社区一直在推进 Dockershim 从 kubelet 的主干代码里面移除,  并且在 2021.12 月份时kubernetes官方发起一个投票来统计使用者对其移除的了解程度和反馈.  从官方文档上来看, Kubernetes 社区的计划是在1.24版本开始移除，并完全采用CRI的方式和容器组件进行交互. 

目前各大云厂商已经开始提供containerd作为容器运行时,  了解 containerd 对于容器使用者是一个必要的技能.

## Containerd 概念

 Containerd 是 CNCF 已经毕业的项目.

Containerd是行业标准的运行时, 它强调简单性、健壮性和可移植性.  它可以管理单机中的整个容器生命周期, 包括: 镜像下载和存储, 容器的执行和监控, 附加网络等功能.  并且在设计上, containerd 目标是嵌入到大型的系统中, 并不是像Docker那样面上最终用户使用.

Containerd的整体架构图如下:

![Containerd](/Users/edianyun/code/my_blog/static/images/containrd/architecture.png)

## 部署和运维

Containerd是一个简单的守护进程,它可以运行在任何系统之上.  并且还提供一个简单的配置文件以方便用户有选择的启用或者禁用某个组件. 默认文件的路劲在 `/etc/containerd/config.toml` , 可以在守护进程中使用`-c`,`--config` 来改变路径.

这里 [https://github.com/containerd/containerd/releases](https://github.com/containerd/containerd/releases) 是containerd所有releases的版本. 在最新的releases 1.6.0版本中一共构建了三个包; 分别是:`containerd-1.6.0`, `cri-containerd-1.6.0`, `cri-containerd-cni-1.6.0`.

- `containerd-1.6.0` 包含containerd的核心程序和containerd-shim组件以及一个和containerd交互的ctr程序.
- `cri-containerd-1.6.0` 在上面的包基础上提供CRI配置工具和Systemd配置以及和GCP云厂商的配置.
- `cri-containerd-cni-1.6.0` 在CRI包的基础上提供CNI的配置和工具.

从上面可以看出containerd正在不断的向标准的CRI和CNI规范靠近,  而且在最新的版本里面containerd已经实现了CRI接口.

在这里我们使用 `cri-containerd-cni-1.5.8` 这个包.

#### Step 0: Install Dependent Libraries

```shell
sudo apt-get update
sudo apt-get install libseccomp2
```

#### Step 1: Download Containerd

```shell
wget https://github.com/containerd/containerd/releases/download/v1.5.8/cri-containerd-cni-1.5.8-linux-amd64.tar.gz
```

#### Step 2: Install Containerd

```shell
sudo tar --no-overwrite-dir -C / -xzf cri-containerd-1.6.0-beta.5-linux-amd64.tar.gz
sudo systemctl daemon-reload
sudo systemctl start containerd
```

```shell
systemctl status containerd.service
● containerd.service - containerd container runtime
     Loaded: loaded (/lib/systemd/system/containerd.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2021-12-31 02:35:24 EST; 1 weeks 3 days ago
       Docs: https://containerd.io
   Main PID: 768 (containerd)
      Tasks: 19
     Memory: 91.6M
     CGroup: /system.slice/containerd.service
             └─768 /usr/bin/containerd

```

以上, 便在单机中安装了containerd程序, 我们可以使用命令 `ctr` 来简单的操作一下.



## Containerd 使用

在这里我们使用containerd自带的 *ctr* 命令来做基本的演示.

```shell
➜  ~ ctr version
Client:
  Version:  v1.5.8
  Revision: 1e5ef943eb76627a6d3b6de8cd1ef6537f393a71
  Go version: go1.16.10

Server:
  Version:  v1.5.8
  Revision: 1e5ef943eb76627a6d3b6de8cd1ef6537f393a71
  UUID: e3bc8bf4-19b7-419e-88c3-df384ce6eb50
```

#### 镜像操作

```shell
# 拉取镜像
➜  ~ ctr i pull docker.io/library/ubuntu:21.10
docker.io/library/ubuntu:21.10:                                                   resolved       |++++++++++++++++++++++++++++++++++++++|
index-sha256:cfc189b67f53b322b0ceaabacfc9e2414c63435f362348807fe960d0fbce5ada:    done           |++++++++++++++++++++++++++++++++++++++|
manifest-sha256:28941e0c8e9be8c6aa586be8c7ae3074c81ed915cb5b5836853985d756fb46e2: done           |++++++++++++++++++++++++++++++++++++++|
config-sha256:64c59b1065b1ea628a7253ea0e5e87234e764fe3612ced48c495bb0f2de60a85:   done           |++++++++++++++++++++++++++++++++++++++|
layer-sha256:688b037d2a94faed4d0a662851a3612e2a23a9e0e2636b9fc84be4f45a05f698:    done           |++++++++++++++++++++++++++++++++++++++|
elapsed: 8.8 s                                                                    total:  29.0 M (3.3 MiB/s)
unpacking linux/amd64 sha256:cfc189b67f53b322b0ceaabacfc9e2414c63435f362348807fe960d0fbce5ada...
done: 1.147791522s

# 列出镜像
➜  ~ ctr i list
REF                            TYPE                                                      DIGEST                                                                  SIZE     PLATFORMS                                                                                LABELS
docker.io/library/nginx:alpine application/vnd.docker.distribution.manifest.list.v2+json sha256:12aa12ec4a8ca049537dd486044b966b0ba6cd8890c4c900ccb5e7e630e03df0 9.6 MiB  linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64/v8,linux/ppc64le,linux/s390x -
docker.io/library/ubuntu:21.04 application/vnd.docker.distribution.manifest.list.v2+json sha256:93a94c12448f393522f44d8a1b34936b7f76890adea34b80b87a245524d1d574 30.2 MiB linux/amd64,linux/arm/v7,linux/arm64/v8,linux/ppc64le,linux/riscv64,linux/s390x          -
docker.io/library/ubuntu:21.10 application/vnd.docker.distribution.manifest.list.v2+json sha256:cfc189b67f53b322b0ceaabacfc9e2414c63435f362348807fe960d0fbce5ada 29.0 MiB linux/amd64,linux/arm/v7,linux/arm64/v8,linux/ppc64le,linux/riscv64,linux/s390x

# 将镜像挂载到某个目录
➜  images mkdir ubuntu
➜  images ctr i  mount docker.io/library/ubuntu:21.10 ./ubuntu
sha256:32e5d056934937fa341b4763348d73dfa6144b78a09db46124fd3f078a4b8b3b
./ubuntu
➜  images ls
ubuntu
➜  images cd ubuntu
➜  ubuntu ls
bin  boot  dev  etc  home  lib  lib32  lib64  libx32  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

#### 容器操作

```shell
# 启动一个容器
➜  ubuntu ctr run -d --cpu-quota 20000  docker.io/library/ubuntu:21.04 ubuntu-test
# 查看 container
➜  containerd ctr container ls
CONTAINER      IMAGE                             RUNTIME
ubuntu-test    docker.io/library/ubuntu:21.04    io.containerd.runc.v2
# 查看一个task
➜  containerd ctr task ls
TASK           PID     STATUS
ubuntu-test    5599    RUNNING
# 进入容器
➜  containerd ctr task exec --exec-id 10 -t ubuntu-test bash
root@iZ8psdykrxdgcybevaw3wzZ:/#

```

[Containerd install]: https://github.com/containerd/containerd/blob/main/docs/cri/installation.md
[Dockershim removal is coming. Are you ready?]: https://kubernetes.io/blog/2021/11/12/are-you-ready-for-dockershim-removal/

