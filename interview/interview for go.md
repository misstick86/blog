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