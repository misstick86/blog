## DRF-Tracking模块源码分析

#### 一、drf-tracking是什么？

drf-tracking是为DRF的view访问提供一个日志记录模块。使用mixin的方式无缝的和DRF相结合。 从源码结构上来看也是Django的一个APP项目，提供Model将日志记录到数据库、自定Manger操作等.其核心为该源码中的`base_mixins.py`模块。个人认为该项目非常适合新手阅读。

#### 二、基本使用

和其他模块安装一样，使用pip安装即可。

```python
$ pip install drf-tracking
```

之后将项目安装到项目settings的`INSTALLD_APPS`中，名字是`rest_framework_tracking` ,由于需要数据库，所以还要执行以下migrate操作。

```python
$ python manage.py migrate
```

采用面向对象的继承方式，我们只需要在每个Class类中继承该模块中的`LoggingMixin`方法即可，默认情况下它会记录所有请求方法的日志。当然我们也可以自定义让哪些请求方法记录日志。

```python
logging_methods = ['POST', 'PUT']
```

`LoggingMixin`类提供了一个类属性,该属性的值是一个列表,用于存放要记录日志的所有HTTP请求方法。

从源码中我们也不难看出,`LoggingMixin`定义了一个**should_log**函数来控制日志是否记录,这个函数也非常简单, 返回结果的是一个bool值。如下：

```python
def should_log(self, request, response):
    return self.logging_methods == '__all__' or request.method in self.logging_methods
```

如上，我们也可以重写这个方法根据不同的需求来控制日志是否被记录。 只要我们最终返回一个bool值即可。

而这个函数的调用取决于`finalize_response`这个函数，也是这个函数来封装记录数据。

`LoggingMixin`中还有一个*handle_log*方法,这个方法控制如何记录日志，以及将日志写到何处。我们来看一下这个函数的代码。

```python
def handle_log(self):
    APIRequestLog(**self.log).save()
```

`APIRequestLog` 是一个Model表,也就是日志记录表，所以这段代码不难理解就是实例化一个*APIRequestLog*实例，然后调用save()方法保存。 而我们在这个类中也只是封装一个全局的`log`属性即可。 可以猜出这个*log*保存的也就是每个表结构中以字段为key的字典。

**到目前为止，我们知道了日志如何保存，如何控制日志是否保存，但好像并不知道这个`log`是如封装的。**

#### 三、请求和响应钩子

我们知道DRF封装了Django原生的View提供了一个我们常用的APIView,其中有一个*initial*的方法。 这个方法主要是做一些请求检查。 当然，我们可以重写这个类，并在此时就开始对请求做日志初始化和记录。 `drf-tracking`就是这么做的，我们来看下这个方法：

```python
def initial(self, request, *args, **kwargs):
    # 初始化我们需要的log字典
    self.log = {}
    #封装请求体数据
    self.log['requested_at'] = now()
    self.log['data'] = self._clean_data(request.body)

    super(BaseLoggingMixin, self).initial(request, *args, **kwargs)

    try:
        data = self.request.data.dict()
    except AttributeError:
        data = self.request.data
    self.log['data'] = self._clean_data(data)
```

我们知道`super()`是执行当前类MRO列表中下一个类中对应的方法，这样我们使用`super()`函数就可以直接执行`APIView`中的*initial*方法，这也是一种为一个函数添加功能的技巧。 

同理,*finalize_response*也是一个被重写的方法，我们来看看这个方法：

```python
    def finalize_response(self, request, response, *args, **kwargs):
        #执行父类的方法
        response = super(BaseLoggingMixin, self).finalize_response(request, response, *args, **kwargs)
		
        # 获取自定义或者默认的should_log方法，来判断是否记录日志
        # Ensure backward compatibility for those using _should_log hook
        should_log = self._should_log if hasattr(self, '_should_log') else self.should_log

        if should_log(request, response):
            #实际封装log部分
            if response.streaming:
                rendered_content = None
            elif hasattr(response, 'rendered_content'):
                rendered_content = response.rendered_content
            else:
                rendered_content = response.getvalue()

            self.log.update(
                {
                    'remote_addr': self._get_ip_address(request),
                    'view': self._get_view_name(request),
                    'view_method': self._get_view_method(request),
                    'path': request.path,
                    'host': request.get_host(),
                    'method': request.method,
                    'query_params': self._clean_data(request.query_params.dict()),
                    'user': self._get_user(request),
                    'response_ms': self._get_response_ms(),
                    'response': self._clean_data(rendered_content),
                    'status_code': response.status_code,
                }
            )
            try:
                # 调用handle_log 来保存封装的日志
                if not connection.settings_dict.get('ATOMIC_REQUESTS'):
                    self.handle_log()
                else:
                    if getattr(response, 'exception', None) and connection.in_atomic_block:
                        connection.set_rollback(True)
                        connection.set_rollback(False)
                    self.handle_log()
            except Exception:
                logger.exception('Logging API call raise exception!')

        return response
```

到此，我们也就看完了整个**drf-tracking**的源码核心部分，重写一个组件的其他部分来扩展其功能。 当然，如果我们详读DRF的源码可以看到,DRF也是重写了Django的view提供了强大的请求功能。

#### 四、自定功能

刚在github上看到这个项目的时候粗略的看了下使用，发现其扩展性不是很好。 以至于觉得不是很好用。后来仔细阅读源码后(也是从它重写DRF的组件启发了我)可扩展性还是很好的。 这里介绍一下自己扩展的DEMO.

注： 这中情况我们就不需要再在settings中INSTALL_APP添加rest_framework_tracking.

**自定义数据库**

drf-tracking自带的数据库只提供了一些简单的字段，如果需要记录我们业务上的数据就需要重写，这里以一个告警的需求为列，我们来自定义Model。

```python
class CustomApiLog(BaseAPIRequestLog):
    subject = models.TextField(verbose_name='告警主题',default=None,null=True,blank=True)
    sub_text = models.TextField(verbose_name='告警内容', default=None,null=True,blank=True)
```

添加告警主题和告警内容两个字段，当然自己也可以根据需求添加。

**自定义mixin**

上面讲到**LoggingMixin** 类就提供了*handle_log*方法，而这个方法知识保存数据库数据，我们可以重写这个方法，并在保存数据库之前获取到我们自定义字段的数据。下来来看看如果需要自定义mixin我需要做些什么。

1、settings指定你自定义的Model

```
LOG_MODEL = 'app.CustomApiLog'
```

2、来看看我自定的mixin

```python
from rest_framework_tracking.base_mixins import BaseLoggingMixin
from rest_framework_tracking.base_models import BaseAPIRequestLog
from django.conf import settings
from django.apps import apps as django_apps
from django.core.exceptions import ImproperlyConfigured

def get_log_model():
    try:
        return django_apps.get_model(settings.LOG_MODEL, require_ready=False)
    except ValueError:
        raise ImproperlyConfigured("AUTH_USER_MODEL must be of the form 'app_label.model_name'")
    except LookupError:
        raise ImproperlyConfigured(
            "AUTH_USER_MODEL refers to model '%s' that has not been installed" % settings.AUTH_USER_MODEL
        )

class CustomLoggingMixin(BaseLoggingMixin):

    def _get_custom_fileds(self):
        # 获取自定义的log表
        self.CustomApiLog = get_log_model()
        #获取自定义的表字段
        custom_filed = (item.name for item in set(self.CustomApiLog._meta.fields) - set(BaseAPIRequestLog._meta.fields))
        # 更新log字典
        for item in custom_filed:
            if hasattr(self,'get_%s' % item):
                func = getattr(self, 'get_%s' % item)
                result = func()
                self.log.update({item: result})

    def handle_log(self):

        self._get_custom_fileds()
        self.CustomApiLog(**self.log).save()
```

自定义字段需要你自己编写函数来返回你想要的数据，这个的函数命名有一定的讲究，他必须是以`get_字段名`命令的函数，例如上面的*subject*字段，其函数名为*get_subject*.

```python
def get_subject(self):
    return '【{user}】操作接口【{interface}】{operator}一条数据'.format(user=self._get_user(self.request),\
        interface=self.request._request.path,operator=self.method_dict.get(self.request.method.upper()))
```

当然，你可以重写我这个提供专门提供自定义字段的所有函数并处理业务逻辑，这并不会对日志记录有任何影响。

参考：[<https://github.com/aschn/drf-tracking>](<https://github.com/aschn/drf-tracking>)

