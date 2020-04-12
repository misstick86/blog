---
title: "从socket看事件驱动"
date: 2020-04-11T16:01:23+08:00
lastmod: 2020-04-11T16:01:23+08:00
draft: false
tags: []
categories: []
---

## 前言
最近一段时间在看werkzegu的源码，也就顺手自己实现了一个类似werkzuge的功能代码，但写完后用`ab`压测发现不能支持并发，每个请求都是串行的，这也就引起了我极大的疑惑，顾来写这边文章记录一下. 以下是疑虑的问题所在:

1. 为什么使用`ab`压测**werkzuge**可以实现并发处理http请求(注：不是真正的并发，只是在请求上)，底层用了什么技术.(io事件驱动)
2. io事件驱动和多线程和多进程有什么关系呢？(也考虑过和协程的关系)

带着这样的问题，我做了以下的代码编写.

<!--more-->

## Http服务实现

我们知道HTTP服务是建立在四层TCP基础之上的,采用的方式为一问一答形式,对应HTTP中的术语为**request**和**response**.

#### requests

客户端发送一个HTTP请求到服务器的请求消息包括以下格式：请求行（request line）、请求头部（header）、空行和请求数据四个部分组成.
一个典型的使用GET方法来传递数据的实例如下:
```
GET /hello.txt HTTP/1.1
User-Agent: curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3
Host: www.example.com
Accept-Language: en, mi
```
#### response

和客户端请求类型,response也包含四部分: 状态行、消息报头、空行和响应正文。

```
HTTP/1.1 200 OK
Date: Mon, 27 Jul 2009 12:28:53 GMT
Server: Apache
Last-Modified: Wed, 22 Jul 2009 19:15:56 GMT

Hello World! My payload includes a trailing CRLF.
```

基于以上对HTTP的定义，我们可以使用socket简单实现一个HTTP服务如下:

```
import socket,json,time
addr_port = ('127.0.0.1', 8000)
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(addr_port)
    s.listen(1)
    print("listen: http://%s:%s" % addr_port)
    while True:
        conn, addr = s.accept()
        with conn:
            data = conn.recv(1024)
            print('conn: IP %s, port: %s' % addr)
            print(data);
            if not data: break
            time.sleep(5)
            conn.send('HTTP/1.1 200 OK\r\n\r\n'.encode())
            conn.sendall(json.dumps({'code':200,'msg':'success'}).encode())
    s.close()
```

此时你可以通过浏览器或者使用`curl`命令来作为http客户端发起请求，可以看到服务器响应了一个json格式的数据.

```
➜  ~ curl http://127.0.0.1:8000
{"code": 200, "msg": "success"}
```

到此可以说我们实现了http协议中定义的最基础的功能:请求和响应. 如果此时你使用如`ab`这个样的压测工具你会发现不管有没有指定并发你都会发现请求是串行化的,也就是服务端必须等待上一个请求处理完成后才会接收下一个请求进行处理.

```
➜  ~ ab -c 10 -n 100 http://127.0.0.1:8000/
```

但对比与werkzuge来说，我们使用同样的压测方法，werkzegu一次可以接收10个并发请求(注意：是接收请求不是处理请求). 你可以这样验证：

将上面socket代码和werkzuge应用中的处理请求代码`sleep 5s`钟,分别使用`ab`进行并发10个,共100请求的测试,在5s之后中断`ab`测试.

- 自己写的socket： 处理1到2个请求后后端服务由于中断连接就关闭了
- werkzuge: 即使中断了`ab`测试了，但对于客户端来说一次并发的请求已经发出，服务端使用了事件驱动的方式也接收了客户端的请求，后续会继续处理请求，可以看到一共处理10请求，也正是客户端的一次并发数.

## IO事件select

在之前的一篇文章中讲过,werkzuge后端还是调用socketserver中的`serve_forever`方法来监听socket. 从源码上可以看出也是使用`select`,`poll`,`epoll`这样io事件模型. 我来详细描述下:

select, poll, epoll本质上都是同步的I/O，因为它们都是在读写事件就绪后自己负责进行读写，这个读写的过程是阻塞的,所以我们可以看到werkzuge虽然接收了并发的10个请求,但每个请求的响应还是串行的,也就是说响应这些请求的总时间是和我们自定义的单线程是一样的(50s).

select, poll, epoll 都是一种 I/O 复用的机制。它们都是通过一种机制(其实也就是轮训监听的描述符)来监视多个描述符，一旦某个描述符就绪了，就能通知程序进行相应的读写操作.Python中也提供了对应的模块实现该功能**select**!

**select** 模块实现了上述的三个I/O复用机制,我们来看一下select定义.

```
 def select(rlist, wlist, xlist, timeout=None):
```

这三个参数都是一个数组，数组中的内容均为一个文件描述符(file descriptor)对象或者一个拥有返回文件描述符方法`fileno()`的对象.

- rlist: 就绪读list
- wlist: 就绪写list
- xlist: 异常的list

`timeout`参数是一个浮点类型的参数,如果不传或者为**None**,那么调用将永远不会超时，也就是不会阻塞.

返回值为函数传递的三个参数的元组, 每个为当前已经准备好的对应的描述符！

我们来改写自己写的程序！

```
import time
import socket, select,json

l_addr=('127.0.0.1',8000)
def serve():
    s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    s.bind(l_addr)
    print("listen: http://%s:%s" % l_addr)
    s.listen(5)
    inputs =[s,]
    outputs=[]
    s.setblocking(True)
    while True:

        r,w,e=select.select(inputs,outputs,inputs)
        print("readables number: ", len(inputs))  #注释2
        for obj in r:
            if obj==s:
                conn,addr=obj.accept()
                conn.setblocking(0)
                inputs.append(conn)

            else:
                data_recv = obj.recv(1024)
                if not data_recv:
                    inputs.remove(obj)
                    if obj in outputs:
                        outputs.remove(obj)
                    obj.close()
                if data_recv:
                    if obj not in outputs:
                        outputs.append(obj)

        for obj in w:
            # print('deal socket...') # 注释1
            time.sleep(5)
            obj.send('HTTP/1.1 200 OK\r\n\r\n'.encode())
            obj.sendall(json.dumps({"ret":0,"msg":"success"}).encode())
            e.append(obj)

        for obj in e:
            inputs.remove(obj)
            if obj in outputs:
                outputs.remove(obj)
            obj.close()

```

对于上面的注释我在这里解释一下,前面说过select, poll, epoll本质上都是同步的I/O，因为它们都是在读写事件就绪后自己负责进行读写.所以说当它在负责读写的时候由于我们`sleep 5`秒钟，那么所有的socket处理数据都会阻塞掉，在当我停止`ab`压测时，由于当前的socket连接已经关闭，所以在**注释1**处就会出现报错.**注释2**是采用另一种方式验证,即统计当前就绪读状态下的**socket**的数量.

```
listen: http://127.0.0.1:8000
readables number:  1
readables number:  2
readables number:  3
readables number:  4
readables number:  5
readables number:  6
readables number:  7
readables number:  8
readables number:  9
readables number:  10
readables number:  11
```

我们这里指定并发10个请求,再加上处于监听的socket刚好11个. 这也就验证了上面所在的io事件驱动本质:**在接收请求中提供一种并发现象,在处理请求中本质是还是同步io**.

## io事件poll

#### select的缺点

- select 最多只能监听1024个描述符，当然这可以通过重新编译Linux内核在改变这个值.
- 每次对于监听的socket进行轮训查找是一个非常耗时的工作
- 轮训的操作有linux内核来完成，也就是文件描述符要进入内核空间,从内核空间到用户空间的开销很大

实际我在使用`ab`做压测统计时发现就绪读列表中最多也就400个左右.

#### poll的改进

poll本质上和select没有区别，只是没有了最大连接数(linux上默认1024个)的限制，原因是它基于链表存储的。

#### python中的poll
`select.poll()`: 返回一个poll对象,并支持`sizehint`参数来优化内部数据结构,该对象支持一下方法.

**eventmask**表示一个可选的掩码位,用于描述要检查的事件类型,其值是一下的集合：

| 名称      | 含义                                   |
| --------- | -------------------------------------- |
| POLLIN    | 有数据读                               |
| POLLPRI   | 有数据紧急读                           |
| POLLOUT   | 数据输出，并且不会阻塞                 |
| POLLERR   | 某种错误情况                           |
| POLLHUP   | 挂起T                                  |
| POLLRDHUP | 准备关闭流socket或等待另外一半连接关闭 |
| POLLNVAL  | 无效的请求：描述符未打开               |

- `register(self, fd, eventmask=None)`:  向poll对象中注册一个文件描述符,如果已经存在则抛出一个OS Error.
- `unregister(self, fd)`:  从poll对象中删除已经注册的描述符
- `modify(self, fd, eventmask)`: 修改一个已经注册的描述符,和`register`功能类似,如果尝试修改一个没有注册的描述符会触发一个OS Error.
- `poll(self, timeout=-1, maxevents=-1)`: 轮训已经注册的文件描述符,返回一个包含`(fd,event)`两个元素的元组列表. 如果列表为空则表示超时或者没有对应的io事件发生;`timeout`表示系统等待返回事件的超时时间，单位毫秒；如果为None,负数,或者不指定则一直阻塞下去.

用此种模式改写我们自己的socket服务如下:

```
import select, socket,time,json

l_addr=('127.0.0.1',8000)
def server():
    # init socket
    s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    s.bind(l_addr)
    print("listen: http://%s:%s" % l_addr)
    s.listen(1)
    s.setblocking(True)
    # init poll
    my_poll = select.poll()
    my_poll.register(s.fileno(),select.EPOLLIN)
    conn_dict={}
    try:
        while True:
            for fd, event in my_poll.poll():
                if event == select.POLLIN:

                    if fd == s.fileno():
                        conn,addr = s.accept()
                        conn.setblocking(False)
                        my_poll.register(conn.fileno(),select.EPOLLIN)
                        conn_dict[conn.fileno()]=conn
                    else:
                        print('poll in.....')
                        conn = conn_dict[fd]
                        data = conn.recv(1024)
                        if data:
                            my_poll.modify(conn.fileno(),select.POLLOUT)
                elif event == select.POLLOUT:
                    time.sleep(1)
                    # print('deal requests...')
                    conn = conn_dict[fd]
                    conn.send('HTTP/1.1 200 OK\r\n\r\n'.encode())
                    conn.sendall(json.dumps({"ret":0,"msg":"success"}).encode())
                    my_poll.unregister(conn.fileno())
                    conn.close()
    except Exception as e:
        s.close()
    finally:
        print(123)
        s.close()
```
同样的道理我们无法在请求处理过程中看到并发的效果(也就是`select.POLLOUT`事件下),可以在`POLLIN`模式下通过简单的打印来看并发的请求.

当我们指定高并发时，比如100个,可以看到快速的`print`出数据来.

```
ab -c 100 -n 1000 http://localhost:8000/
```

## io事件epoll

#### poll的缺点

poll解除select最大1024个描述符限制,其他的和select类似.事实上，同时连接的大量客户端在一时刻可能只有很少的处于就绪状态，因此随着监视的描述符数量的增长，其效率也会线性下降。

#### 什么是epoll

epoll是在2.6内核中提出的，是之前的select和poll的增强版本。相对于select和poll来说，epoll更加灵活，没有描述符限制。epoll使用一个文件描述符管理多个描述符，将用户关系的文件描述符的事件存放到内核的一个事件表中，这样在用户空间和内核空间的copy只需一次。

关于上面的缺点epoll使用了一下方案来解决：

- **内核copy** 在底层使用**mmap()**文件映射的方式加速与内核空间的数据传递
- **最大连接数** 最大连接数取决你操作系统定义的**file_max**,也就是说取决与操作系统的限制,而且这个值可以修改.
- **fd轮训** epoll采用了回调的机制来管理已就绪的fd,所以epoll永远管理的是一个已就绪的列表

这里有一个思考，epoll更像是一个高贵的公子,自己拿到的东西永远都是已经准备好的(就绪的fd),但是是谁在为它准备这些已就绪的fd呢？ 看有些文章说是Python底层在做这件事情.

epoll对与fd的操作有两种模式： **LT level trigger(水平出发)** 和 **ET edge trigger(边沿触发)**.

- LT模式：当检测到描述符事件发生并将此事件通知应用程序，应用程序可以不立即处理该事件。下次调用epoll_wait时，会再次响应应用程序并通知此事件。
- ET模式：当检测到描述符事件发生并将此事件通知应用程序，应用程序必须立即处理该事件。如果不处理，下次调用epoll_wait时，不会再次响应应用程序并通知此事件。

#### python中的epoll

epoll模型也是在select模块中，如果需要一个epoll对象直接实例化就可以了！

```
epoll = select.epoll(sizehint=-1, flags=0)
```

- sizehint： 这个参数没有太多的意义，仅仅使用在没有`epoll_create1()`系统调用的老系统中
- flags： 这个参数已弃用，在python3.4之后就直接使用**select.EPOLL_CLOEXEC**,不用管.

并且在3.4之后支持和`with`语句一起协同工作.

epoll中的事件:

| 名称        | 含义                                   |
| ----------- | -------------------------------------- |
| EPOLLIN     | 读就绪                                 |
| EPOLLOUT    | 写就绪                                 |
| EPOLLPRI    | 有数据紧急读                           |
| EPOLLERR    | assoc,fd 上发生错误                    |
| EPOLLHUP    | assoc,fd 上发生挂起                    |
| EPOLLET     | 设置边沿触发，默认是水平触发           |
| EPOLLRDHUP  | 准备关闭流socket或等待另外一半连接关闭 |
| EPOLLRDNORM | 和EPOLLIN一样                          |
| EPOLLRDBAND | 可以读取高优先级数据                   |
| EPOLLWRNORM | 和EPOLLOUT一样                         |
| EPOLLWRNORM | 可以写取高优先级数据                   |
| EPOLLMSG    | 忽略                                   |

epoll中提供了一下方法:

- `register(self, fd, eventmask=None)` 向epoll中注册一个fd,如果已经存在就会包OS Error.
- `unregister(self, fd)` epoll中注销一个fd.
- `poll(self,timeout=-1, maxevents=-1)` 在epoll的fd中等待事件发生
- `modify(self, fd, eventmask)` 修改一个fd的事件
- `close()` 关闭epoll对象描述符
- `fileno()` 返回当前epoll对象的fd.

使用epoll改写我们程序如下:
```
import select,socket,json,time

l_addr=('127.0.0.1',8000)

def server():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(l_addr)
    s.listen(1)
    print("listen: http://%s:%s" % l_addr)
    s.setblocking(0)
    epoll = select.epoll()
    epoll.register(s.fileno(),select.EPOLLIN)
    try:
        conn_dict={}
        while True:
            events = epoll.poll()
            print(len(events))   #注释1
            for fd, event in events:
                if event == select.EPOLLIN:
                    if fd == s.fileno():
                        conn,addr = s.accept()
                        conn.setblocking(False)
                        epoll.register(conn.fileno(),select.EPOLLIN)
                        conn_dict[conn.fileno()]=conn
                    else:
                        print('input request...')  #注释2
                        conn = conn_dict[fd]
                        time.sleep(1)
                        data = conn.recv(1024)
                        if data:
                            epoll.modify(conn.fileno(),select.EPOLLOUT)
                elif event == select.EPOLLOUT:
                    conn = conn_dict[fd]
                    conn.send('HTTP/1.1 200 OK\r\n\r\n'.encode())
                    conn.sendall(json.dumps({"ret":0,"msg":"success"}).encode())
                    conn.shutdown(socket.SHUT_RDWR)
                elif event == select.EPOLLHUP:
                    conn = conn_dict[fd]
                    epoll.unregister(conn.fileno())
                    conn.close()
    finally:
        epoll.unregister(s.fileno())
        epoll.close()
        s.close()
```

使用上面的`ab`压测你会发现**注释1**和并发的连接数是一样的大约在100个左右(ab一次100个并发),在**注释2**处的接收请求数据很快就打印100个，和poll类似.

## 高级别selectors模块

这个模块是`select`扩展,可以根据用户的系统选择合适的io模型，官方也鼓励使用这个模块.这里就不多讲解了,贴一下**server_forver**的源码供大家参考:

```
with _ServerSelector() as selector:
    selector.register(self, selectors.EVENT_READ)

    while not self.__shutdown_request:
        ready = selector.select(poll_interval)
        # bpo-35017: shutdown() called during select(), exit immediately.
        if self.__shutdown_request:
            break
        if ready:
            self._handle_request_noblock()

        self.service_actions()
```

## 总结
事件驱动I/O的一个潜在的优势在于它可以在不使用多线程或者多进程的情况下同时处理大量的连接.也就是说,`select()`可以来监视成千上百个socket,并且对他们中间发送的事件做出响应.

事件驱动的缺点在于这里没有涉及真正的并发.如果一个事件的处理方法阻塞了或者执行了一个较长的耗时计算(也就是我们在列子中指定的`sleep`函数),那么之后所有的处理请求过程都会阻塞.

## 参考

[HTTP消息结构](https://www.runoob.com/http/http-messages.html)

[Linux下I/O多路复用select, poll, epoll 三种模型的Python使用](https://www.jianshu.com/p/abfb47d36fba)

[How To Use Linux epoll with Python](http://scotdoyle.com/python-epoll-howto.html)

[select — Waiting for I/O completion](https://docs.python.org/3/library/select.html#poll-objects)