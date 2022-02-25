## Runc 介绍

`runc` 是一个命令行工具用于在Linux上根据OCI的标准创建一个容器. 可以说他是距离操作系统最近的一个组件, 但立最终的使用用户就显得较远(主要由高级别的软件调用).  在系统中*runc* 默认被放在 `/usr/local/sbin/runc` 这个目录下. 项目的GitHub地址如下:

> [https://github.com/opencontainers/runc](https://github.com/opencontainers/runc)

## 使用

和 Docker 启动一个容器一样简单, 我们只需要使用`runc run` 命令就可以启动一个容器. 但是不一样的是我们需要为它准备两个东西: `config.json` 和 `rootfs`.

#### 创建bundle

`rootfs`和`config.json` 这两个文件放在一起我们统称为**bundle**.

我们可以使用 `docker export` 命令将容器的文件系统导出出来. 使用 `runc spec` 创建一个默认的 `config.json`文件.

```shell
➜  runc-demo docker export $(docker create busybox) | tar -C rootfs -xvf -
➜  runc-demo cd rootfs
➜  rootfs ls
bin  dev  etc  home  proc  root  sys  tmp  usr  var
```

```shell
➜  runc-demo runc spec
➜  runc-demo ls
config.json  rootfs
```

#### 运行容器

同过运行以下命令我们可以启动一个容器. 

```shell
➜  runc-demo runc run mycontainers
/ # ls
```

在默认的**config.json**文件中,我们在启动一个容器时会打开一个新的终端执行sh命令. 当然我们也可以更改这个配置文件执行我们命令.

当然,我们也可以先创建容器然后再启动容器. 这是非常有用的, 如网络协议栈, 一般都是在这个阶段设置的.

```shell
➜  runc-demo runc create mycontainers
➜  runc-demo runc list
ID             PID         STATUS      BUNDLE                                        CREATED                          OWNER
mycontainers   28306       created     /home/admin/devops/opencantainers/runc-demo   2022-02-10T08:28:14.457538458Z   root
➜  runc-demo runc start mycontainers
➜  runc-demo runc list
ID             PID         STATUS      BUNDLE                                        CREATED                          OWNER
mycontainers   0           stopped     /home/admin/devops/opencantainers/runc-demo   2022-02-10T08:28:14.457538458Z   root
➜  runc-demo runc delete mycontainers
➜  runc-demo runc list
ID          PID         STATUS      BUNDLE      CREATED     OWNER
```

#### rootless 容器

`runc` 可以不同过root 权限创建一个容器, 这个叫做`rootless`.  我们只需要传递一些参数即可.

```shell
# The --rootless parameter instructs runc spec to generate a configuration for a rootless container, which will allow you to run the container as a non-root user.
runc spec --rootless

# The --root parameter tells runc where to store the container state. It must be writable by the user.
runc --root /tmp/runc run mycontainerid
```


## go-runc

containerd 社区并没有在代码直接引用runc的代码, 而是将runc命令封装成为一个基础库. 这个基础库便是 [go-runc](https://github.com/containerd/go-runc)  项目.

作为开发者我们可以任意的修改这个项目来添加我们需要的功能.



