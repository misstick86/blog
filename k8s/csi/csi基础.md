## CSI 基础

这篇文章将主要介绍一下与存储有关的各种资源和用法,并简单介绍创建一个volume到pod挂载的流程.



#### PV 对象

PV(持久卷)是集群中的一块块存储, 它是一个集群资源.使用一下`YAML`文件便可以创建一个PV资源.

```yaml

apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs
spec:
  storageClassName: manual
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: 10.244.1.4
    path: "/"
```

以上表示我们向`10.244.1.4`这个NFS服务器创建一个挂载目录, 然后在pod模板里面申请将这个NFS目录挂载到本地目录.    对于Kubernetes来说，NFS 这样的存储供应软件已经在kubernetes的核心代码里面实现了,  这也叫做In-Tree 插件. 当然不是所有得存储介质软件kubernetes都要实现一遍, 这便有了后来的Out-Tree插件.



#### PVC 对象

PVC(持久卷申请)表达用户对存储的需求.  PVC不管是如何实现一个存储, 只表达自己的需要. 当集群中有合适的PV出现时,会有一个Controller负责将这两个资源关联到一起. 叫做:**PersistentVolumeController**.

一下是如何创建一个PVC资源.

```yaml

apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
```



> 以上,PV是运维同学需要准备的资源,而开发则需要PVC来描述资源的需求, 具体的组合将由controller来负责.



#### StorageClass



#### VolumeAttachment



#### CSIDriver 



#### CSINode



