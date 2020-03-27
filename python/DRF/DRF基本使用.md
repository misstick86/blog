## 一、Serializer (序列化)

​	序列化器允许把对象列如querysets或model实例非常容易的转化为Python类型如Json\XML或者其他类型。序列化器还提供反序列化，允许数据转换为复杂的类型，之后在验证传过来的数据。

​	序列化的工作方式非常类似于Django的Form和ModelForm类，Serializer类提供有力的、通用的方式控制你的输出和响应， 而且ModelSerializer类很方便创建一个序列化处理Model和querysets.

#### 1.1 数据反序列化

数据反序列化是指我们将一个已经序列化后的数据转化为Python的一个对象示例，比如我们通过反序列化将字典转化为一个`Student`实例。

```python
In [1]: s2 = {'name':'world','age':19}

In [2]: ser2 = serializer.StudentSerializers(data=s2)

In [3]: ser2.is_valid()
Out[3]: True

In [5]: ser2.save()
Out[5]: <Student: Student object>



```

可以看到，我们已经将一个字典转化为`StudentSerializer`实例，如果我们想要保存这个实例，直接调用*save()*方法就可以了。

```python
class StudentView(View):
    def post(self,request):
        ret = {'code': 0}
        name = request.POST.get('name')
        age = request.POST.get('age')

        serializer_data = StudentSerializers(data={'name':name, 'age':age})
        if serializer_data.is_valid():
            # print(112)
            serializer_data.save()

        else:
            ret['code'] = 1
            ret['msg'] = '添加失败'

        return JsonResponse(ret, status=200)
```



此时可以明白，如果我们在view中获取到了`s2`的数据，那我们就可以使用`serializer`的方式来创建这个数据实例。

#### 1.2 数据序列化

列子以我们上节课的Student表未为列.  可以看到`StudentSerializers`中的对象和表`Student`的结构一样，我们就可以来序列化`Student`对象。

```python
In [1]: from app import models

In [2]: from app import serializer

In [6]: s1 = models.Student(name='hello',age=18)

In [7]: s1.save()

In [8]: serializer = serializer.StudentSerializers(s1)

In [9]: serializer.data
Out[9]: ReturnDict([('id', 3), ('name', 'hello'), ('age', 18)])


```

现在，我们可以把数据库中的数据拿出来，然后序列化成一个json数据。

```python
    def get(self,request):
        ret = {'code':0}
        queryset = Student.objects.all()
        serializer_data = StudentSerializers(queryset,many=True)
        ret['data'] = serializer_data.data
        return JsonResponse(ret)
```

以上就是最基本的**Serializer** 使用方法，除此之外，DRF还为我们提供了ModelSerializer、HyperlinkedModelSerializer 等多种方序列化方式。

#### 1.3 ModelSerializer

```
class StudentSerializers(serializers.ModelSerializer):
    class Meta:
        model = Student
        fields = '__all__'
```

## 二、请求和响应

#### 2.1 请求

DRF基扩展了Django自带的`HttpRequest`名为`Request`，并扩展了`TemplateResponse`取名为`Response`.

```python
request.POST  # 仅处理from表单数据，也就是post方法
retuest.data  # 处理任意数据，包括POST\PUT\PATCH.
```

封装了两个API views，供我们使用。

1、基于函数的view使用 `@api_view`进行装饰

2、基于类型的view可以继承与`APIView`.

```python
@api_view(['GET','POST'])
def student(request):
    pass
```

```python
class student(APIView):
    def get(self,request):
        pass
```

#### 2.2 响应

```python
from rest_framework.response import Response


class student(APIView):
    def get(self,request):
        ret = {'code': 0}
        return Response(ret)
```

## 三、状态码

DRF将状态和的标识和原语同一封装起来，让人很清楚的知道每个请求状态码的错误类型。

```
from rest_framework.status import HTTP_400_BAD_REQUEST
```

所有的状态码都封装在`rest_framework.status`这个文件中，开箱即用。

