---

---

## werkzuge示例
一个简单的werkzuge示例如下所示:
<!--more-->
```
import json
from werkzeug.wrappers import Request, Response
from werkzeug.serving import run_simple

@Request.application
def application(request):
    response = Response(json.dumps({'code':0, 'msg': 'success'}),status=200)
    return response

if __name__ == '__main__':
    run_simple('localhost',8000,application)
```

运行werkzeug的程序的入口为`serving`文件的`run_simple`函数,该函数通过调用`make_server`函数来创建一个*Server*类,这个类继承了从**HTTP**到底层的**socket**类，通过运行**serve_forever**方法来实现接收数据和处理数据.

## WSGI类的关联关系
在`make_server`中使用了多个WSGI的类,分别是**BaseWSGIServer**,**ForkingWSGIServer**,**ThreadedWSGIServer**;不难看出后面两个是对**BaseWSGIServer**提供的多进程和多线程的支持.他们之间的继承关系如下所示:
```
            BaseWSGIServer
            //        \\
           //          \\
ForkingWSGIServer   ThreadedWSGIServer
```
一切的起源都是**BaseWSGIServer**，来看看这个类的作用.

## BaseWSGIServer的继承
```
    BaseServer(socketserver)
            ||
            ||
        TCPServer(socketserver)
            ||
            ||
        HTTPServer(http/server)
            ||
            ||
    BaseWSGIServer(werkzeug/server)
```

## BaseWSGIServer类的方法和属性
**BaseWSGIServer**继承于**HTTPServer**,也就不难看出WSGI是连接web服务器与和应用程序之前的座桥梁. 详细请参考这篇文章: [Werkzeug How WSGI Works](http://mitsuhiko.pocoo.org/wzdoc/wsgihowto.html)

##### 属性
- host and port: 需要监听的ip地址和端口，也是通常所说的socket.
- applicaion: web服务其要与之交互的应用程序.
- handler: 用作处理请求的handler类，也是实际由它实现了WSGI的功能和应用程序交互.

我们知道在编写**socketserver**模块的服务端代码时,真正处理请求的是由我们自定义的`Handler`实现的. 而`http`和`werkzeug`都继承了这一思想，将处理请处理的方法放在**Handler**中，并在开始处理请求时实例化这个类. 默认`Handler`采用的是**WSGIRequestHandler**这个类. 初始化时如下:
```
if handler is None:
    handler = WSGIRequestHandler
```

#### serve_forever()监听socket
**BaseWSGIServer** 虽然自己从新实现了**server_forever**方法, 但并未做太多的事情，真正实现socket的数据接受和处理还是**BaseServer**中的这个方法.
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
使用`selector`实现io的多路复用，它可以根据操作系统平台实现不同的io多路复用机制，常见的是`select`,`poll`,`epoll`. 可以看到当有请求进来时调用了内部的`_handle_request_noblock`方法处理请求.

#### get_request 方法
当一个请求进来时，werkzegu重写了**get_request**方法来建立客户端连接，返回一个请求的socket对象和客户端地址信息.
```
    con, info = self.socket.accept()
    return con, info
```


之后在函数内部调用`verify_request`和`process_request`实现对请求的验证和处理，这些实现还是在socketserver模块定义的**BaseServer**类中. 之后由`finish_request`这个方法实例化一个请求的**handler**类处理socket.
```
def finish_request(self, request, client_address):
    """Finish one request by instantiating RequestHandlerClass."""
    self.RequestHandlerClass(request, client_address, self)
```
以下是WSGI的`handler`如何继承底层sockerserver的`handler`;可以看到和**BaseWSGIServer**的继承是一个样子.

## WSGIRequestHandler的继承关系
```
    BaseRequestHandler(socketserver)
            ||
            ||
    StreamRequestHandler(socketserver)
            ||
            ||
    BaseHTTPRequestHandler(http/server)
            ||
            ||
    WSGIRequestHandler(werkzeug/server)
```
可以看到**BaseRequestHandler**接收一下属性:
- request: 每个请求的socket实例
- client_address： 客户端连接地址和端口
- server: 当前处理请求的server，对werkzeug来说就是`BaseWSGIServer`

*handler*的实例化还是由基类**BaseRequestHandler**来实现的，之后一次调用`setup()`,`handler()`，`finish()`方法来完成处理请求. 此处的**BaseRequestHandler**则是一个接口，定义了需要实现的方法，而所有的具体方法处理逻辑则有对应派生类实现。

#### setup()方法
注： 由于HTTP是基于TCP协议的，而这个**setup()**方法也是**StreamRequestHandler**(TCP)实现的.
1. 定义了`rfile`和`wfile`分别实现对socket的读和写. rfile设置了读缓存，wfile则没有缓存。
2. 是否禁用nagle 算法.
3. 设置超时时间

#### handle()方法
**WSGIRequestHandler**本身也只是调用父类的**handler**方法,之后调用了**handle_one_request**,WSGI重写了这个方法，主要做了三件事：
1. 获取http的请求行，也就是 **GET /hello.txt HTTP/1.1\r\n**,这样的二进制流数据.
2. 解析获取到的请求行，并封装成`request method`,`request path`,`request version` 和 获取请求头数据，并验证连接是否关闭.
3. 调用`run_wsgi()` 实现后续的数据处理.

#### run_wsgi()方法
根据PEP333的规范，在服务器或网关的开发中，应用程序必须要接受两个位置参数：
1. environ： 是一个字典对象，包含CGI样式的环境变量，而且必须是内置的Python字典.
2. start_response： 是一个可调用对象，一般来说可以是一个函数.
具体请参考PEP333官方文档:[https://www.python.org/dev/peps/pep-0333/](https://www.python.org/dev/peps/pep-0333/).

Werkzeug的具体实现为： 在进入函数时通过`make_environ`函数生成当前wsgi所拥有的环境变量，通过`execute`方法将应用程序传递进来，也就是我们开头设置的应用程序.

对于每个应用程序来说都加了`Request.application`这个类装饰器. 装饰器接收的参数也是wsgi提供的`envrion`和`response`对象。
```
def application(*args):
    request = cls(args[-2])
    with request:
        try:
            resp = f(*args[:-2] + (request,))
        except HTTPException as e:
            resp = e.get_response(args[-2])
        return resp(*args[-2:])
```
此处*request*为当前函数所在的类的实例，*f* 为我们执行应用程序对应的函数. 返回的*resp*也就是我们在应用程序中返回的对象,当一个可调用对象调用时会首先查找自己的`__call__`方法，此时这个装饰器返回的对象也就是**Response**中`__call__`方法返回的数据。

#### Response.__call__方法
处理WSGI引用程序提供的响应数据，参数分别为WSGI的环境变量字典`environ`和**Handler**类中的**start_response**,函数返回一个迭代器，响应的数据都放在这个迭代器中.

一个http的响应依次为首行，响应头，响应体如下:
```
 HTTP/1.1 200 OK
```
在这个函数中通过`environ`变量封装了对应的状态码和响应头，状态码是在应用程序中调用**Response**类实例化时就直接当成属性的方式赋值的，而响应头则调用**get_wsgi_headers**函数构造. 之后就开始调用**start_response**构造响应的数据.

在**start_response**中将响应放在了`headers_set`这个列表中，而这个`headers_set`是个`run_wsgi`变量通过闭包的形式修改.

而实际响应的数据则由放在了迭代器`app_iter`中.
```
    application_iter = app(environ, start_response)
```
接下来便是通过socket发送数据了. 来看一下**write**方法.

#### write函数
1. 封装请求行
`write`行数在响应数据之前先通过放在`headers_set`列表构造响应头和响应行. 并调用`send_response`行数发送响应行.
```
if self.request_version != "HTTP/0.9":
    hdr = "%s %d %s\r\n" % (self.protocol_version, code, message)
    self.wfile.write(hdr.encode("ascii"))
```
2. 封装响应头
之后封装响应头数据，并通过`send_header`函数发送响应头.而`send_header`只是将所有的请求头格式化放在一个列表中用于缓存,之后封装了一些基本的http响应头,如：**Server**,**Date**,结束后调用**end_headers**函数封装最后的`\r\n`并通过`flush_headers`函数将数据发送出去.

3. 发送响应数据
```
if data:
    # Only write data if there is any to avoid Python 3.5 SSL bug
    self.wfile.write(data)
self.wfile.flush()
```
最后通过调用迭代器的`close()`方法关闭数据. 次数WSGI侧数据的数据发送已经完成.

## 关闭Socket
此情况为一个socket连接响应一个请求，所以在响应完成后`Handler`的**close_connection**会被设置为True,此时开始关闭socket.
首先调用**finish**函数对`wfile`和`rfile`进行关闭;然后在调用**shutdown_request**对应socket进行关闭.
```
def handle(self):
    """Handle multiple requests if necessary."""
    self.close_connection = True

    self.handle_one_request()
    while not self.close_connection:
        self.handle_one_request()
```
由`handler`可以看出在处理请求之前就在`close_connection`属性设置为True，也就无法重用一个Socket.
