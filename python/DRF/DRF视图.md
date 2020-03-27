## 一、基于类的视图

在基于函数的视图和基于类的视图选择上，我更推荐使用基于类的视图。 这种把HTTP请求方法和类中的函数想绑定更容易理解，代码也更易读。

下面来看看DRF提供的多种向上封装的类:

![Django VIew类图](.\image\Django VIew类图.png)

#### 1.1 APIView视图

url:

```python
url(r'^studentdetail/(?P<pk>\d+)/$',views.StudentDetail.as_view(), name='Student Deatil')
```



**列出所有：**

```python
    def get(self,request):
        ret = {'code': 0}
        queryset = Student.objects.all()
        serializer = StudentSerializers(queryset,many=True)
        ret['data'] = serializer.data
        return Response(ret)
```

**添加一个**

```python
    def post(self,request):
        ret = {'code':0}
        serializer = StudentSerializers(data=self.request.data)
        if serializer.is_valid():
            serializer.save()
        else:
            ret['msg'] = '创建失败'
        return Response(ret)
```

**获取单个:**

```python
    def get_object(self,pk):
        try:
            return Student.objects.get(pk=pk)
        except Student.DoesNotExist:
            raise HTTP_404_NOT_FOUND
    def get(self,request,pk):
        ret = {'code': 0}
        s1 = self.get_object(pk)
        serializer = StudentSerializers(s1)
        ret['data'] = serializer.data
        return Response(ret)
```

#### 1.2 使用mixins

上述的`APIView`，我们需要为每个请求方法都涉及到数据库查询操作，代码不经看起来不美观，而且重复写了很多无用的代码，增加了维护的难度。 DRF提供了Minxs类型，同一封装了HTTP的7大方法，我们只需要按需继承即可！

**注：在使用Mixins之前，我们需要为每个类都继承GenericAPIView**。

比如我们重写之前的*GET*和*POST*方法。

```python
class StudentList(generics.GenericAPIView, mixins.ListModelMixin, mixins.CreateModelMixin):
    queryset = Student.objects.all()
    serializer_class = StudentSerializers
    def get(self,request,*args, **kwargs):
        return self.list(request,*args, **kwargs)
    def post(self,request,*args, **kwargs):
        return self.create(request,*args, **kwargs)
```

可以看到代码简洁了很多，我们只需要根据请求方法调用对应的处理方法就行了。

但是，如果我们还是重复的写了`get`、`post`这些方法，这显然很累赘。

而使用**混合类**就很好的解决了这个问题。

但是，如果我们获取所有用户列表，和单个用户信息的时候我们还是要写两个类，而且我们还要写两次`queryset`和`serializer_class`。 这显然还是代码比较冗余。

#### 1.3 使用混合类

混合类的主要作用是减少代码的书写量，混合类将一些常用的类组合起来供我们随时使用。

```python
from rest_framework import generics
class StudentList(generics.ListCreateAPIView):
    queryset = Student.objects.all()
    serializer_class = StudentSerializers

```

```python
class StudentDetail(generics.RetrieveDestroyAPIView):
    queryset = Student.objects.all()
    serializer_class = StudentSerializers
```

可以看到代码减少了很多，但是我们还是为同一接口使用了两个类，有没有一种方法能将这两个类合并到一起呢？ 这就要使用我们的viewset了.

#### 1.4 Viewset 

在之前的类中我们都是写了两个url分别对应两个类，而是用viewset加上了路由器可以将url和类同一的管理起来。

**视图如下：**

```python
class StudentViewset(viewsets.ModelViewSet):
    queryset = Student.objects.all()
    serializer_class = StudentSerializers
```

**绑定路由**

```python
student_list = views.StudentViewset.as_view({
    'get': 'list',
    'post': 'create'
})

student_detail = views.StudentViewset.as_view({
    'get': 'retrieve',
    'put': 'update',
    'delete': 'destroy'
})
```

将每个方法绑定到类中的方法即可。

#### 1.5 路由器

现在是一个接口我们做一个路由绑定，但是如果我们100个接口，那么我们估计写这种路由绑定都要写好几个文件，DRF又为我们提供了一个叫做路由器的功能，自动我们做路由绑定和分发。

## 二、如何选择

从**APIView**到**Viewset**，书写代码越来越少，但是带来的问题就是越来越抽象，我们虽然之后这么做可以写一个很好的restful api的接口，但是我们对接口的定制也就越来麻烦。

实际生产中，对于那些只涉及增删改查的接口我们应该使用上层抽象的类型，对于那些需要特殊定制的接口我们应该使用最原始的**APIView**，这可以让我们完全定制化我们的API.