说完PVC创建后调用云厂商的接口创建PV的流程, 这篇文章在介绍一下当Pod引用一个pv时整个volume被挂载到Pod的流程.



> 默认情况下,监听Pod引用Volume的组件是 `Kube-controller-manager` 的 `ADController` 组件, 这里就主要介绍一下这个组件.

#### AdController的作用

AdController 全称为Attachment/Detachment 控制器, 主要赋值监听Pod中有关volume的变化, 然后根据调度的Node,创建、删除对应的VolumeAttachment 对象（对于CSI Plugin 而言）, 顺便在更新一下Node.Status.VolumesAttached的状态.

从CSI的角度来看, AdController只会负责创建或删除VolumeAttachment对象, 而不会真正的执行挂载或者卸载操作. 这一部分真正的打工人是 **CSI-attacher** 这个项目. CSI-attacher 会watch到VolumeAttachmentd的资源变化, 然后调用 **[alibaba-cloud-csi-driver](https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver)** 的 **Controller** 组件. 整体来说, CSI-attacher也只是一个桥梁, 只做了一些更新 `VolumeAttachment` 的操作,  alibaba-cloud-csi-driver 负责调用云厂商的 API 来将哪个volume挂载哪个Node上.



#### AD controller的初始化

和 *Deployment* 等其他资源一样, **AdController**的初始化被放在一个map数据结构里面, 之后会循环这个map, 调用对应的初始化函数.

[https://github.com/kubernetes/kubernetes/blob/v1.22.0/cmd/kube-controller-manager/app/controllermanager.go#L442](https://github.com/kubernetes/kubernetes/blob/v1.22.0/cmd/kube-controller-manager/app/controllermanager.go#L442)

```go
// 初始化函数, 随着kube-controller-manager的启动,启动一个AdController.
func startAttachDetachController(ctx ControllerContext) (http.Handler, bool, error) {
	if ctx.ComponentConfig.AttachDetachController.ReconcilerSyncLoopPeriod.Duration < time.Second {
		return nil, true, fmt.Errorf("duration time must be greater than one second as set via command line option reconcile-sync-loop-period")
	}
  // 分别实例化csiNode 和 csiDriver 的Informer.
	csiNodeInformer := ctx.InformerFactory.Storage().V1().CSINodes()
	csiDriverInformer := ctx.InformerFactory.Storage().V1().CSIDrivers()
  // 探测可用的 Plugin, 也就是k8s支持的 Intree 存储插件，如 RDB, NFS iscsi.
	plugins, err := ProbeAttachableVolumePlugins()
	if err != nil {
		return nil, true, fmt.Errorf("failed to probe volume plugins when starting attach/detach controller: %v", err)
	}

	filteredDialOptions, err := options.ParseVolumeHostFilters(
		ctx.ComponentConfig.PersistentVolumeBinderController.VolumeHostCIDRDenylist,
		ctx.ComponentConfig.PersistentVolumeBinderController.VolumeHostAllowLocalLoopback)
	if err != nil {
		return nil, true, err
	}
  // 实例化一个 AdController,  
	attachDetachController, attachDetachControllerErr :=
		attachdetach.NewAttachDetachController(
			ctx.ClientBuilder.ClientOrDie("attachdetach-controller"),
			ctx.InformerFactory.Core().V1().Pods(),
			ctx.InformerFactory.Core().V1().Nodes(),
			ctx.InformerFactory.Core().V1().PersistentVolumeClaims(),
			ctx.InformerFactory.Core().V1().PersistentVolumes(),
			csiNodeInformer,
			csiDriverInformer,
			ctx.InformerFactory.Storage().V1().VolumeAttachments(),
			ctx.Cloud,
			plugins,
			GetDynamicPluginProber(ctx.ComponentConfig.PersistentVolumeBinderController.VolumeConfiguration),
			ctx.ComponentConfig.AttachDetachController.DisableAttachDetachReconcilerSync,
			ctx.ComponentConfig.AttachDetachController.ReconcilerSyncLoopPeriod.Duration,
			attachdetach.DefaultTimerConfig,
			filteredDialOptions,
		)
	if attachDetachControllerErr != nil {
		return nil, true, fmt.Errorf("failed to start attach/detach controller: %v", attachDetachControllerErr)
	}
  // AdController 以一个异步的方式启动.
	go attachDetachController.Run(ctx.Stop)
	return nil, true, nil
}
```

#### AD controller的组件

##### ActualStateOfWorld（ASW）

ActualStateOfWorld 是一组定义了当前系统下volume-Node的attach-detach 实际状态缓存.  对于这个缓存的操作都是线程安全的. 它的结构体如下:

```go
type actualStateOfWorld struct {
	// attachedVolumes is a map containing the set of volumes the attach/detach
	// controller believes to be successfully attached to the nodes it is
	// managing. The key in this map is the name of the volume and the value is
	// an object containing more information about the attached volume.
	attachedVolumes map[v1.UniqueVolumeName]attachedVolume

	// nodesToUpdateStatusFor is a map containing the set of nodes for which to
	// update the VolumesAttached Status field. The key in this map is the name
	// of the node and the value is an object containing more information about
	// the node (including the list of volumes to report attached).
	nodesToUpdateStatusFor map[types.NodeName]nodeToUpdateStatusFor

	// volumePluginMgr is the volume plugin manager used to create volume
	// plugin objects.
	volumePluginMgr *volume.VolumePluginMgr

	sync.RWMutex
}
```



##### DesiredStateOfWorld（DSW）

DesiredStateOfWorld 是一组定义了当前系统下Node-volume-pod的attach-detach期望状态缓存. 

```go
type desiredStateOfWorld struct {
	// nodesManaged is a map containing the set of nodes managed by the attach/
	// detach controller. The key in this map is the name of the node and the
	// value is a node object containing more information about the node.
	nodesManaged map[k8stypes.NodeName]nodeManaged
	// volumePluginMgr is the volume plugin manager used to create volume
	// plugin objects.
	volumePluginMgr *volume.VolumePluginMgr
	sync.RWMutex
}
```



##### reconciler

reconciler 是一个异步循环,同过attach\detach操作协调 ASW 和 DSW 状态.

```go
type reconciler struct {
	loopPeriod                time.Duration
	maxWaitForUnmountDuration time.Duration
	syncDuration              time.Duration
	desiredStateOfWorld       cache.DesiredStateOfWorld
	actualStateOfWorld        cache.ActualStateOfWorld
	attacherDetacher          operationexecutor.OperationExecutor
	nodeStatusUpdater         statusupdater.NodeStatusUpdater
	timeOfLastSync            time.Time
	disableReconciliationSync bool
	recorder                  record.EventRecorder
}
```



##### DesiredStateOfWorldPopulator

DesiredStateOfWorldPopulator 会定期的检查期望状态下的pod是否需要删除,  它也定时检查所有pod,看是否有需要挂载的volume的Pod然后添加到期望状态的缓存中.

```go
type desiredStateOfWorldPopulator struct {
	loopSleepDuration        time.Duration
	podLister                corelisters.PodLister
	desiredStateOfWorld      cache.DesiredStateOfWorld
	volumePluginMgr          *volume.VolumePluginMgr
	pvcLister                corelisters.PersistentVolumeClaimLister
	pvLister                 corelisters.PersistentVolumeLister
	listPodsRetryDuration    time.Duration
	timeOfLastListPods       time.Time
	csiMigratedPluginManager csimigration.PluginManager
	intreeToCSITranslator    csimigration.InTreeToCSITranslator
}
```



#### AD controller的运行

在AdController的初始化时,上诉的几个结构体已经初始化完成, 在运行阶段会以一下的流程进行:

1. adc.populateActualStateOfWorld() 根据Node.Status.VolumesAttached字段初始化ASW结构,保存系统中已存在的node-Volume关系.
2. adc.populateDesiredStateOfWorld() 根据系统中pod.Spec.Volumes字段初始化DSW结构, 在此过程中如果Pod的volume已经挂载到Node上则更新ASW,并标记该volume为Attach.
3. adc.reconciler.Run() 协调ASW和DSW状态. 
4. adc.desiredStateOfWorldPopulator.Run(stopCh) 监控Pod的变化退出的Pod做Detach操作, 新增的Pod做Attach操作.



##### reconciler.Run()  的运行

该部分的主要代码是**reconcile()**函数,  主要代码逻辑如下:

1. 遍历 ASW 中已经 attached 的 volume，判断 DSW 中是否存在，如果不存在，则调用 rc.attacherDetacher.DetachVolume 执行该 volume 的 Detach 操作.

   [https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L142](https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L142)

2. 遍历 DSW 中的所有Volume, 如果不存在在ASW中,则调用rc.attacherDetacher.AttachVolume执行该volume执行Attach操作.

   [https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L242](https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L242)

3. 更新Node.Status.VolumesAttached 的值.

   [https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L236](https://github.com/kubernetes/kubernetes/blob/v1.22.0/pkg/controller/volume/attachdetach/reconciler/reconciler.go#L236)

   

##### Attach/Detach操作

从上面的流程中可知, 执行attach的deatch的操作是rc.attacherDetacher这个结构体调用的. 它在AdController初始化的时候已经初始化了. 之后在传递给Reconciler.

```go
	adc.attacherDetacher =
		operationexecutor.NewOperationExecutor(operationexecutor.NewOperationGenerator(
			kubeClient,
			&adc.volumePluginMgr,
			recorder,
			false, // flag for experimental binary check for volume mount
			blkutil))
```

结构体如下:

```go
type operationExecutor struct {
	// pendingOperations keeps track of pending attach and detach operations so
	// multiple operations are not started on the same volume
	pendingOperations nestedpendingoperations.NestedPendingOperations

	// operationGenerator is an interface that provides implementations for
	// generating volume function
	operationGenerator OperationGenerator
}
```

这里以AttachVolume操作为例列举一下实际Attach的流程:

rc.attacherDetacher.AttachVolume() --> operationGenerator.GenerateAttachVolumeFunc() --> attachVolumeFunc()

最后的核心调用还是attachVolumeFunc()这个函数, 源码如下:

```go
	attachVolumeFunc := func() volumetypes.OperationContext {
    // 根据 volumeSpec 获取对应的Plugin, 比如说 RBD, Chef, 如果是CSI 就是CSI Plugin。 后面以CSI为列.
		attachableVolumePlugin, err :=
			og.volumePluginMgr.FindAttachablePluginBySpec(volumeToAttach.VolumeSpec)

		migrated := getMigratedStatusBySpec(volumeToAttach.VolumeSpec)

		if err != nil || attachableVolumePlugin == nil {
			eventErr, detailedErr := volumeToAttach.GenerateError("AttachVolume.FindAttachablePluginBySpec failed", err)
			return volumetypes.NewOperationContext(eventErr, detailedErr, migrated)
		}
    //  实例化 CSI Plugin  这里实际调用的是: https://github.com/kubernetes/kubernetes/blob/master/pkg/volume/csi/csi_plugin.go#L585
		volumeAttacher, newAttacherErr := attachableVolumePlugin.NewAttacher()
		if newAttacherErr != nil {
			eventErr, detailedErr := volumeToAttach.GenerateError("AttachVolume.NewAttacher failed", newAttacherErr)
			return volumetypes.NewOperationContext(eventErr, detailedErr, migrated)
		}

		// Execute attach 这个便是调用 csi 的Attach方法，看下面的分析
		devicePath, attachErr := volumeAttacher.Attach(
			volumeToAttach.VolumeSpec, volumeToAttach.NodeName)

		if attachErr != nil {
			uncertainNode := volumeToAttach.NodeName
			if derr, ok := attachErr.(*volerr.DanglingAttachError); ok {
				uncertainNode = derr.CurrentNode
			}
			addErr := actualStateOfWorld.MarkVolumeAsUncertain(
				volumeToAttach.VolumeName,
				volumeToAttach.VolumeSpec,
				uncertainNode)
			if addErr != nil {
				klog.Errorf("AttachVolume.MarkVolumeAsUncertain fail to add the volume %q to actual state with %s", volumeToAttach.VolumeName, addErr)
			}

			// On failure, return error. Caller will log and retry.
			eventErr, detailedErr := volumeToAttach.GenerateError("AttachVolume.Attach failed", attachErr)
			return volumetypes.NewOperationContext(eventErr, detailedErr, migrated)
		}

		// Successful attach event is useful for user debugging
		simpleMsg, _ := volumeToAttach.GenerateMsg("AttachVolume.Attach succeeded", "")
    
		for _, pod := range volumeToAttach.ScheduledPods {
			og.recorder.Eventf(pod, v1.EventTypeNormal, kevents.SuccessfulAttachVolume, simpleMsg)
		}
		klog.Infof(volumeToAttach.GenerateMsgDetailed("AttachVolume.Attach succeeded", ""))

		// Update actual state of world  更新ASW
		addVolumeNodeErr := actualStateOfWorld.MarkVolumeAsAttached(
			v1.UniqueVolumeName(""), volumeToAttach.VolumeSpec, volumeToAttach.NodeName, devicePath)
		if addVolumeNodeErr != nil {
			// On failure, return error. Caller will log and retry.
			eventErr, detailedErr := volumeToAttach.GenerateError("AttachVolume.MarkVolumeAsAttached failed", addVolumeNodeErr)
			return volumetypes.NewOperationContext(eventErr, detailedErr, migrated)
		}

		return volumetypes.NewOperationContext(nil, nil, migrated)
	}

	eventRecorderFunc := func(err *error) {
		if *err != nil {
			for _, pod := range volumeToAttach.ScheduledPods {
				og.recorder.Eventf(pod, v1.EventTypeWarning, kevents.FailedAttachVolume, (*err).Error())
			}
		}
	}

	attachableVolumePluginName := unknownAttachableVolumePlugin

	// Get attacher plugin
	attachableVolumePlugin, err :=
		og.volumePluginMgr.FindAttachablePluginBySpec(volumeToAttach.VolumeSpec)
	// It's ok to ignore the error, returning error is not expected from this function.
	// If an error case occurred during the function generation, this error case(skipped one) will also trigger an error
	// while the generated function is executed. And those errors will be handled during the execution of the generated
	// function with a back off policy.
	if err == nil && attachableVolumePlugin != nil {
		attachableVolumePluginName = attachableVolumePlugin.GetPluginName()
	}

	return volumetypes.GeneratedOperations{
		OperationName:     "volume_attach",
		OperationFunc:     attachVolumeFunc,
		EventRecorderFunc: eventRecorderFunc,
		CompleteFunc:      util.OperationCompleteHook(util.GetFullQualifiedPluginNameForVolume(attachableVolumePluginName, volumeToAttach.VolumeSpec), "volume_attach"),
	}
```

AdController 不负责实际的Attach操作, 它只是创建一个VolumeAttachment资源.

```go
func (c *csiAttacher) Attach(spec *volume.Spec, nodeName types.NodeName) (string, error) {
	if spec == nil {
		klog.Error(log("attacher.Attach missing volume.Spec"))
		return "", errors.New("missing spec")
	}

	pvSrc, err := getPVSourceFromSpec(spec)
	if err != nil {
		return "", errors.New(log("attacher.Attach failed to get CSIPersistentVolumeSource: %v", err))
	}

	node := string(nodeName)
	attachID := getAttachmentName(pvSrc.VolumeHandle, pvSrc.Driver, node)

	attachment, err := c.plugin.volumeAttachmentLister.Get(attachID)
	if err != nil && !apierrors.IsNotFound(err) {
		return "", errors.New(log("failed to get volume attachment from lister: %v", err))
	}

	if attachment == nil {
		var vaSrc storage.VolumeAttachmentSource
		if spec.InlineVolumeSpecForCSIMigration {
			// inline PV scenario - use PV spec to populate VA source.
			// The volume spec will be populated by CSI translation API
			// for inline volumes. This allows fields required by the CSI
			// attacher such as AccessMode and MountOptions (in addition to
			// fields in the CSI persistent volume source) to be populated
			// as part of CSI translation for inline volumes.
			vaSrc = storage.VolumeAttachmentSource{
				InlineVolumeSpec: &spec.PersistentVolume.Spec,
			}
		} else {
			// regular PV scenario - use PV name to populate VA source
			pvName := spec.PersistentVolume.GetName()
			vaSrc = storage.VolumeAttachmentSource{
				PersistentVolumeName: &pvName,
			}
		}
     // 实例化一个 VolumeAttachment 对象.
		attachment := &storage.VolumeAttachment{
			ObjectMeta: meta.ObjectMeta{
				Name: attachID,
			},
			Spec: storage.VolumeAttachmentSpec{
				NodeName: node,
				Attacher: pvSrc.Driver,
				Source:   vaSrc,
			},
		}
    // 请求 API 创建一个VolumeAttachment对象
		_, err = c.k8s.StorageV1().VolumeAttachments().Create(context.TODO(), attachment, metav1.CreateOptions{})
		if err != nil {
			if !apierrors.IsAlreadyExists(err) {
				return "", errors.New(log("attacher.Attach failed: %v", err))
			}
			klog.V(4).Info(log("attachment [%v] for volume [%v] already exists (will not be recreated)", attachID, pvSrc.VolumeHandle))
		} else {
			klog.V(4).Info(log("attachment [%v] for volume [%v] created successfully", attachID, pvSrc.VolumeHandle))
		}
	}
  // 等待VolumeAttachment的状态变成attach
	// Attach and detach functionality is exclusive to the CSI plugin that runs in the AttachDetachController,
	// and has access to a VolumeAttachment lister that can be polled for the current status.
	if err := c.waitForVolumeAttachmentWithLister(pvSrc.VolumeHandle, attachID, c.watchTimeout); err != nil {
		return "", err
	}

	klog.V(4).Info(log("attacher.Attach finished OK with VolumeAttachment object [%s]", attachID))

	// Don't return attachID as a devicePath. We can reconstruct the attachID using getAttachmentName()
	return "", nil
}
```



##### desiredStateOfWorldPopulator.Run(stopCh)的运行

作用：更新 desiredStateOfWorld，跟踪 desiredStateOfWorld 初始化后的后续变化更新。

主要调用了两个方法：

（1）dswp.findAndRemoveDeletedPods：更新 desiredStateOfWorld，从中删除已经不存在的 pod；

（2）dswp.findAndAddActivePods：更新 desiredStateOfWorld，将新增的 pod volume 加入 desiredStateOfWorld。

```go
func (dswp *desiredStateOfWorldPopulator) populatorLoopFunc() func() {
	return func() {
		dswp.findAndRemoveDeletedPods()

		// findAndAddActivePods is called periodically, independently of the main
		// populator loop.
		if time.Since(dswp.timeOfLastListPods) < dswp.listPodsRetryDuration {
			klog.V(5).Infof(
				"Skipping findAndAddActivePods(). Not permitted until %v (listPodsRetryDuration %v).",
				dswp.timeOfLastListPods.Add(dswp.listPodsRetryDuration),
				dswp.listPodsRetryDuration)

			return
		}
		dswp.findAndAddActivePods()
	}
}
```















































  