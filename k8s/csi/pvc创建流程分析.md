这篇文章将以Disk Plugin为列, 分析一下一个PVC 创建完成之后调用对应的Stroage Classs 创建PV的整个流程, 会涉及一下组件**[external-provisioner](https://github.com/kubernetes-csi/external-provisioner)**,   **[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)** 的源码.

> 阿里云对 **[external-provisioner](https://github.com/kubernetes-csi/external-provisioner)** 做了一部分修改, 拿不到内部的版本,所以就以 [external-provisioner](https://github.com/kubernetes-csi/external-provisioner) 1.16版本进行分析了.

#### 部署

在阿里云的集群中部署cis主要有两个部分, 一个是以Demonset运行的 **csi-plugin**. 另一个则是以Deployment运行的**csi-provisioner**. 

- **csi-provisioner** 主要是的负责创建PVC后执行创建磁盘, 挂载到Node的操作.
- **csi-plugin** 主要是负责和kubelet交互,用于Plugin的注册, Node中磁盘挂载到目录操作.

csi-provisioner 中的各个容器是以Sidecar形式运行在一起的.  以Disk Plugin为列, Disk Plugin一共部署了三个容器: **csi-provisioner**, **csi-attacher**, **csi-resizer**

```yaml
- args:
    - --provisioner=diskplugin.csi.alibabacloud.com
    - --csi-address=$(ADDRESS)
    - --feature-gates=Topology=True
    - --volume-name-prefix=disk
    - --strict-topology=true
    - --timeout=150s
    - --enable-leader-election=true
    - --leader-election-type=leases
    - --retry-interval-start=500ms
    - --v=5
    env:
    - name: ADDRESS
      value: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com/csi.sock
    image: registry-vpc.us-west-1.aliyuncs.com/acs/csi-provisioner:v1.6.0-cbd508573-aliyun
    imagePullPolicy: Always
    name: external-disk-provisioner
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com
      name: disk-provisioner-dir
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: csi-admin-token-zfsm6
      readOnly: true
  - args:
    - --v=5
    - --csi-address=$(ADDRESS)
    - --leader-election=true
    env:
    - name: ADDRESS
      value: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com/csi.sock
    image: registry-vpc.us-west-1.aliyuncs.com/acs/csi-attacher:v2.1.0
    imagePullPolicy: Always
    name: external-disk-attacher
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com
      name: disk-provisioner-dir
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: csi-admin-token-zfsm6
      readOnly: true
  - args:
    - --v=5
    - --csi-address=$(ADDRESS)
    - --leader-election
    env:
    - name: ADDRESS
      value: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com/csi.sock
    image: registry-vpc.us-west-1.aliyuncs.com/acs/csi-resizer:v1.1.0
    imagePullPolicy: Always
    name: external-disk-resizer
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    volumeMounts:
    - mountPath: /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com
      name: disk-provisioner-dir
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: csi-admin-token-zfsm6
      readOnly: true
```

> csi-provisioner 对应的开源组件就是 **[external-provisioner](https://github.com/kubernetes-csi/external-provisioner)** 组件. **csi-attacher**, **csi-resize**是关于挂载和调整磁盘大小的组件, 这里先不介绍.

#### csi-provisioner 介绍

**external-provisioner** 本质上更像一个桥梁, 它对接 *kubernetes* 和用户自定义的[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)plugin. 对于用户来说:  **[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)** 必须实现两个接口: `CreateVolume` and `DeleteVolume` 来供 **external-provisioner** 调用. 对于**external-provisioner**来说,  **external-provisioner** 会 watch住 *kubernetes* 中 pvc 的创建, 从而调用 `CreateVolume` 来创建对应的存储. 当用户删除 pv 时, **external-provisioner** 也会监控到pv的状态改变,从而调用`DeleteVolume`来删除对应的存储.

关于 **csi-provisioner** 的设计可以参考: [https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/container-storage-interface.md#provisioning-and-deleting](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/storage/container-storage-interface.md#provisioning-and-deleting)

下图表明了用户创建一个PVC资源后到删除的整个流程:

![流程图](../../static/images/k8s/provisioning.png)

这里需要注意一下几个问题:

1. 所有的GRPC调用都必须是幂等的.
2. 失败通过重试处理
3. 一个pv被标识删除后, 删除动作不会立即执行而是等到controller认为可以删除时才会删除.

#### csi-provisioner 源码分析



从部署来看启动 **csi-provisioner** 时传递一个参数: `csi-address`, 这个参数便是和 *CSI Plugin* 通信的地址. 

> /var/lib/kubelet/csi-provisioner/diskplugin.csi.alibabacloud.com/csi.sock

###### 启动流程

（1）**csi-provisioner** 向 **CSI Plugin** 发送一个探针请求,确定**CSI Plugin**, 调用的时**Probe**接口.

```go
	err = ctrl.Probe(grpcClient, *operationTimeout)
	if err != nil {
		klog.Error(err.Error())
		os.Exit(1)
	}
```



（2） **csi-provisioner** 向 **CSI Plugin** 的 **GetPluginInfo** 的接口发送一个请求获取当前Plugin的名称.

```go
	// Autodetect provisioner name
	provisionerName, err := ctrl.GetDriverName(grpcClient, *operationTimeout)
	if err != nil {
		klog.Fatalf("Error getting CSI driver name: %s", err)
	}
```



（3）**csi-provisioner** 向 **CSI Plugin** 的 **GetPluginCapabilities** 的接口发送一个请求, 知道当前Plugin的能力.

```go
	pluginCapabilities, controllerCapabilities, err := ctrl.GetDriverCapabilities(grpcClient, *operationTimeout)
	if err != nil {
		klog.Fatalf("Error getting CSI driver capabilities: %s", err)
	}
```



> 以上从侧面说明, 对于用户实现的Plugin, 我们必须要实现 **Probe**, **GetPluginInfo**, **GetPluginCapabilities**  这便是 `CSI Identity` 功能.



（4）实例化部分资源的Lister和Informer, 如: *StorageClasses*, *PersistentVolumeClaims*, *VolumeAttachment*, 这部分资源会传递给 **csiProvisioner** 结构.

```go
	// Listers
	// Create informer to prevent hit the API server for all resource request
	scLister := factory.Storage().V1().StorageClasses().Lister()
	claimLister := factory.Core().V1().PersistentVolumeClaims().Lister()

	var vaLister storagelistersv1.VolumeAttachmentLister
	if controllerCapabilities[csi.ControllerServiceCapability_RPC_PUBLISH_UNPUBLISH_VOLUME] {
		klog.Info("CSI driver supports PUBLISH_UNPUBLISH_VOLUME, watching VolumeAttachments")
		vaLister = factory.Storage().V1().VolumeAttachments().Lister()
	} else {
		klog.Info("CSI driver does not support PUBLISH_UNPUBLISH_VOLUME, not watching VolumeAttachments")
	}
...
	// PersistentVolumeClaims informer
	rateLimiter := workqueue.NewItemExponentialFailureRateLimiter(*retryIntervalStart, *retryIntervalMax)
	claimQueue := workqueue.NewNamedRateLimitingQueue(rateLimiter, "claims")
	claimInformer := factory.Core().V1().PersistentVolumeClaims().Informer()
```

（5）实例化一个 *csiProvisioner* 结构体, 该结构体实现的功能便是创建 删除用户的volume请求.

```go
	// Create the provisioner: it implements the Provisioner interface expected by
	// the controller
	csiProvisioner := ctrl.NewCSIProvisioner(
		clientset,
		*operationTimeout,
		identity,
		*volumeNamePrefix,
		*volumeNameUUIDLength,
		grpcClient,
		snapClient,
		provisionerName,
		pluginCapabilities,
		controllerCapabilities,
		supportsMigrationFromInTreePluginName,
		*strictTopology,
		*immediateTopology,
		translator,
		scLister,
		csiNodeLister,
		nodeLister,
		claimLister,
		vaLister,
		*extraCreateMetadata,
		*defaultFSType,
		nodeDeployment,
		*controllerPublishReadOnly,
	)

```

（6） 实例化一个*provisionController*, 这个controler便是使用 client-go 监听资源变化的核心组件.

```go
	provisionController = controller.NewProvisionController(
		clientset,
		provisionerName,
		csiProvisioner,
		provisionerOptions...,
	)
```

（7）根据是否启用leader功能, 调用run方法启动 **Provision** 程序. **run** 方法如下:

```go
	run := func(ctx context.Context) {
		factory.Start(ctx.Done())
		if factoryForNamespace != nil {
			// Starting is enough, the capacity controller will
			// wait for sync.
			factoryForNamespace.Start(ctx.Done())
		}
		cacheSyncResult := factory.WaitForCacheSync(ctx.Done())
		for _, v := range cacheSyncResult {
			if !v {
				klog.Fatalf("Failed to sync Informers!")
			}
		}

		if capacityController != nil {
			go capacityController.Run(ctx, int(*capacityThreads))
		}
		if csiClaimController != nil {
			go csiClaimController.Run(ctx, int(*finalizerThreads))
		}
    // 启动 provisionController 监听资源的变化
		provisionController.Run(ctx)
	}
```

###### 处理流程

用户启动**provisionController**后, 资源的变更会同过ListWatch监听到,然后放到WorkQueue中. 之后便是从workqueue中取到数据处理.

```go
		for i := 0; i < ctrl.threadiness; i++ {
			go wait.Until(func() { ctrl.runClaimWorker(ctx) }, time.Second, ctx.Done())
			go wait.Until(func() { ctrl.runVolumeWorker(ctx) }, time.Second, ctx.Done())
		}
```

- **runClaimWorker()** 处理PVC资源变化后的事件.
- **runVolumeWorker()** 处理PV资源变化后的事件.



###### runClaimWorker() 流程

- 将获取的资源转换为一个PVC资源.
- 判断当前的PVC状态是否可以向Plugin创建volume.

```go
func (ctrl *ProvisionController) shouldProvision(claim *v1.PersistentVolumeClaim) (bool, error) {
	if claim.Spec.VolumeName != "" {
		return false, nil
	}

	if qualifier, ok := ctrl.provisioner.(Qualifier); ok {
		if !qualifier.ShouldProvision(claim) {
			return false, nil
		}
	}

	// Kubernetes 1.5 provisioning with annStorageProvisioner
	if ctrl.kubeVersion.AtLeast(utilversion.MustParseSemantic("v1.5.0")) {
		if provisioner, found := claim.Annotations[annStorageProvisioner]; found {
			if ctrl.knownProvisioner(provisioner) {
				claimClass := util.GetPersistentVolumeClaimClass(claim)
				class, err := ctrl.getStorageClass(claimClass)
				if err != nil {
					return false, err
				}
				if class.VolumeBindingMode != nil && *class.VolumeBindingMode == storage.VolumeBindingWaitForFirstConsumer {
					// When claim is in delay binding mode, annSelectedNode is
					// required to provision volume.
					// Though PV controller set annStorageProvisioner only when
					// annSelectedNode is set, but provisioner may remove
					// annSelectedNode to notify scheduler to reschedule again.
					if selectedNode, ok := claim.Annotations[annSelectedNode]; ok && selectedNode != "" {
						return true, nil
					}
					return false, nil
				}
				return true, nil
			}
		}
	} else {
		// Kubernetes 1.4 provisioning, evaluating class.Provisioner
		claimClass := util.GetPersistentVolumeClaimClass(claim)
		class, err := ctrl.getStorageClass(claimClass)
		if err != nil {
			glog.Errorf("Error getting claim %q's StorageClass's fields: %v", claimToClaimKey(claim), err)
			return false, err
		}
		if class.Provisioner != ctrl.provisionerName {
			return false, nil
		}

		return true, nil
	}

	return false, nil
}
```

- 满足创建Volume的条件后,调用 **provisionClaimOperation()** 函数向 **[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)** 创建磁盘.
- 实际调用的是 **ProvisionExt()** 函数, 该函数封装CreateVolume的请求参数,并向 **alibaba-cloud-csi-driver** 的 CreateVolume 接口发送请求创建volume.
- 请求结束后, 封装一个pv资源并向API-Server创建一个pv资源. 阿里云这里做了一些优化, 默认pv的名字是以**disk-xxxxxxx**形式, 阿里云则修改为他们的DIsk id. 

###### runVolumeWorker()流程

**runVolumeWorker()** 主要是监听PV的变化,在用户删除这个PV时调用Plugin的**DeleteVolume**接口.

```go
//  判断当前的PV是否可以删除, 
func (ctrl *ProvisionController) shouldDelete(volume *v1.PersistentVolume) bool {
	if deletionGuard, ok := ctrl.provisioner.(DeletionGuard); ok {
		if !deletionGuard.ShouldDelete(volume) {
			return false
		}
	}

	// In 1.9+ PV protection means the object will exist briefly with a
	// deletion timestamp even after our successful Delete. Ignore it.
	if ctrl.kubeVersion.AtLeast(utilversion.MustParseSemantic("v1.9.0")) {
		if ctrl.addFinalizer && !ctrl.checkFinalizer(volume, finalizerPV) && volume.ObjectMeta.DeletionTimestamp != nil {
			return false
		} else if volume.ObjectMeta.DeletionTimestamp != nil {
			return false
		}
	}

	// In 1.5+ we delete only if the volume is in state Released. In 1.4 we must
	// delete if the volume is in state Failed too.
	if ctrl.kubeVersion.AtLeast(utilversion.MustParseSemantic("v1.5.0")) {
		if volume.Status.Phase != v1.VolumeReleased {
			return false
		}
	} else {
		if volume.Status.Phase != v1.VolumeReleased && volume.Status.Phase != v1.VolumeFailed {
			return false
		}
	}

	if volume.Spec.PersistentVolumeReclaimPolicy != v1.PersistentVolumeReclaimDelete {
		return false
	}

	if !metav1.HasAnnotation(volume.ObjectMeta, annDynamicallyProvisioned) {
		return false
	}

	ann := volume.Annotations[annDynamicallyProvisioned]
	migratedTo := volume.Annotations[annMigratedTo]
	if ann != ctrl.provisionerName && migratedTo != ctrl.provisionerName {
		return false
	}

	return true
}
```

```go
func (ctrl *ProvisionController) deleteVolumeOperation(volume *v1.PersistentVolume) error {
	operation := fmt.Sprintf("delete %q", volume.Name)
	glog.Info(logOperation(operation, "started"))

	// This method may have been waiting for a volume lock for some time.
	// Our check does not have to be as sophisticated as PV controller's, we can
	// trust that the PV controller has set the PV to Released/Failed and it's
	// ours to delete
  // 在删除之前或再一次获取当前PV的状态,判断是否可以删除。
	newVolume, err := ctrl.client.CoreV1().PersistentVolumes().Get(volume.Name, metav1.GetOptions{})
	if err != nil {
		return nil
	}
	if !ctrl.shouldDelete(newVolume) {
		glog.Info(logOperation(operation, "persistentvolume no longer needs deletion, skipping"))
		return nil
	}
	// 实际封装deleteVolume请求的函数.
	err = ctrl.provisioner.Delete(volume)
	....
	}
```

**CreateVolume()** 和 **DeleteVolume()**  便是 CSI Plugin 中 controller 要实现的部分.



## 总结

以上便是创建一个PVC和删除PV时**[external-provisioner](https://github.com/kubernetes-csi/external-provisioner)** 和  **[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)**  两个组件的交互流程.  其中还有很多的细节没有写出来, 但不妨碍对整个流程的理解. 





