## Metadata
对于Metadata来说,  其本身也是一个插件, 在containerd启动时手动将metadata插件注册到Plugin 注册中心中.  在containerd中它的文件名叫做:`meta.db`.

实现metadata的核心数据结构是 *DB*,  它的定义如下:

```go
type DB struct {
	db *bolt.DB
	ss map[string]*snapshotter
	cs *contentStore

	// 此处的锁主要是对垃圾回收阶段对数据的保护, 当锁被持有时不能进行读写事务, 从而防		      止了数据更改, 但不影响读事务.	
	wlock sync.RWMutex


	dirty uint32

	// dirtySS 和 dirtyCS 主要用来跟踪自上次垃圾回收后删除的对象, 在下次垃圾回收过程中      将其删除, 注意: 这个操作只能在事务或者wlock.Lock锁中操作.
	dirtySS map[string]struct{}
	dirtyCS bool

	// mutationCallbacks are called after each mutation with the flag
	// set indicating whether any dirty flags are set
	mutationCallbacks []func(bool)

	dbopts dbOptions
}
```

以上数据结构的初始化是在 metadata Plugin 的初始化中, 经过依赖检查后,便打开了这个`meta.db` 的文件, 然后实例化和做一些初始化.

[https://github.com/containerd/containerd/blob/main/services/server/server.go#L408](https://github.com/containerd/containerd/blob/main/services/server/server.go#L408)

## 流程

这里同过 nmesapce 的创建过程,  看看数据是如何保存在 `meta.db`数据库里面的.  在介绍Plugin时说过, Service 类型的 Plugin 是 GRPC Plugin 的具体实现.  所以在创建一个**namespace**时,  实际上调用是如下方法:

[https://github.com/containerd/containerd/blob/main/services/namespaces/local.go#L118](https://github.com/containerd/containerd/blob/main/services/namespaces/local.go#L118)

在 *Create* 函数内部调用的是 *withStoreUpdate* 函数,  这个函数会调用**DB** 数据结构的一个*Update* 方法,  这个函数接受的是带有如下参数的函数:

```go
func(tx *bolt.Tx) error {

}
```

BoltBD 将控制写事务的工作交个了开发者, 在实际执行update时需要为这个操作加上锁, 这个操作也是在上面的函数上做的.

`l.withStore(ctx, fn)` 这个参数便是生成上述的函数.

上诉函数同过参数传递后最后交给 *Blotdb* 的 *Update* 函数执行, 实际执行的方法便是传递给*withStoreUpdate* 函数. 代码如下:

```go
	if err := l.withStoreUpdate(ctx, func(ctx context.Context, store namespaces.Store) error {
		if err := store.Create(ctx, req.Namespace.Name, req.Namespace.Labels); err != nil {
			return errdefs.ToGRPC(err)
		}

		for k, v := range req.Namespace.Labels {
			if err := store.SetLabel(ctx, req.Namespace.Name, k, v); err != nil 		        {
				return err
			}
		}

		resp.Namespace = req.Namespace
		return nil
	}); err != nil {
		return &resp, err
	}
```

参数 *store* 是一个包含 `bolt.Tx` 的结构体,  调用的*create*方法实际上执行写入blotdb一些逻辑的操作. 

```go
func (s *namespaceStore) Create(ctx context.Context, namespace string, labels map[string]string) error {
	// 创建最外层bucket
	topbkt, err := createBucketIfNotExists(s.tx, bucketKeyVersion)
	if err != nil {
		return err
	}
    // 验证 namnesapce 名称的合法性
	if err := identifiers.Validate(namespace); err != nil {
		return err
	}
    // 验证labels的合法性
	for k, v := range labels {
		if err := l.Validate(k, v); err != nil {
			return fmt.Errorf("namespace.Labels: %w", err)
		}
	}
	
	//  创建 namesapce 的 bucket.
	// provides the already exists error.
	bkt, err := topbkt.CreateBucket([]byte(namespace))
	if err != nil {
		if err == bolt.ErrBucketExists {
			return fmt.Errorf("namespace %q: %w", namespace, errdefs.ErrAlreadyExists)
		}

		return err
	}
	// 在 namesapce 下创建 labels bucket.
	lbkt, err := bkt.CreateBucketIfNotExists(bucketKeyObjectLabels)
	if err != nil {
		return err
	}
    // 将 labels 信息放入 bucket 中.
	for k, v := range labels {
		if err := lbkt.Put([]byte(k), []byte(v)); err != nil {
			return err
		}
	}

	return nil
}
```