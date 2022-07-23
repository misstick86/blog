#### slice和array的区别

-   声明数组时，方括号内写明了数组的长度或者...,声明slice时候，方括号内为空
-   作为函数参数时，数组传递的是数组的副本，而slice传递的是指针。


#### 函数传指针和传值有什么区别？

- 值传递本身是对参数的copy, 在函数中修改形参的值不会改变外面实参的值
- 指针传递本身传递的指针, 修改的值也是指针指向的地址,所以外部的实参也会发生改变.


#### Go 如何静态的去看线程是否安全

可以使用 go run -race 或者 go build -race来进行静态检测。


#### new和make有什么区别？

1. New通常用于初始化自定义类型 make用于初始化内置类型如 slice, map, channel.
2. New 不会初始化内存,只是为其赋值为`零值`,并返回一个指向改类型的指针.
3. make 会初始化该类型被为期分配内存,返回的是指向改类型的值.


#### sync.map与map的区别，怎么实现的

- map 是一个简单的数据结构, 用于存储key-value类型. 但是它不是线程安全的
- sync.map在map的基础上引用锁, 保障了线程安全.

**Map** 的实现

go 原生的map数据结构, 采用hash的方式实现, 底层有 `hmap` 和 `bmap` 两个数据结构.

- `hmap` : map的header, 用户保存map的基础信息, 如: map的个数、map的存储信息等.
- `bmap` : key-value实际存储的地方,  以数组的方式被 `hmap` 引用, 改数据结构由编译器自动修改.

**Sync.Map**实现

如果想要拥有一个线程安全的map, 一个锁加上原生map就可以了. 每次对map的读写都加上锁，这样就可以保证了并发安全.

Sync.map的大致实现也是如此, 不过引用一个原则操作的readonly. 这样可以使得map适用于读多写少的场景.


#### channel了解吗，channel的工作原理是什么？

channel 是一个通道，从使用上来说看像是一个队列. 使用方式如下:

```go
ch := make(chan int, num)
```

`num` 是channel的大小, 如果不指定可以认定为1.

它有一下特点:

1. channel的大小一般固定的,当生产者过快时会block, 等待channel中有可使用空间.
2. 当没有数据向channel中发送时, 消费者将会block.



#### 讲讲Golang的调度模型

这个问题主要问的是 Golang 的 GMP 调度原理.

- G:  通常可以理解为一个goroutine, 程序中在`go`关键字后面的执行体.
- M: 工作线程, 可以理解为操作系统的线程
- P: 可以粗暴的理解为CPU的核数, 可以同过变量`GOMAXPROCS`修改.

参考: [Golang 调度](https://zhuanlan.zhihu.com/p/352964026)


#### go 怎么实现func的自定义参数  

使用 function option 功能实现.

```go
package main  
  
import "fmt"  
  
type StudentDemo struct {  
   name string  
   age  int  
}  
  
type Option func(*StudentDemo)  
  
func NewStudentWithName(name string) Option {  
   return func(s *StudentDemo) {  
      s.name = name  
   }  
}  
  
func NewStudent(opt ...Option) *StudentDemo {  
   s := StudentDemo{name: "1", age: 10}  
   for _, v := range opt {  
      v(&s)  
   }  
   return &s  
}  
  
func main() {  
   s := NewStudent(NewStudentWithName("hello"))  
   fmt.Println(s.name)  
  
}
```



#### Go内存分配

Go的内存分配主要采用的是Google的TaMelloc思想.  首先, 将分配器分为三个阶段: `mcache`, `mcentral`, `mheap`.  

- `mcache`: 线程分配器, 在初始化时为每个线程预分配一些内存资源, 小对象可以直接从上面分配
- `mcentral`: 线程中共享的分配器, 当`mcache`中没有内存存储后会向这个地方申请
- `mheap`: 抽象操系统的内存,并向`mcentral`提供内存空间

> 注: `mcentral` 和 `mheap` 在操作时都是需要加锁访问的.

除此之外, go内存还抽象出 **Page** 和 **Span** 的概念:

`Page`:  页的大小, 在x86的系统上一般是8kb.
`Span`:  由多个页组成, 是go内存管理的最小单位.

为了方便管理，go在`mcache`和`mcentral`中都引用了`对象大小等级`这个概念. 以`mcache`为列,  在准备内存资源的时候会有 `8kb`, `16kb`, `32kb` 的内存链表, 当为一个对像分配内存时会判断改对象的大小处在某个等级,再行分配.

`mcentral` 向 `mheap` 申请内存的时候不在适用上面的方案, 因为 `mheap` 本质上由一个个`span`组成, 数据结构上也不太一样.


#### Go内存逃逸

内存逃逸是指栈内存中的数据有于某些原因被放在堆内存中, 由堆进行分配和回收.

发生内存逃逸的时机:

- 函数中的局部变量被返回到其他地方使用, 由于函数生命周期结束只能放在堆中.
- channel中传递指针, golang并不知道哪个Goroutine会处理,什么时候释放变量,只能交由堆内存管理.
- slice无限扩大,  slice主要放在栈内存中, 但当超过栈内存最大值, 会将slice放入堆中.
- interface无法确定类型也会发生逃逸.
- 
指令集 -gcflags 用于将标识参数传递给 Go 编译器, -m 会打印出逃逸分析的优化策略。


#### 讲讲go的GC  

参考: [go 内存回收](https://zhuanlan.zhihu.com/p/297177002)


#### go调度中阻塞都有那些方式


####  向为 nil 的 channel 发送数据会怎么样

```shell

fatal error: all goroutines are asleep - deadlock!

```

channle 未初始化,触发一个**fatal error**.


#### go-rountine pool

Pool 主要思想是控制 goroutine 的数量, 事先生成一定的goroutine等待任务的到来. 在设计上任务可以同过channel传递.



