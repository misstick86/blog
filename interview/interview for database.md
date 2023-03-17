## MySQL

#### MySQL 数据库的隔离级别


## Etcd or Blotdb

#### ETCD的Treeindex是什么

由Google的 [btree](https://github.com/google/btree) 存储的一个keyIndex值. `KeyIndex` 存储的是某个的key的修改版本.  全局之中只有一个B-Tree. 

#### TreeIndex为什么使用btree

btree是存储在内存之中, 并且支持范围查询, 如果使用hash表或者AVL树之内的数据结构, AVL由于是一个平衡二叉树, 数据高度会很大, 对于较多读的情况下反而影响速度.




#### ETCD数据不能太大的原因

- 启动耗时, 需要打开bblot的db文件读取key-value数据,重建treeindex模块. 其中`Insert()`函数会施加锁,
- 内存较小的情况下导致缺页中断, 由于mmap也db文件映射到内存中缺页会导致性能下降.
- treeindex设计缺陷, 不支持数据分片,大量的key情况下会增加查询,修改的延迟.
- 大量的key情况下提交事务会触发b+tree的重平衡，增加延迟
- 一但客户端出现`expensive request`,很容易将带宽打满, 导致不稳定
- 当出现follower重建时,大的快照也会更多的带宽，cpu资源




