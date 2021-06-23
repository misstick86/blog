#### 前言
公司需要一套kafka集群来采集各个区域的用户行为日志,目前香港集群已经部署完成,还需要在东南亚和北美各创建一个kafka集群并将数据同步到香港的kafka集群中. kafak的集群部署在kubernets中,采用helm部署方式,集群之间的数据同步使用的是kafka官方给的解决方案**mirrormaker**.

#### 安装kafka集群
kafka集群的安装已经收纳到helm官网,首先我们要添加一个`incubator`的仓库地址，因为 stable 的仓库里面并没有合适的 Kafka 的 Chart 包：

helm官方kafak地址如下: [https://github.com/helm/charts/tree/master/incubator/kafka](https://github.com/helm/charts/tree/master/incubator/kafka)

```
$ helm repo add incubator http://mirror.azure.cn/kubernetes/charts-incubator/
$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "incubator" chart repository
...Successfully got an update from the "stable" chart repository
Update Complete. ⎈ Happy Helming!⎈
```

使用helm安装就非常的简单了,比如:

```
helm install --name my-kafka incubator/kafka
```
当然默认的安装不适合我们实际的需求,我们需要编写自己的**values.yaml**文件.kafka的后端需要存储空间,阿里云本省也提供了很多可以使用的存储插件,我们这里使用的是NAS,由于需要做**mirrormaker**,我们需要将kafka集群暴露在公网.最后使用的**values.yaml**文件如下:

```
external:
  enabled: true
  type: LoadBalancer
  distinct: true
  dommain: bnstat.com

configurationOverrides:
  "advertised.listeners": |-
    EXTERNAL://kafka-$((${KAFKA_BROKER_ID})).example.com:19092
  "listener.security.protocol.map": |-
    PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT

persistence:
  size: "10Gi"
  storageClass: alicloud-nas
livenessProbe:
  initialDelaySeconds: 120
```

> 这里说一下我遇到的问题.

kafka默认会为我们在底层的云环境创建三个LB,但这些都是内网的(阿里云中).一开始我认为在LB中绑定对应的外网IP不就可以把服务暴露出来了,但事情并没有这么简单. 这是由于kafak中的配置文件两个字段所定义的**listeners**,**advertised.listeners**.

- listeners: 一般用于内网通信,如果不准备把kafka暴露在公网只需要配置这个参数
- advertised.listeners: 用于配置外网,会将此地址配置在zookeeper中(这里有一个坑)

关于这两个字段可以参考文档:[https://segmentfault.com/a/1190000020715650](https://segmentfault.com/a/1190000020715650)

在使用helm部署时,我对**values.yaml**的更改一直使用的是**helm upgrade**的方式,但当你修改pod中的环境变量内容时并不会触发pod更新,你需要手动更新. 而且由于**advertised.listeners**会向zookeeper中写入,修改**value.yaml**并不会更改zookeeper中的**advertised.listeners**数据,这一度困扰了我很久.

在使用**external**字段时,建议在配置的**advertised.listeners**采用域名的方式,即使kafka对外的LB发生改变也只需要改解析就可以了,对于业务没有影响.

最后: helm安装时直接指定**values.yaml**文件既可以.

```
helm install my-kafka -f values.yaml incubator/kafka
```

通过内部连接kafak集群就非常简单了,使用如下的配置创建一个pod.

```
apiVersion: v1
kind: Pod
metadata:
  name: testclient
  namespace: kafka
spec:
  containers:
  - name: kafka
    image: solsson/kafka:0.11.0.0
    command:
      - sh
      - -c
      - "exec tail -f /dev/null"
```
使用如下的配置列出kafka的所有的topic:
```
kubectl -n kafka exec -ti testclient -- ./bin/kafka-topics.sh --zookeeper my-release-zookeeper:2181 --list
```

#### mirrormaker镜像同步

MirrorMaker是Kafka附带的一个用于在Kafka集群之间制作镜像数据的工具。该工具从源集群中消费并生产到目标群集。这种镜像的常见用例是在另一个数据中心提供副本。

关于mirrormaker制作成Docker镜像的方法网上也有很多,这里我使用的[https://github.com/srotya/docker-kafka-mirror-maker](https://github.com/srotya/docker-kafka-mirror-maker)的构建方法,但是由于时间比较长久所以还是自己修改了一部分.修改后的Dockerfile如下:

```
FROM nimmis/java-centos:oracle-8-jre
MAINTAINER Ambud Sharma

ENV WHITELIST *
ENV DESTINATION "localhost:6667"
ENV SOURCE "localhost:6667"
ENV SECURITY "PLAINTEXT"
ENV GROUPID "_mirror_maker"
ENV PRINCIPAL "kafka/localhost@EXAMPLE.COM"
ENV KEYTAB_FILENAME "mirror.keytab"

RUN mkdir -p /usr/local/kafka_2.12-2.0.1
COPY kafka_2.12-2.0.1 /usr/local/kafka_2.12-2.0.1
RUN yum -y install gettext
RUN mkdir -p /etc/mirror-maker/
RUN mkdir /etc/security/keytabs/
ADD ./consumer.config /tmp/mirror-maker/
ADD ./producer.config /tmp/mirror-maker/
ADD ./kafka_jaas.conf /tmp/mirror-maker/
ADD ./run.sh /etc/mirror-maker/
RUN chmod +x /etc/mirror-maker/run.sh

CMD /etc/mirror-maker/run.sh
```
此镜像已经上传到Dockerhub中,地址:[https://hub.docker.com/r/uxiaosongsong/mirror-maker](https://hub.docker.com/r/uxiaosongsong/mirror-maker)

以上的坏境变量也非常的简单,简单介绍一下:

 - **WHITELIST**: 要镜像同步的topic,支持正则表达式
 - **DESTINATION**: 要同步的目表kafka集群地址
 - **SOURCE**: 提供同步kafka集群的数据的地址

 之后再使用一个deploy部署起来就可以了,当然如果你需要同步多个就对应的创建多个deploy就行了.

 ```
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: mirror-maker
  namespace: xxxxx-public
spec:
  replicas: 1
  template:
    metadata:
      labels:
        name: mirror-maker
    spec:
      containers:
      - name: mirror-maker
        image: uxiaosongsong/mirror-maker:v1
        imagePullPolicy: IfNotPresent
        env:
        - name: "WHITELIST"
          value: "ops_test"
        - name: "DESTINATION"
          value: "data-kafka-headless:9092"
        - name: "SOURCE"
          value: "kafka-0.example.com:19092"
      nodeSelector:
        tuiwen-tech.com/phase: data
 ```

之后便可以在马来集群进行生产数据,硅谷集群消费数据就可以了,如下:

1. 马来生产

```
admin@iZ8psdykrxdgcybevaw3wzZ:~$ kubectl -n tuiwen-public exec -ti testclient -- kafka-console-producer --broker-list data-kafka-headless:9092 --topic ops_test
>jijoa
```

2. 硅谷消费

```
➜  kafka git:(master) ✗ kubectl -n tuiwen-public exec -ti testclient -- kafka-console-consumer --bootstrap-server data-kafka:9092 --topic ops_test --from-beginning
jijoa
```

#### 同步延迟验证
kafka集群的同步默认走的还是公网,安全性是通过限制ip的访问控制方式来实现的,监测两个集群数据同步的延迟也是一个必要的工作,目前采取的方式为马来生产一个时间数据,硅谷消费掉这个时间数据并和自己生成的时间做差值：
1. 生产者代码

```
#! /usr/bin/env python
# -*- coding: utf-8 -*-
# __author__ = "busyboy"
# Date: 4/28/20

import time
from kafka import KafkaProducer


def gen_time():
    current_time = str(round(time.time() * 1000))
    return current_time.encode("utf8")

def func():
    i = 0
    while True:
        current_time = gen_time()
        producer = KafkaProducer(bootstrap_servers=['kafka-2.example.com:19092','kafka-1.example.com:19092','kafka-0.example.com:19092'])
        future = producer.send('ops_test',value=current_time, partition= 0)
        result = future.get(timeout= 10)
        print(result)
        time.sleep(5)


if __name__ == '__main__':
    func()
```

2. 消费者代码

```
#! /usr/bin/env python
# -*- coding: utf-8 -*-
# __author__ = "busyboy"
# Date: 4/28/20

import time
from kafka import KafkaConsumer


consumer = KafkaConsumer('ops_test', bootstrap_servers=['kafka-2.bnstat.com:19092','kafka-1.bnstat.com:19092','kafka-0.bnstat.com:19092'])
for msg in consumer:
    print('time is:%d ms' % (int(round(time.time() * 1000)) - int(msg.value.decode("utf8"))))

```

在消费端消费数据验证延迟.
```
(.venv) admin@jump-server:~/python$ python kafka-consumer.py
time is:1774 ms
time is:2280 ms
time is:1940 ms
time is:209 ms
time is:210 ms
time is:214 ms
time is:233 ms
time is:211 ms
...
time is:219 ms
time is:214 ms
time is:212 ms
time is:211 ms
time is:469 ms
time is:398 ms
time is:209 ms
time is:209 ms
```

总体来看两端的延迟还是比较理想的在300毫秒以内,后续还可以改造代码将监控的数据放在prometheus中并实施监控起来.
