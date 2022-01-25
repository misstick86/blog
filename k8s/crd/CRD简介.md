## k8s之CRD开发(一)

K8s提供了很多开箱即用的workload(Deployment, StatefulSet, Job, Pod), 在实际的使用中，这些也能满足我们绝大部份的需求.  像我们对外提供一个标准的HTTP服务时,采用的形式就是Deployment + Service + Ingress.  这个时候业务开发者就需要写上述三个资源的YAML文件. 其实这个不一定是完全必要的, 我们可以对其进行在次抽象，将其打包在一起为一个资源(假设叫做: WebResource). 这样对于同一种模式的应用部署时候，我们就可以操作`WebResource`既可.

**Kubernetes**本身就提供了一个简单的可以让我们自定义对应资源的功能. **CRD**(CustomResourceDefinitions) 这是一种可以让kubernetes认识我们自己定义了的资源的功能.  我们简单来了解一下什么CRD.

#### CRD本身也是一种资源

我们知道可以通过**api-resource**查看当前系统中支持的所有资源.  其实可以看到crd也在其中.

```shell
(base) ➜  ~ kubectl api-resources| grep customresourcedefinitions
customresourcedefinitions         crd,crds           apiextensions.k8s.io/v1                     false        CustomResourceDefinition
```

当然,和其他内置的系统资源一样,他也需要**apiVersion**、**Kind**、**metadata**、**spec**等字段来描述一个CRD资源.

一个简单的CRD资源如下:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
   name: crontabs.extention.funstory.ai
spec:
   group: extention.funstory.ai
   versions:
     - name: v1beat1
       storage: true
       served: true
       schema:
         openAPIV3Schema:
           type: object
           properties:
             spec:
               type: object
               properties:
                 cronSpec:
                   type: string
                 image:
                   type: string
                 replicas:
                   type: integer
   scope: Namespaced
   names:
     kind: CronTab
     plural: crontabs
     shortNames:
       - ct
```

这里,我们定义了一个Kind是CronTab的资源, 这个资源包含三个字段:  **cronSpec**, **image**,**replicas**.

之后,我们只需要将这个CRD资源提交到**kubernetes**系统中既可. 那么**kubernetes**就可以认识我们这个CRD资源.

```shell
kubectl apply -f crd-crontan.yaml
```

 我们在来查看一下系统的资源, 可以看到多了一个我们定义对的`cronTab`资源.

```shell
(base) ➜  crd kubectl get crd | grep funstory
crontabs.extention.funstory.ai                        2021-05-13T14:09:35Z
```

#### 管理自定义资源

我们可以像管理**Deployment**资源一样管理我们自定义的资源,kubectl支持的命令我们都可以使用. 如下,我们创建一个**Crontab**资源.

```yaml
(base) ➜  crd cat crontab.yaml
apiVersion: "extention.funstory.ai/v1beat1"
kind: CronTab
metadata:
  name: my-new-cron-object
spec:
  cronSpec: "* * * * */5"
  image: my-awesome-cron-image
```

```shell
(base) ➜  crd kubectl apply -f crontab.yaml  # 创建资源
(base) ➜  crd kubectl get ct  # 查看资源
NAME                 AGE
my-new-cron-object   17h
(base) ➜  crd kubectl delete ct my-new-cron-object   # 删除资源
crontab.extention.funstory.ai "my-new-cron-object" deleted
```

到此,我们只是简单定义了一个CRD资源, kubernetes也已经认识这个对象并可以操作这个资源. 但想要让其真正的提供业务能力(实现我们想要的功能), 我们还需要编写对应的controller来实现其业务逻辑.

