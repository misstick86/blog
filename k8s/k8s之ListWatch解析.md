## k8s之ListWatch解析

![client](/Users/xiaosongsong/code/my_blog/static/images/k8s/client-go-controller-interaction.jpeg)

Client-go中ListWatch是负责对api-server进行监控的组件,可以说kubernetes系统中任何事件的更新都依赖于Listwatch发现.  所以这一节我们将探讨一下它是如何做到的.









ListWatch是由**List**和**Watch**接口组合而成。

```go
// Lister is any object that knows how to perform an initial list.
type Lister interface {
	// List should return a list type object; the Items field will be extracted, and the
	// ResourceVersion field will be used to start the watch in the right place.
	List(options metav1.ListOptions) (runtime.Object, error)
}
```

```go
// Watcher is any object that knows how to start a watch on a resource.
type Watcher interface {
	// Watch should begin a watch at the specified version.
	Watch(options metav1.ListOptions) (watch.Interface, error)
}
```

```go
// ListerWatcher is any object that knows how to perform an initial list and start a watch on a resource.
type ListerWatcher interface {
	Lister
	Watcher
}
```





看完了ListWatch的接口我们来看一下对应的结构体是如何设计的.

```go
type ListWatch struct {
	ListFunc  ListFunc
	WatchFunc WatchFunc
	// DisableChunking requests no chunking for this list watcher.
	DisableChunking bool
}
```





## 一切源于Reflector

从上图可以看出,**ListandWatch**只是一个简单的执行过程，其具体的对象是放在Reflector中. 

```go
	r := NewReflector(
		c.config.ListerWatcher,
		c.config.ObjectType,
		c.config.Queue,
		c.config.FullResyncPeriod,
	)
```

具体的调用是放在*Reflector*的`Run`方法中.



## ListAndWatch具体实现

这里以POD资源为例，其他资源类似.

ListAndWatch函数的具体实现可以分为两部分: 第一部分是获取pod资源列表数据， 第二部分是监控pod资源对象. 

```go
	pager := pager.New(pager.SimplePageFunc(func(opts metav1.ListOptions) (runtime.Object, error) {
				return r.listerWatcher.List(opts)
			}))
  list, paginatedResult, err = pager.List(context.Background(), options)
```

**pager**封装了一个带分页列表的请求对象，具体请求时调用**List**函数获取对应的资源.

而**List**函数则实际调用了封装在**ListWatch**结构中的ListFunc函数， 该函数则通过调用pod资源的方法获取一个或多个pod资源对象.

```go
	listFunc := func(options metav1.ListOptions) (runtime.Object, error) {
		optionsModifier(&options)
		return c.Get().
			Namespace(namespace).
			Resource(resource).
			VersionedParams(&options, metav1.ParameterCodec).
			Do(context.TODO()).
			Get()
	}
```

获取资源是由opts的ResourceVersion(资源版本号)参数控制的,如果参数为0,则表示获取所有的pod的资源，如果ResourceVersion为非0,则表示根据资源版本号据需获取.

```go
		resourceVersion = listMetaInterface.GetResourceVersion()
		initTrace.Step("Resource version extracted")
		items, err := meta.ExtractList(list)
		if err != nil {
			return fmt.Errorf("unable to understand list result %#v (%v)", list, err)
		}
		initTrace.Step("Objects extracted")
		if err := r.syncWith(items, resourceVersion); err != nil {
			return fmt.Errorf("unable to sync list result: %v", err)
		}
		initTrace.Step("SyncWith done")
    
		r.setLastSyncResourceVersion(resourceVersion)
		initTrace.Step("Resource version updated")
```

之后就是将获取到的pod资源对象保存在DeltaFiFO中,并设置当前的ResourceVersion.

所以获取资源列表的大致流程图如下:

```json
              ------------------------------
              | r.listerWatcher.List(opts) |   //获取pod资源数据
              ------------------------------
                            |
              ------------------------------
        | rlistMetaInterface.GetResourceVersion() |   // 获取资源列表
              ------------------------------        
                            |
              ------------------------------
              |    meta.ExtractList(list)  |   // 将获取到的资源对象，装换成资源对象列表
              ------------------------------  
                            |
              ------------------------------
          | r.syncWith(items, resourceVersion) |   // 同步到DeltaFIFO中
              ------------------------------
                            |        
              ------------------------------
     | r.setLastSyncResourceVersion(resourceVersion) |   //更新RecourseVersion
              ------------------------------
```



#### 来看一下如何watch对应的资源

首先，watch一个pod资源也是通过informer下的watchFun函数，它通过clientset客户端与api-server建立长链接，监控指定资源的变更事件. watchFunc的代码如下:

```go
	watchFunc := func(options metav1.ListOptions) (watch.Interface, error) {
		options.Watch = true
		optionsModifier(&options)
		return c.Get().
			Namespace(namespace).
			Resource(resource).
			VersionedParams(&options, metav1.ParameterCodec).
			Watch(context.TODO())
	}
```

启动一个watch pod如下:

```go
w, err := r.listerWatcher.Watch(options) //封装一个watch对象
err := r.watchHandler(start, w, &resourceVersion, resyncerrc, stopCh); // 处理资源的变更
```

watchHandler主要处理event事件的变更,代码如下:

```go
		case watch.Added:
				// 处理add事件，并将改事件对象更新到DeleatFIFO中。
				err := r.store.Add(event.Object)
				if err != nil {
					utilruntime.HandleError(fmt.Errorf("%s: unable to add watch event object (%#v) to store: %v", r.name, event.Object, err))
				}
			case watch.Modified:
				err := r.store.Update(event.Object)
				if err != nil {
					utilruntime.HandleError(fmt.Errorf("%s: unable to update watch event object (%#v) to store: %v", r.name, event.Object, err))
				}
			case watch.Deleted:
				// TODO: Will any consumers need access to the "last known
				// state", which is passed in event.Object? If so, may need
				// to change this.
				err := r.store.Delete(event.Object)
				if err != nil {
					utilruntime.HandleError(fmt.Errorf("%s: unable to delete watch event object (%#v) from store: %v", r.name, event.Object, err))
				}
```

watchHandler每次监听为一个周期，外部有一个死循环控制.

事件的接收则通过如下代码：

```go
		case event, ok := <-w.ResultChan():
```

那么事件是如何传递的呢？

