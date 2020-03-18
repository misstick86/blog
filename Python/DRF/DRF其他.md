## 一、认证

目前来说我们没有为任何一个接口或者请求做任何限制，任何人都可以随便的访问他们，但这样并不安全。

通过配置我们可以在url上配置登陆的相关信息:

```python
url(r'^api-auth/', include('rest_framework.urls',namespace='rest_framework')),
```

这样我们就可以在DRF中提供的web应用进行访问这个url开始认证。

#### 1.1 认证方案

DRF提供了多种认证方案，如果需要使用哪个认证方案我们也只需要在**settings.py**中进行配置即可。

```python
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'rest_framework.authentication.SessionAuthentication',
        'rest_framework.authentication.BasicAuthentication',
    ),
```

而对于前后端分离的项目中我们最常用的是token认证，允许我们自己生成Token进行认证管理。 其核心也是使用数据库保存用户和token的关联信息。 但我们也可以使用第三方组件JWT：`djangorestframework-jwt`

关于Json Web Token可以参考文章:<https://tools.ietf.org/html/draft-ietf-oauth-json-web-token-32>

**安装：**

```python
pip install djangorestframework-jwt
```

**使用：**

在**Settings**认知中配置一下：

```python
'rest_framework_jwt.authentication.JSONWebTokenAuthentication',
```

在url中设置一下路径:

```python
from rest_framework_jwt.views import obtain_jwt_token
url(r'^api-token-auth/', obtain_jwt_token),
```

## 二、权限

#### 2.1 全局权限

在**settings.py**的配置中可以添加全局权限配置。如下：

```python
REST_FRAMEWORK = {

    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticated',
    ),
}
```

#### 2.2 对象权限

**APIView**为每个接口提供一下`permission_classes`属性，我们可以选择任何权限应用到这个接口上. DRF为我们提供了一下权限: **BasePermission**、**AllowAny**、**IsAuthenticated** 等。

当然，我们也可以根据接口来自定义每个用户的权限。 只需要继承**BasePermission**后.重写`has_permission`或者`has_object_permission`即可。

```python
    permission_classes = (permissions.IsAdminUser)
```

## 三、分页

分页和权限类似，提供全局的分页和单接口的分页。 使用方式也很相同。

```python
'PAGE_SIZE': 10
```

如果是自定义则需要继承`BasePagination`后自己指定数据。

## 四、文档

DRF本身自带一个文档功能，我们可以直接引用对应的url即可。

```python
    #api文档路由地址
    url(r'^docs/',include_docs_urls(title='kk-devops2.0接口文档')),
```

