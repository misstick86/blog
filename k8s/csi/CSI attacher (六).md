前面介绍了当Pod调度到一台机器之后, AdController会监控Pod的调用创建一个 `volumeattachments` 资源对象, 然而后续的操作就交给了 `CSI attacher`  来处理了.

`CSI attacher` 对应的项目是: [external-attacher](https://github.com/kubernetes-csi/external-attacher)

#### 介绍

