熟悉kebernetes的人员应该知道, kubernetes在使用上也有一个namespace的概念. 在实际生产中有些技术团队会以namespace来区分业务,或者运行环境. 而对于containerd来说, 也提供了一个namespace的概念.  通过namespace, 多个用户可以操作同一个containerd的实例而不用担心冲突, 而且可以拥有多个相同名称但配置差异很大的容器.

值得注意的是namespace在实现上只是一个管理结构并不打算用于安全.

## 基本使用

`ctr` 命令可以管理一些namesapce的操作, 主要也就是增删查.

```shell
# 创建namespace
➜  ~ ctr ns create moby-demo
# 给namespace 打lable
➜  ~ ctr ns label moby-demo run=test
# 查看所有的namespace
➜  ~ ctr  ns ls
NAME      LABELS
default
demo
moby-demo run=test
# 删除一个namesapce
➜  ~ ctr ns rm moby-demo
moby-demo
```

## 如何指定namespace

在上一篇使用go调用containerd的客户端的demo文章中, 我们简单介绍了namespace的创建, 客户端需要传递一个 `context` 来创建, 和namesapce相关的操作都定义在 `github.com/containerd/containerd/namespaces` 这个目录下.

```go
// set a namespace
ctx := namespaces.WithNamespace(context.Background(), "my-namespace")

// get the namespace
ns, ok := namespaces.Namespace(ctx)
```

从上面可以看出, namespace本省还是一个context结构, 而客户端在和containerd的API交互时都是同过GRPC通信的, namespace将传递会从client端传到server端.

## Server端Namespace
