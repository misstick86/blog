##  一、Django的FBV和CBV

#### 1.1 FBV视图

FBV即function base view(基于函数的视图). 处理Django中的每个ULR对应的视图用一个函数来表示，在函数的内部使用`if-else`语句来判断请求的类型。

```python
def users(request):
    if request.method == 'GET':
        ret = {'code': 0}
        user_list = ['zhangsan', '李四']
        ret['data'] = user_list
        return JsonResponse(ret)
```

#### 1.2 CBV视图

CBV即Class base view(基于类的视图). 处理Django的中URL根据视图类中函数来关联相应的请求方法. 此种写法看起来就比较明确,也正好和RESTful规范的思想相切合.

```python
class UsersView(View):
    def get(self,request):
        ret = {'code': 0}
        ret['data'] = 'this is get method'
        return JsonResponse(ret)

    def post(self,request):
        ret = {'code':0}
        ret['data'] = 'this is post method'
        return JsonResponse(ret)
```

### 1.3 使用Postman测试接口

下载地址: [<https://www.getpostman.com/downloads/>](<https://www.getpostman.com/downloads/>)

当然，软件已经放到了课件中，直接双击安装即可。

之后还要将Django的CSRF注释掉，默认Django会阻止postman的请求。

**settings.py** 文件中间件注释掉下面这一行:

```Python
# 'django.middleware.csrf.CsrfViewMiddleware',
```

## 二、数据的几种序列化方式

首先，我们需要创建一张表。

```python

class Student(models.Model):
    name = models.CharField(max_length=32,verbose_name='年龄')
    age = models.IntegerField(verbose_name='年龄')
```



#### 2.1 Json序列化

这种方式是自己序列化json对应，在响应是指定响应的类型为json数据。

```python
def users(request):
    if request.method == 'GET':
        ret = {'code': 0}
        data = []
        queryset = Student.objects.all()
        for itme in queryset:
            data.append({'name': itme.name, 'age': itme.age})
        ret['data'] = data
        return HttpResponse(json.dumps(ret),content_type='application/json')
```

#### 2.2 JsonResponse

此种方式是`JsonResponse`帮我们封装了响应头的`content-type`和数据的序列化。 

但数据还是需要我们自己构造成可序列化对象。

```python
    if request.method == 'GET':
        ret = {'code': 0}
        data = []
        queryset = Student.objects.all()
        for itme in queryset:
            data.append({'name': itme.name, 'age': itme.age})
        ret['data'] = data
        return JsonResponse(ret)
```

#### 2.3 Django serializers

Django自带的serializers会自动帮我序列化查询到的model对象。不需要我们自己封装数据。

```python
def users(request):
    if request.method == 'GET':
        ret = {'code': 0}
        data = []
        queryset = Student.objects.all()

        # serialize已经是序列化后的数据，JsonResponse会在此序列化，所以我们要先反序列化一次
        data = serializers.serialize('json',queryset)

        ret['data'] = json.loads(data)
        return JsonResponse(ret)
```

想一想，以上三种方式都需要自己查表，然后自己在封装序列化的数据，之后响应对应的Json数据。 如果，有框架帮我做这些那将是太方便了。

**这就是我们之后要讲的Django restful framework!**

## 三、Django RestFul Framework

#### 3.1 安装app

在settings配置文件中安装`rest_framework`模块。

```python
INSTALLED_APPS = (
    ...
    'rest_framework',
)
```

#### 3.2 创建Serializers

在对应的app下创建一个serializeers.py文件。

```python
from rest_framework import serializers


class StudentSerializers(serializers.Serializer):
    id = serializers.IntegerField(read_only=True)
    name = serializers.CharField(max_length=32)
    age = serializers.IntegerField()
```

#### 3.3 创建View视图

```python
from app.serializers import StudentSerializers
from rest_framework import viewsets
class StudentViewset(viewsets.ModelViewSet):
    queryset = Student.objects.all()
    serializer_class = StudentSerializers
```

#### 3.4 使用路由器管理路由

```python
from rest_framework import routers

router = routers.DefaultRouter()
router.register(r'student',views.StudentViewset)

urlpatterns = [
    url(r'^admin/', admin.site.urls),
    url(r'', include(router.urls))
]
```

在访问对应的url可以看到，DRF框架已经帮我封装好了我们想要的数据。
