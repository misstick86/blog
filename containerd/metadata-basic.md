在介绍MetaData之前有必要先了解一下boltdb这个数据库, 它是一款非常优秀的key-value类型的存储, 像etcd都是基于boltdb之上构建的.

> boltdb 的项目地址 [https://github.com/etcd-io/bbolt](https://github.com/etcd-io/bbolt)
## BoltDB 介绍

BoltDB 项目的目标是提供一个简单,快速,可靠的数据库, 而且不会像 Postgres 或者 MySQL那样提供完整的功能. 
- **纯go:** 意味着该项目只由golang语言开发，不涉及其他语言的调用。因为大部分的数据库基本上都是由c或者c++开发的，boltdb是一款难得的golang编写的数据库。

- **支持事务:** boltdb数据库支持两类事务：**读写事务**、**只读事务**、 **批量读写事务**。这一点就和其他kv数据库有很大区别。

- **文件型:** boltdb所有的数据都是存储在磁盘上的，所以它属于文件型数据库。这里补充一下个人的理解，在某种维度来看，boltdb很像一个简陋版的innodb存储引擎。底层数据都存储在文件上，同时数据都涉及数据在内存和磁盘的转换。但不同的是，innodb在事务上的支持比较强大。

- **单机:** boltdb不是分布式数据库，它是一款单机版的数据库。个人认为比较适合的场景是，用来做wal日志或者读多写少的存储场景。

- **kv数据库：** boltdb不是sql类型的关系型数据库，它和其他的kv组件类似，对外暴露的是kv的接口，不过boltdb支持的数据类型key和value都是[]byte。

更多关于BoltDB的介绍可以参考如下:
[https://www.bookstack.cn/read/jaydenwen123-boltdb_book/00fe39712cec954e.md](https://www.bookstack.cn/read/jaydenwen123-boltdb_book/00fe39712cec954e.md)

## MetaData 介绍

MetaData是由boltdb支持的元数据数据库, 该数据库存储的有namesapce, lable, containers等等.  MetaData也包含主要的垃圾回收逻辑, 并且是原子的自动的方式.

在boltDb中最重要的概率是bucket, metadata的设计存储bucket如下:

```
	<version>/<namespace>/<object>/<key> -> <field>
```

- version:  当前使用的是`v1`, 
- namespace:  当前资源所属的Namespace.
- object : 存储在bucket中的对象类型. 有两个比较特殊的对象 `labels` and `indexes`. `labels` 用于保存父namespace的标签, `indexes`用于保留索引对象.
- key: 存储当前bucket对象的特定资源的名称.
-  field: 每一个bucket存储的实际数据.

以containers资源为例,存储在blotdb中的数据如下:
```
//  ├──version : <varint>                        - Latest version, see migrations  
//  └──v1                                        - Schema version bucket  
//     ╘══*namespace*							 - namesapce 
//        ├──containers  						 - object
//        │  ╘══*container id*  			     - container name
//        │     ├──createdat : <binary time>     - Created at  
//        │     ├──updatedat : <binary time>     - Updated at  
//        │     ├──spec : <binary>               - Proto marshaled spec  
//        │     ├──image : <string>              - Image name  
//        │     ├──snapshotter : <string>        - Snapshotter name  
//        │     ├──snapshotKey : <string>        - Snapshot key  
//        │     ├──runtime  
//        │     │  ├──name : <string>            - Runtime name  
//        │     │  ├──extensions  
//        │     │  │  ╘══*name* : <binary>       - Proto marshaled extension  
//        │     │  └──options : <binary>         - Proto marshaled options  
//        │     └──labels  
//        │        ╘══*key* : <string>           - Label value
```

以上在便是在metadata的bucket中存储的布局, 你可以使用一下代码查看对应bucket的信息.

```go
/**
 * @Author: wusong
 * @Description:
 * @File:  viewer.go
 * @Version: 1.0.0
 * @Date: 2022/1/25 6:53 PM
 */

package main

import (
	"errors"
	"flag"
	"fmt"
	bolt "go.etcd.io/bbolt"
	"os"
	"strings"
)

var key = flag.String("key","v1","key is bucket")
var file = flag.String("file", "./meta.db", "file is meta db")

func PathExists(path string) (bool, error) {
	_, err := os.Stat(path)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, errors.New("file not exists")
	}
	return false, errors.New("file not exists")
}

func getBucket(tx *bolt.Tx, key string) *bolt.Bucket {
	keys := strings.Split(key,"/")
	bkt := tx.Bucket([]byte(keys[0]))
	for _, key := range keys[1:] {
		if bkt == nil {
			break
		}
		bkt = bkt.Bucket([]byte(key))
	}

	return bkt
}

func main() {

	flag.Parse()
	if ok, err := PathExists(*file); !ok {
		fmt.Println(err)
		os.Exit(-1)
	}

    db, err := bolt.Open(*file,  0600, nil)
    if err != nil {
           panic(err)
    }
    db.View(func(tx *bolt.Tx) error {
		b := getBucket(tx, *key)
		c := b.Cursor()
		for k, v := c.First(); k != nil; k, v = c.Next() {
			fmt.Printf("key=%s, value=%s\n", k, v)
		}
       return nil
    })
}
```

同过编译以上代码可以查看containerd中的meta.db文件的数据:

```shell
edianyun@xiaosongsong  ~/code/go/demo  go build viewer.go
edianyun@xiaosongsong  ~/code/go/demo  ./viewer -key v1/default
v1
key=containers, value=
key=content, value=
key=images, value=
key=leases, value=
key=snapshots, value=
edianyun@xiaosongsong  ~/code/go/demo  ./viewer -key v1/default/containers
v1
key=nginx-1, value=
edianyun@xiaosongsong  ~/code/go/demo  ./viewer -key v1/default/containers/nginx-1
v1
key=createdat, value=�^w"�����
key=image, value=docker.io/library/nginx:alpine
key=labels, value=
key=runtime, value=
key=snapshotKey, value=nginx-1
key=snapshotter, value=overlayfs
...
```

元数据在bucket中存储是一种层级格式, 以不通的namesapce进行分割.具体可参考:

[https://github.com/containerd/containerd/blob/main/metadata/buckets.go#L27](https://github.com/containerd/containerd/blob/main/metadata/buckets.go#L27)