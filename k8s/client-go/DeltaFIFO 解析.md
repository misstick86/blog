## DeltaFIFO 解析

`DelatFIFO`是一个传统的先进先出队列,它从ListWatcher中接收数据，并将数据发送给informer。和`FIFO`队列不同主要在两个方面.





`DelatFIFO`也是一个生产者-消费之队列,其中**Reflector**是生产者,消费者是任何调用**Pop**方法的对象.



**DelteFIFO**主要使用在以下场景:

1. 每次对象更改时至少处理一下
2. 在处理该对象时,需要知道至上一次更改时发生了什么
3. 需要处理某些对象的删除
4. 需要定期的处理某些对象



DeltaFIFO在定义时本身也是一个Queue对象，所以在实现上代码如下:

```go
var (
	_ = Queue(&DeltaFIFO{}) // DeltaFIFO is a Queue
)
```

**DeltaFIFO**实现了**Queue**和**Store**的所有方法. 



## DeltaFIFO的具体实现

Delta是Deltas(是一个列表)的成员, 而Deltas是DeltaFIFO的存储类型。

#### 1. 首先来看看Deltas是什么

Delta的结构体定义如下:

```go
type Delta struct {
	Type   DeltaType
	Object interface{}
}
```

其中DeltaType是个**string**类型, **Object** 可以是任何一种类型。

**DeltaType**内置定义了5个操作: **Added**、 **Updated**、 **Deleted**、 **Replaced**、 **Sync**. 

而Deltas就是**Delta**这种结构体的列表，一个标准的存储如下:

```json
[{"Added": obj1}, {"Delete":obj1}, {"Replaced":obj1}....]
```

这里可以看到为什么都是**obj1**呢， 其实**DeltaFIFO**对象中是这么定义的:

```go
	items map[string]Deltas
```

这是一个map数据结构，key是根据算法计算的一个资源对象的，values是一个数组, 也就是每个资源的事件变更都会保存到这个数组中，所以索引0就是最老的变更资源，最后一个就是最新变更资源.



生产者和消费中都是在调用controller的RUN方法时启动的.

```go
	wg.StartWithChannel(stopCh, r.Run)

	wait.Until(c.processLoop, time.Second, stopCh)
```



## 生产者方法

生产者是和Reflector相关联的, DeltaFIFO实例化的Queue对应也是被关联到Reflector的store对象中. 这ListAndWatch资源对象是都是想store中添加、修改、删除资源.

DeltaFIFO队列的方法中不管是ADD、Delete、Update事件都调用了底层的**queueActionLocked**方法,该方法接收一个`action`动作和一个对象.

```go
func (f *DeltaFIFO) queueActionLocked(actionType DeltaType, obj interface{}) error {
  // 计算出该对应的key, 通常以pod为列： namespace/pod-name  --> default/mypod-123
	id, err := f.KeyOf(obj)
	if err != nil {
		return KeyError{obj, err}
	}
  // 获取该资源已有的资源列表，并将新的资源对象添加到最后
	oldDeltas := f.items[id]
	newDeltas := append(oldDeltas, Delta{actionType, obj})
  // 去重操作
	newDeltas = dedupDeltas(newDeltas)

	if len(newDeltas) > 0 {
    // 像queue中添加对应的objkey
		if _, exists := f.items[id]; !exists {
			f.queue = append(f.queue, id)
		}
    // 像对应的Deltas中更新资源
		f.items[id] = newDeltas
		f.cond.Broadcast()
	} else {
		// This never happens, because dedupDeltas never returns an empty list
		// when given a non-empty list (as it is here).
		// If somehow it happens anyway, deal with it but complain.
		if oldDeltas == nil {
			klog.Errorf("Impossible dedupDeltas for id=%q: oldDeltas=%#+v, obj=%#+v; ignoring", id, oldDeltas, obj)
			return nil
		}
		klog.Errorf("Impossible dedupDeltas for id=%q: oldDeltas=%#+v, obj=%#+v; breaking invariant by storing empty Deltas", id, oldDeltas, obj)
		f.items[id] = newDeltas
		return fmt.Errorf("Impossible dedupDeltas for id=%q: oldDeltas=%#+v, obj=%#+v; broke DeltaFIFO invariant by storing empty Deltas", id, oldDeltas, obj)
	}
	return nil
}
```



## 消费者方法

DeltasFIFO对应的Pop方法时作为消费者的方法使用,该函必须接收一个回调函数来处理对应的数据.

```go
func (f *DeltaFIFO) Pop(process PopProcessFunc) (interface{}, error)
```

```go
	defer f.lock.Unlock()
	for {
		for len(f.queue) == 0 {
			// When the queue is empty, invocation of Pop() is blocked until new item is enqueued.
			// When Close() is called, the f.closed is set and the condition is broadcasted.
			// Which causes this loop to continue and return from the Pop().
			if f.closed {
				return nil, ErrFIFOClosed
			}
			// 队列为空，一直阻塞住
			f.cond.Wait()
		}
    // 获取队列里第一个元素并更新队列
		id := f.queue[0]
		f.queue = f.queue[1:]
		if f.initialPopulationCount > 0 {
			f.initialPopulationCount--
		}
    // 从Deltas中取出对应的obj
		item, ok := f.items[id]
		if !ok {
			// This should never happen
			klog.Errorf("Inconceivable! %q was in f.queue but not f.items; ignoring.", id)
			continue
		}
		delete(f.items, id)
    // 处理对应的obj
		err := process(item)
		if e, ok := err.(ErrRequeue); ok {
			f.addIfNotPresent(id, item)
			err = e.Err
		}
		// Don't need to copyDeltas here, because we're transferring
		// ownership to the caller.
		return item, err
	}
```

不同的informer实例化时定义的Process函数是不一样的。 其本质都是将obj存储至indexers中. 看一下简单的定义如下:

```go
		Process: func(obj interface{}) error {
			// from oldest to newest
			for _, d := range obj.(Deltas) {
				switch d.Type {
				case Sync, Replaced, Added, Updated:
					if old, exists, err := clientState.Get(d.Object); err == nil && exists {
            // clientstate是一个indexer实例化后的对象
            // 更新indexer中对应的obj.
						if err := clientState.Update(d.Object); err != nil {
							return err
						}
            // 调用我们自定义的update函数
						h.OnUpdate(old, d.Object)
					} else {
						if err := clientState.Add(d.Object); err != nil {
							return err
						}
            // 调用我们自定义的add函数
						h.OnAdd(d.Object)
					}
				case Deleted:
					if err := clientState.Delete(d.Object); err != nil {
						return err
					}
          // 调用我们自定义的delete函数
					h.OnDelete(d.Object)
				}
			}
			return nil
		},
```













