## 内容流

本篇为 `content` 相关文章的翻译, 这个的 `content` 也是一种概念.

> [https://github.com/containerd/containerd/blob/main/docs/content-flow.md](https://github.com/containerd/containerd/blob/main/docs/content-flow.md)

containerd 的主要目标是创建一个可以在容器中执行程序的系统,  为了达到这个目的,  containerd 设计了一个概念叫做: `content` 来管理.

这篇文章介绍了 *content* 是如何进入containerd, 如何管理,以及在这个过程中的每个阶段.  下面以一个镜像来详解介绍这个流程.

## 内容区域

`content` 存在于containerd生命周期的一下区域:
- OCI hub, 例如: docker hub , quay.io
-  containerd content store, containerd 的本地存储, 在标准的Linux系统存储在 `/var/lib/containerd/io.containerd.content.v1.content`
-  snapshots, containerd的本地存储, 在标准的Linux系统中根据不通的存储系统放在不通的目录下, 对于 overlayfs 文件系统就是`/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs`.

创建一个container会产生一下流程:

1. 将镜像的所有内容加载到 `content store` 中, 通常是从OCI hub 中下载的, 当然也可以直接加载.
2. 从镜像的每一层创建一个 committed 的 snapshots.
3. 创建一个可以层, 以至于可以修改容器的内容.

此时, 创建了一个container, 并以 rootfs 作为一个活动的 snapshots.

一下介绍内容区域的详细信息, 以及他们之间的关联关系.

## 镜像格式

一个镜像由一堆描述符的JSON文档组成,  描述符中包含一个**MediaType** 字段. 这个字段告诉是一下哪种类型:

- "manifest": 它包含将镜像作为配置文件的hash值以及创建文件的二进制层.
- "Index": 每个manifests的hash值, 跟据平台和架构不同.

Index的目的是匹配我们相同的平台.

下面是以 `redis:5.0.9` 为列的镜像将其存储到磁盘的示例:

1. 检索镜像的描述符文档.
2. 根据mediaType确定描述符是*index* 还是 *manifest*.
 - 	 如果描述符是*index*, 根据平台和架构找到需要运行的容器, 并根据hash值来检索清单.
 - 	 如果是*manifest*, 继续。

3. 循环每个在manifest的元素, 并存储.

当我们第一次获取到 `redis:5.0.9` 的JSON 文档时如下:

```json
{
  "manifests": [
    {
      "digest": "sha256:a5aae2581826d13e906ff5c961d4c2817a9b96c334fd97b072d976990384156a",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      },
      "size": 1572
    },
    {
      "digest": "sha256:4ff8940144391ecd5e1632d0c427d95f4a8d2bb4a72b7e3898733352350d9ab3",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "arm",
        "os": "linux",
        "variant": "v5"
      },
      "size": 1573
    },
    {
      "digest": "sha256:ce541c3e2570b5a05d40e7fc01f87fc1222a701c81f95e7e6f2ef6df1c6e25e7",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "arm",
        "os": "linux",
        "variant": "v7"
      },
      "size": 1573
    },
    {
      "digest": "sha256:535ee258100feeeb525d4793c16c7e58147c105231d7d05ffc9c84b56750f233",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "arm64",
        "os": "linux",
        "variant": "v8"
      },
      "size": 1573
    },
    {
      "digest": "sha256:0f3b047f2789547c58634ce88d71c7856999b2afc8b859b7adb5657043984b26",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "386",
        "os": "linux"
      },
      "size": 1572
    },
    {
      "digest": "sha256:bfc45f499a9393aef091057f3d067ff7129ae9fb30d9f31054bafe96ca30b8d6",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "mips64le",
        "os": "linux"
      },
      "size": 1572
    },
    {
      "digest": "sha256:3198e1f1707d977939154a57918d360a172c575bddeac875cb26ca6f4d30dc1c",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "ppc64le",
        "os": "linux"
      },
      "size": 1573
    },
    {
      "digest": "sha256:24a15cc9366e1557db079a987e63b98a5abf4dee4356a096442f53ddc8b9c7e9",
      "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
      "platform": {
        "architecture": "s390x",
        "os": "linux"
      },
      "size": 1573
    }
  ],
  "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
  "schemaVersion": 2
}
```

以上便是一个原始的manifests, 可以看到它包含了很多平台,  这个标志的字段是 *architecture* 和 *os*, 由于我们需要运行在Linux和amd64的架构平台之上,  所以只需要看带有如下字段的menifest.

```json
"platform": {
  "architecture": "amd64",
  "os": "linux"
}
```

根据上面的描述, 我们获取到的 hash 值为 *sha256:a5aae2581826d13e906ff5c961d4c2817a9b96c334fd97b072d976990384156a*.

当我们以此hash和平台去检索时, 得到的结果如下:

```json
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
   "config": {
      "mediaType": "application/vnd.docker.container.image.v1+json",
      "size": 6836,
      "digest": "sha256:df57482065789980ee9445b1dd79ab1b7b3d1dc26b6867d94470af969a64c8e6"
   },
   "layers": [
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 27098147,
         "digest": "sha256:123275d6e508d282237a22fefa5aef822b719a06496444ea89efa65da523fc4b"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 1730,
         "digest": "sha256:f2edbd6a658e04d559c1bec36d838006bbdcb39d8fb9033ed43d2014ac497774"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 1417708,
         "digest": "sha256:66960bede47c1a193710cf8bfa7bf5f50bc46374260923df1db1c423b52153ac"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 7345094,
         "digest": "sha256:79dc0b596c9027416a627a6237bd080ac9d87f92b60f1ce145c566632839bce7"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 99,
         "digest": "sha256:de36df38e0b6c0e7f29913c68884a0323207c07cd7c1eba71d5618f525ac2ba6"
      },
      {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 410,
         "digest": "sha256:602cd484ff92015489f7b9cf9cbd77ac392997374b1cc42937773f5bac1ff43b"
      }
   ]
}
```

*mediaType* 告诉我们这是一个清单, 它包含一下格式:

- config: 这个hash 值是 `"sha256:df57482065789980ee9445b1dd79ab1b7b3d1dc26b6867d94470af969a64c8e6"`
- layers: 一个或者多个层.

以上的每一个元素, index, manifest, 每一层的配置文件都是单独存储在hub中的,并且单独下载.

## Content Store

当content被加载到containerd的 content store 中, 它和存储到hub的方式非常相似. 每个组件都存储在一个文件中, 文件的命名为它的hash值.

还是Redis的那个例子, 当我们以 `client.Pull()` 或者 `ctr pull` , content store 将存储一下内容:
-   `sha256:1d0b903e3770c2c3c79961b73a53e963f4fd4b2674c2c4911472e8a054cb5728` - the index
-   `sha256:a5aae2581826d13e906ff5c961d4c2817a9b96c334fd97b072d976990384156a` - the manifest for `linux/amd64`
-   `sha256:df57482065789980ee9445b1dd79ab1b7b3d1dc26b6867d94470af969a64c8e6` - the config
-   `sha256:123275d6e508d282237a22fefa5aef822b719a06496444ea89efa65da523fc4b` - layer 0
-   `sha256:f2edbd6a658e04d559c1bec36d838006bbdcb39d8fb9033ed43d2014ac497774` - layer 1
-   `sha256:66960bede47c1a193710cf8bfa7bf5f50bc46374260923df1db1c423b52153ac` - layer 2
-   `sha256:79dc0b596c9027416a627a6237bd080ac9d87f92b60f1ce145c566632839bce7` - layer 3
-   `sha256:de36df38e0b6c0e7f29913c68884a0323207c07cd7c1eba71d5618f525ac2ba6` - layer 4
-   `sha256:602cd484ff92015489f7b9cf9cbd77ac392997374b1cc42937773f5bac1ff43b` - layer 5

实际存储的content 如下:

```shell
➜  ~ tree /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/
/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/
├── 0ff87ec668da99b8b5542b57d61691abb2aa6cabc7e8039317e17996c439f5da
├── 12aa12ec4a8ca049537dd486044b966b0ba6cd8890c4c900ccb5e7e630e03df0
├── 28941e0c8e9be8c6aa586be8c7ae3074c81ed915cb5b5836853985d756fb46e2
├── 3f3577460f48b48cdb31034e3efd3969d4cfa788495ddc3c0c721d0cb4503ca8
├── 64c59b1065b1ea628a7253ea0e5e87234e764fe3612ced48c495bb0f2de60a85
├── 688b037d2a94faed4d0a662851a3612e2a23a9e0e2636b9fc84be4f45a05f698
├── 93a94c12448f393522f44d8a1b34936b7f76890adea34b80b87a245524d1d574
├── 97518928ae5f3d52d4164b314a7e73654eb686ecd8aafa0b79acd980773a740d
├── 9e6a0d5477cff31ce49b4d3bc07409ebd27609574e968043d0b9c10acf854ebc
├── a2402c2da4733ff9c5b44fee234b9407cd120a9817c6bb2ffc9d10e9508c1540
├── a4e1564120377c57f6c7d13778f0b12977f485196ea2785ab2a71352cd7dd95d
├── b46db85084b80a87b94cc930a74105b74763d0175e14f5913ea5b07c312870f8
├── cfc189b67f53b322b0ceaabacfc9e2414c63435f362348807fe960d0fbce5ada
├── d662230a2592d697a8f3afba21d863148b68850e4d5cecaf2ab436f3cd72c10c
├── e0bae2ade5ec5d4a95703ac5d449bb058ef7ed0076fbe81bf4bee15e7587d190
├── e362c27513c3158f887a4eff0cea4b87b6b379be655a39c1e3c02e76e6b53678
└── f51b557cbb5e8dfd8c5e416ae74b58fe823efe52d9f9fed3f229521844a509e2

0 directories, 17 files
```

当然, 我们可以使用`ctr content ls` 看到类似的结构.
```shell
➜  ~ ctr content ls
DIGEST									SIZE	AGE		LABELS
sha256:1ed3521a5dcbd05214eb7f35b952ecf018d5a6610c32ba4e315028c556f45e94	1.732kB	18 seconds	containerd.io/uncompressed=sha256:832f21763c8e6b070314e619ebb9ba62f815580da6d0eaec8a1b080bd01575f7,containerd.io/distribution.source.docker.io=library/redis
sha256:2a9865e55c37293b71df051922022898d8e4ec0f579c9b53a0caee1b170bc81c	1.862kB	20 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/gc.ref.content.m.7=sha256:d66dfc869b619cd6da5b5ae9d7b1cbab44c134b31d458de07f7d580a84b63f69,containerd.io/gc.ref.content.m.2=sha256:17dc42e40d4af0a9e84c738313109f3a95e598081beef6c18a05abb57337aa5d,containerd.io/gc.ref.content.m.3=sha256:613f4797d2b6653634291a990f3e32378c7cfe3cdd439567b26ca340b8946013,containerd.io/gc.ref.content.m.1=sha256:aeb53f8db8c94d2cd63ca860d635af4307967aa11a2fdead98ae0ab3a329f470,containerd.io/gc.ref.content.m.6=sha256:4b7860fcaea5b9bbd6249c10a3dc02a5b9fb339e8aef17a542d6126a6af84d96,containerd.io/gc.ref.content.m.5=sha256:1072145f8eea186dcedb6b377b9969d121a00e65ae6c20e9cd631483178ea7ed,containerd.io/gc.ref.content.m.0=sha256:9bb13890319dc01e5f8a4d3d0c4c72685654d682d568350fd38a02b1d70aee6b,containerd.io/gc.ref.content.m.4=sha256:ee0e1f8d8d338c9506b0e487ce6c2c41f931d1e130acd60dc7794c3a246eb59e
sha256:5999b99cee8f2875d391d64df20b6296b63f23951a7d41749f028375e887cd05	1.418MB	15 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/uncompressed=sha256:223b15010c47044b6bab9611c7a322e8da7660a8268949e18edde9c6e3ea3700
sha256:97481c7992ebf6f22636f87e4d7b79e962f928cdbe6f2337670fa6c9a9636f04	409B	19 seconds	containerd.io/uncompressed=sha256:d442ae63d423b4b1922875c14c3fa4e801c66c689b69bfd853758fde996feffb,containerd.io/distribution.source.docker.io=library/redis
sha256:987b553c835f01f46eb1859bc32f564119d5833801a27b25a0ca5c6b8b6e111a	7.648kB	18 seconds	containerd.io/gc.ref.snapshot.overlayfs=sha256:33bd296ab7f37bdacff0cb4a5eb671bcb3a141887553ec4157b1e64d6641c1cd,containerd.io/distribution.source.docker.io=library/redis
sha256:9bb13890319dc01e5f8a4d3d0c4c72685654d682d568350fd38a02b1d70aee6b	1.572kB	20 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/gc.ref.content.l.5=sha256:97481c7992ebf6f22636f87e4d7b79e962f928cdbe6f2337670fa6c9a9636f04,containerd.io/gc.ref.content.l.4=sha256:fd36a1ebc6728807cbb1aa7ef24a1861343c6dc174657721c496613c7b53bd07,containerd.io/gc.ref.content.l.3=sha256:bfee6cb5fdad6b60ec46297f44542ee9d8ac8f01c072313a51cd7822df3b576f,containerd.io/gc.ref.content.l.2=sha256:5999b99cee8f2875d391d64df20b6296b63f23951a7d41749f028375e887cd05,containerd.io/gc.ref.content.l.1=sha256:1ed3521a5dcbd05214eb7f35b952ecf018d5a6610c32ba4e315028c556f45e94,containerd.io/gc.ref.content.l.0=sha256:bb79b6b2107fea8e8a47133a660b78e3a546998fcf0427be39ac9a0af4a97e90,containerd.io/gc.ref.content.config=sha256:987b553c835f01f46eb1859bc32f564119d5833801a27b25a0ca5c6b8b6e111a
sha256:bb79b6b2107fea8e8a47133a660b78e3a546998fcf0427be39ac9a0af4a97e90	27.09MB	11 seconds	containerd.io/uncompressed=sha256:d0fe97fa8b8cefdffcef1d62b65aba51a6c87b6679628a2b50fc6a7a579f764c,containerd.io/distribution.source.docker.io=library/redis
sha256:bfee6cb5fdad6b60ec46297f44542ee9d8ac8f01c072313a51cd7822df3b576f	7.348MB	16 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/uncompressed=sha256:b96fedf8ee00e59bf69cf5bc8ed19e92e66ee8cf83f0174e33127402b650331d
sha256:fd36a1ebc6728807cbb1aa7ef24a1861343c6dc174657721c496613c7b53bd07	98B	19 seconds	containerd.io/uncompressed=sha256:aff00695be0cebb8a114f8c5187fd6dd3d806273004797a00ad934ec9cd98212,containerd.io/distribution.source.docker.io=library/redis

```
### Labels

从上面可以看到每个层都有一个标签, 下面简单介绍一下:

##### Layer Labels

我们从层本省来开始查看, 可以看到它只有一个`containerd.io/uncompressed` 的labels. 他们是一个压缩后的tar文件, 标签的值在未压缩时给的是hash值. 可以同过以下命令查看:

```shell
$ cat <file> | gunzip - | sha256sum -
```

例如:

```shell
➜  ~ cat /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/fd36a1ebc6728807cbb1aa7ef24a1861343c6dc174657721c496613c7b53bd07 | gunzip - | sha256sum -
aff00695be0cebb8a114f8c5187fd6dd3d806273004797a00ad934ec9cd98212  -
```

可以看到hash值和最后一层的值是相同的.

##### config labels

仅仅只有一个config 层, `sha256:987b553c835f01f46eb1859bc32f564119d5833801a27b25a0ca5c6b8b6e111a`, 它有一个标签`containerd.io/gc.ref` 这个一个和垃圾回收有关的标签.

这个示例中标签的格式主要为`containerd.io/gc.ref.snapshot.overlayfs`,  这其中还包含如何连接到*snapshot* 中, 后面会讨论.

#####  Manifest Labels

也是以`containerd.io/gc.ref` 开头的标签, 表示他们被用于垃圾回收.  在上面的示例中下面的hash层应该是包含manifest labels.

```
sha256:2a9865e55c37293b71df051922022898d8e4ec0f579c9b53a0caee1b170bc81c	1.862kB	20 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/gc.ref.content.m.7=sha256:d66dfc869b619cd6da5b5ae9d7b1cbab44c134b31d458de07f7d580a84b63f69,containerd.io/gc.ref.content.m.2=sha256:17dc42e40d4af0a9e84c738313109f3a95e598081beef6c18a05abb57337aa5d,containerd.io/gc.ref.content.m.3=sha256:613f4797d2b6653634291a990f3e32378c7cfe3cdd439567b26ca340b8946013,containerd.io/gc.ref.content.m.1=sha256:aeb53f8db8c94d2cd63ca860d635af4307967aa11a2fdead98ae0ab3a329f470,containerd.io/gc.ref.content.m.6=sha256:4b7860fcaea5b9bbd6249c10a3dc02a5b9fb339e8aef17a542d6126a6af84d96,containerd.io/gc.ref.content.m.5=sha256:1072145f8eea186dcedb6b377b9969d121a00e65ae6c20e9cd631483178ea7ed,containerd.io/gc.ref.content.m.0=sha256:9bb13890319dc01e5f8a4d3d0c4c72685654d682d568350fd38a02b1d70aee6b,containerd.io/gc.ref.content.m.4=sha256:ee0e1f8d8d338c9506b0e487ce6c2c41f931d1e130acd60dc7794c3a246eb59e
```

##### Index Labels

也是以`containerd.io/gc.ref` 开头的标签, 表示他们被用于垃圾回收.  在上面的示例中包含**l**:

```
sha256:9bb13890319dc01e5f8a4d3d0c4c72685654d682d568350fd38a02b1d70aee6b	1.572kB	20 seconds	containerd.io/distribution.source.docker.io=library/redis,containerd.io/gc.ref.content.l.5=sha256:97481c7992ebf6f22636f87e4d7b79e962f928cdbe6f2337670fa6c9a9636f04,containerd.io/gc.ref.content.l.4=sha256:fd36a1ebc6728807cbb1aa7ef24a1861343c6dc174657721c496613c7b53bd07,containerd.io/gc.ref.content.l.3=sha256:bfee6cb5fdad6b60ec46297f44542ee9d8ac8f01c072313a51cd7822df3b576f,containerd.io/gc.ref.content.l.2=sha256:5999b99cee8f2875d391d64df20b6296b63f23951a7d41749f028375e887cd05,containerd.io/gc.ref.content.l.1=sha256:1ed3521a5dcbd05214eb7f35b952ecf018d5a6610c32ba4e315028c556f45e94,containerd.io/gc.ref.content.l.0=sha256:bb79b6b2107fea8e8a47133a660b78e3a546998fcf0427be39ac9a0af4a97e90,containerd.io/gc.ref.content.config=sha256:987b553c835f01f46eb1859bc32f564119d5833801a27b25a0ca5c6b8b6e111a
```

> 在实际操作中, 1.5.8 的containerd的设计已经发生改变, 包含了**l** 和 **m** 的标签.

## Snapshots

在content store 中的内容是不可变的, 但通常也是无法使用的格式. 例如, 所有的container 层通常是tar-gzip的格式, 不能简单的挂载这种tar-gzip文件.  即使可以, 我们也希望这些不可变的内容能够发生改变. 

为了实现这个目的, 我们需要对content创建快照.

流程如下:

1. 快照程序从父快照开始, 对于第一次快照是空白, 当前的叫做"active"快照.
2. diff 应用程序了解层 blob 的内部格式，将层 blob 应用于active快照.
3. 在出现差异后会提成新的快照, 这个叫做"commit" 快照.
4. commit 的快照用于下一层的父级.

回到我们这个列子, 每一层都有一个不可变的快照层.  上面我们看到有6个层, 这里可以也有6个已经 commit 的 snapshots. 

```shell
(base) ➜  ~ ctr snapshots ls
KEY                                                                     PARENT                                                                  KIND
sha256:2ae5fa95c0fce5ef33fbb87a7e2f49f2a56064566a37a83b97d3f668c10b43d6 sha256:d0fe97fa8b8cefdffcef1d62b65aba51a6c87b6679628a2b50fc6a7a579f764c Committed
sha256:33bd296ab7f37bdacff0cb4a5eb671bcb3a141887553ec4157b1e64d6641c1cd sha256:bc8b010e53c5f20023bd549d082c74ef8bfc237dc9bbccea2e0552e52bc5fcb1 Committed
sha256:a8f09c4919857128b1466cc26381de0f9d39a94171534f63859a662d50c396ca sha256:2ae5fa95c0fce5ef33fbb87a7e2f49f2a56064566a37a83b97d3f668c10b43d6 Committed
sha256:aa4b58e6ece416031ce00869c5bf4b11da800a397e250de47ae398aea2782294 sha256:a8f09c4919857128b1466cc26381de0f9d39a94171534f63859a662d50c396ca Committed
sha256:bc8b010e53c5f20023bd549d082c74ef8bfc237dc9bbccea2e0552e52bc5fcb1 sha256:aa4b58e6ece416031ce00869c5bf4b11da800a397e250de47ae398aea2782294 Committed
sha256:d0fe97fa8b8cefdffcef1d62b65aba51a6c87b6679628a2b50fc6a7a579f764c                                                                     Committed
```

##### parents
除了root层, 每个层都有一个父级, 这也和镜像的构建同理.

##### Name

snapshots的key或者名字并不和 content store 的hash值相同, 这是因为content store的hash值是原始内容的hash如tag-gz格式. snapshots 将其加载到文件系统中来使用, 它也不是一个未压缩的内容,如tar文件. 将会给一个标签: `containerd.io/uncompressed`.

相反, **name**是将层应用于上一层并对其进行hash的结果. 按照这个逻辑, root层应该和第一层的未压缩值具有相同的hash值和名称. 事实也的确如此. 

#####  Final Layer

最后一层是创建一个*active* snapshots 来启动容器的点, 因此,我们需要跟踪它.  它是一个放置config的一个label. 在示例中, 表示的是如下一层:

```json
sha256:987b553c835f01f46eb1859bc32f564119d5833801a27b25a0ca5c6b8b6e111a	7.648kB	20 hours	containerd.io/gc.ref.snapshot.overlayfs=sha256:33bd296ab7f37bdacff0cb4a5eb671bcb3a141887553ec4157b1e64d6641c1cd,containerd.io/distribution.source.docker.io=library/redis
```

在snapshots中, 它表示的是如下的一层:

```go
sha256:33bd296ab7f37bdacff0cb4a5eb671bcb3a141887553ec4157b1e64d6641c1cd sha256:bc8b010e53c5f20023bd549d082c74ef8bfc237dc9bbccea2e0552e52bc5fcb1 Committed
```

> 在content store 上的config标签是以 `containerd.io/gc.ref` 开始的, 这是一个垃圾回收的标签, 也正是这个标签阻止了垃圾回收删除snapshots.  因为有config在引用它, 所以顶层受到了垃圾回收的保护, 顶层又依赖于上一层, 以此类推, 直到root层.

##### container

基于以上条件, 我们知道一个*active* snapshots 对于containers非常有用. 我们仅仅需要使用**Prepare()** 激活快照同过传递Id和父快照.

因此, 步骤如下:
1. 同过`Pull()` 或者 content store api 获取 content store中的数据.
2. 解压image,并为镜像的每一层创建一个commit的snapshots. 使用的是`Unpack()`函数, 也可以使用`WithPullUnpack()` 函数.
3. 使用`Prepare()`函数创建一个active snapshots. 如果打算创建一个容器可以跳过这一步,  因为这里可以当做下一步的一个参数.
4. 使用 `NewContainer()` 创建一个容器, 可以同过参数`WithNewSnapshots()`来告诉是否创建snapshots.