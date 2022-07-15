#### 简述 Kubernetes Pod 的 LivenessProbe 探针的常见方式
- exec 执行命令,根据命令执行成功语法判断是否健康
- HttpGet: 发送http 请求,根据http 状态码判断是否健康
- tcpSocket: 探测端口是否打开
- Grpc: 新版本中引用, 对应业务需要实现 HealthCheck 接口.

## 