#### slice和array的区别



#### 函数传指针和传值有什么区别？

- 值传递本身是对参数的copy, 在函数中修改形参的值不会改变外面实参的值
- 指针传递本身传递的指针, 修改的值也是指针指向的地址,所以外部的实参也会发生改变.


#### new和make有什么区别？

1. New通常用于初始化自定义类型 make用于初始化内置类型如 slice, map, channel.
2. New 不会初始化内存,只是为其赋值为`零值`,并返回一个指向改类型的指针.
3. make 会初始化该类型被为期分配内存,返回的是指向改类型的值.


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


#### 讲讲go的GC  

参考: [go 内存回收](https://zhuanlan.zhihu.com/p/297177002)


#### Go内存分配


#### Go内存逃逸

内存逃逸是指栈内存中的数据有于某些原因被放在堆内存中, 由堆进行分配和回收.

发生内存逃逸的时机:

- 函数中的局部变量被返回到其他地方使用, 由于函数生命周期结束只能放在堆中.
- channel中传递指针, golang并不知道哪个Goroutine会处理,什么时候释放变量,只能交由堆内存管理.
- slice无限扩大,  slice主要放在栈内存中, 但当超过栈内存最大值, 会将slice放入堆中.
- interface无法确定类型也会发生逃逸.
- 
指令集 -gcflags 用于将标识参数传递给 Go 编译器, -m 会打印出逃逸分析的优化策略。


#### go调度中阻塞都有那些方式


#### go 中slice 和 array的区别

-   声明数组时，方括号内写明了数组的长度或者...,声明slice时候，方括号内为空
-   作为函数参数时，数组传递的是数组的副本，而slice传递的是指针。


####  向为 nil 的 channel 发送数据会怎么样

```shell

fatal error: all goroutines are asleep - deadlock!

```

channle 未初始化,触发一个**fatal error**.

#### go的map实现原理


#### go-rountine 池介绍



