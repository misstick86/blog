根据CSI基础可知, 用户写的Driver需要事先注册到kubernetes系统中, 这篇文章主要介绍用户写的驱动如何和**node-driver-register**, **kubelet**交互。

这里会以**[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)** 的DISK做分析,也算是对于这部分的源码解读.



### 部署

Kubernetes 提供了一个叫做CSIDriver的资源,如果我们想将DISK这个插件注册到kubernetes的CSI中,需要先创建对应的CSI Driver对象。

```yaml
apiVersion: storage.k8s.io/v1beta1
kind: CSIDriver
metadata:
  name: diskplugin.csi.alibabacloud.com
spec:
  attachRequired: true
  podInfoOnMount: true
```

**Node-driver-register** 是官方提供注册的一个组件, 他和用户写的驱动程序一起以Demonset的方式部署在kubernetes之上. 部署文件可以下面找到.

[https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver/blob/master/deploy/disk/disk-plugin.yaml#L9](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver/blob/master/deploy/disk/disk-plugin.yaml#L9)



#### 流程

