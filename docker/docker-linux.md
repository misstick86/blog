


上一篇文章讲到Docker本质上还是一个进程，它的隔离主要依赖于Linux内核的Namespace机制，这篇文章就带你从进程创建到Namespace机制进行简单剖析。

## 一、Namespace简介
当前，Linux内核共实现了六种不同类型的Namespaces(较新版本的内核添加了Cgroups namespace)。每个Namespace的功能是将一个特定的全局系统资源包装在一起, 这让每个进程错误的以为自己都拥有独立的全局资源。Namespace的总体目标是支持容器技术的实现，为每个或每一组进程提供一种假象让其错误的认为自己就是操作系统的唯一进程。

**Linux内核的六种Namespace:**

|        分类        | 系统调用参数  |               内核版本               |
| :----------------: | :-----------: | :----------------------------------: |
|  Mount namespace   |  CLONE_NEWNS  |             Linux 2.4.19             |
|   UTS namespaces   | CLONE_NEWUTS  |             Linux 2.6.19             |
|   IPC namespaces   | CLONE_NEWIPC  |             Linux 2.6.19             |
|   PID namespaces   | CLONE_NEWPID  |             Linux 2.6.24             |
| NETWORK namespaces | CLONE_NEWNET  | 始于Linux 2.6.24 完成于 Linux 2.6.29 |
|  User namesapces   | CLONE_NEWUSER | 始于 Linux 2.6.23 完成于 Linux 3.8)  |

从实现时间上来看，Redhat6系列天然不支持，建议直接使用Redhat7系列。

**Mount namespace:** 隔离一组进程文件系统挂载点集合，从而实现不同Namespace中的进程看到的文件系统不同。 mount() 和 umount() 系统调用将不在全局操作系统上执行，而是在于调用进程相关联的Namespace中操作。

**UTS namespaces:** 隔离一个系统的身份标识符。分别通过sethostname() 和 setdomainname() 系统调用进程设置，此Namespac允许每个容器中拥有自己的主机名等。

**IPC namespaces:** 进程间通信隔离，也就是Systme V IPC和POSIX message queues对象，每个IPC Namespace都拥有自己一套的System V IPC标识符和自己的POSIX消息队列系统。

**PID namespaces:** 隔离进程的PID号，换句话说，不同的Namespace中可以拥有相同的PID号。一个好处是每个进程可以在宿主机中迁移并保持这个PID不变。 PID Namespace也允许每个容器中拥有自己的Init，管理系统的初始化和进程回收。

**NETWORK namespaces:** 隔离网络相关资源，每个Network Namespace中都拥有独立的网络设备、IP地址、ip路由表、/proc/net目录，端口号等。

**User namesapces:** 隔离进程的用户、用户组。换句话说，运行一个User Namespace中进程的用户或者用户组可以和操作系统中的用户不同。 比如在操作系统中以非==root==用户运行，而在User Namesapce中以==root==用户运行。

从Linux内核3.8开始，用户可以在/proc/[pid]/ns目录下看到指向不同的Namespace的文件。如下：
```
[root@localhost ~]# ls -l /proc/self/ns/
total 0
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 ipc -> ipc:[4026531839]
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 mnt -> mnt:[4026531840]
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 net -> net:[4026531956]
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 pid -> pid:[4026531836]
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 user -> user:[4026531837]
lrwxrwxrwx. 1 root root 0 Mar 26 11:34 uts -> uts:[4026531838]
```
如上，内核提供了上述六种Namespace功能，但这又是如何与进程产生关联的呢？ 这主要是使用Linux提供的系统调用功能。

## 二、Linux的系统调用
Linux内核中设置了一组用于实现各种系统功能的子程序，被称之为系统调用。用户可以在自己的应用程序中引用对应的头文件来调用他们。 从某种角度来看，系统调用非常类似于普通的函数，区别在于系统调用运行在内核态，而用户自己的函数运行在用户态。 我通常跟愿意称之为内核提供的API接口。

而Namespace机制也就是通过在创建进程时(系统调用)通过传递不同的参数实现。实现Namespace功能的系统调用主要包括三个，分别是`clone()`、 `setns()`、 `unshare()`, 当然还包括/proc目录下的部分文件。

- clone(): 实现进程的系统调用，用来创建一个新的进程，并可以通过传递不同参数达到隔离。
- unshare(): 是某个进程脱离某个Namespace。
- setns(): 把某个进程加入某个Namespace。
接下来，以==clone==系统调用为列来创建一个进程。

#### Clone()系统调用
在Linux中，创建一个进程的一个简单方式就是Clone() 函数，函数的基本形式如下：
```
    int clone(int (*fn)(void *), void *child_stack,  int flags, void *arg ) ;
```
`clone()`系统调用是传统Unix系统调用fork() 的一种更通用的实现方式。可以通过传递不同的flags参数实现多种功能。下面来看看`clone()`函数传递的参数功能：

- fn: 指定新进程要执行的函数，当这个函数返回时表示子进程结束。返回值表示子进程的退出状态码。
- arg: 像指定的函数中传递的参数。
- child_stack: 指定子进程所使用的栈地址。
- flags: 子进程结束后发送给父进程的终止信号，通常为SIGCHLD信号。也可以和CLONE_*开头的各种标志位。
-
关于`clone()`系统调用更多的内容请参考：[http://man7.org/linux/man-pages/man2/clone.2.html](http://man7.org/linux/man-pages/man2/clone.2.html)

来看一个关于Clone的案例:
```
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <stdio.h>
#include <sched.h>
#include <signal.h>
#include <unistd.h>

/* 定义一个给 clone 用的栈，栈大小1M */
#define STACK_SIZE (1024 * 1024)
static char container_stack[STACK_SIZE];

char* const container_args[] = {
            "/bin/bash",
            NULL
};

int container_main(void* arg)
{
            printf("Container - inside the container!\n");
            /* 直接执行一个shell，以便我们观察这个进程空间里的资源是否被隔离了 */
            execv(container_args[0], container_args);
            printf("Something's wrong!\n");
            return 1;
}

int main()
{
            printf("Parent - start a container!\n");
            /* 调用clone函数，其中传出一个函数，还有一个栈空间的（为什么传尾指针，因为栈是反着的） */
            int container_pid = clone(container_main, container_stack+STACK_SIZE, SIGCHLD, NULL);
            /* 等待子进程结束 */
            waitpid(container_pid, NULL, 0);
            printf("Parent - container stopped!\n");
            return 0;
}
```
这个示例表示使用`clone()`创建一个新的进程，并在子进程中执行**bin/bash**,即:启动一个新的Shell程序,等待用户进行交互. 当子进程退出时，父进程调用SIGCHLD信号进行收尾工作。
接下来我们执行这个程序:
```
busyboy@busyboy:~/docker/clone$ echo $$
22099   #显示当前shell进程的pid号。
busyboy@busyboy:~/docker/clone$ ./clone.out   # 执行对应的程序。
Parent - start a container!
child Process id is 26208
Container - inside the container!
busyboy@busyboy:~/docker/clone$ echo $$
26208    # 在此查看当前的pid号，可以发现已经和之前的不一样了，说明已经在新的进程中运行。
```

当然，我们可以使用`pstree -p`命令来查看进程树，所得到的结果也是一样的。

上面的程序简单的描述了`clone()`系统调用的使用方法，而Namespace也是通过给子进程传递不同的参数实现不同级别的隔离。接下来我们看看不同级别的Namespace。

## 三、Linux的Namespace
#### UTS Namespace
UTS namespace 提供了主机名和域名的隔离，这样每个容器就可以拥有了独立的主机名和域名，在网络上可以被视作一个独立的节点而非宿主机上的一个进程。

下面我们通过代码来感受一下 UTS 隔离的效果，整个程序还是对上述`clone()` 系统调用程序的修改；代码如下:
```
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <stdio.h>
#include <sched.h>
#include <signal.h>
#include <unistd.h>

/* 定义一个给 clone 用的栈，栈大小1M */
#define STACK_SIZE (1024 * 1024)
static char container_stack[STACK_SIZE];

char *const container_args[] = {
            "/bin/bash",
                NULL};

int container_main(void *arg)
{
          printf("Container - inside the container!\n");
          sethostname("container", 10); // 设置主机名
          /* 直接执行一个shell，以便我们观察这个进程空间里的资源是否被隔离了 */
          execv(container_args[0], container_args);
          printf("Something's wrong!\n");
          return 1;
}

int main()
{
          printf("Parent - start a container!\n");
          /* 调用clone函数，其中传出一个函数，还有一个栈空间的（为什么传尾指针，因为栈是反着的） */
          int container_pid = clone(container_main, container_stack + STACK_SIZE, CLONE_NEWUTS | SIGCHLD, NULL);
          /* 等待子进程结束 */
          waitpid(container_pid, NULL, 0);
          printf("Parent - container stopped!\n");
          return 0;
}
```
这个程序主要修改了两个部分，第一个是在进行`clone()`系统调用时传递了CLONE_NEWUTS这个参数，第二个是使用`sethostname()`系统调用设置主机名。

```
busyboy@busyboy:~/docker/uts$ sudo ./uts.out
Parent - start a container!
Container - inside the container!
root@container:~/docker/uts# hostname
container
```

#### IPC Namespace

IPC即进程间通信，是指在不同的进程之间传播和信息交换。IPC的方式通常有管道、消息队列、信号量、共享内存、Socket、Streams等。为了让同一个Namespace下的进程相互通信，所以，我们也需要把IPC给隔离出来。对于每个IPC来说，他们都有自己的System V IPC和POSIX message queues,并且对其他的namespace不可见。
在Linux下，我们想要和ipc打交道通常需要使用一下两个命令:

- ipcs: 查看IPC(共享内存、消息队列和信号量)的信息
- ipcmk: 创建IPC(共享内存、消息队列和信号量)的信息

> 注：由于代码都是在上层基础上做改动，这个只写出修改的部分。
```
int container_pid = clone(container_main, container_stack+STACK_SIZE,
            CLONE_NEWUTS | CLONE_NEWIPC | SIGCHLD, NULL);
```
首先，我们在shell中使用ipcmk -Q 创建一个全局的message queue。

1. 创建
```
busyboy@busyboy:~/docker/ipc$ ipcmk -Q
Message queue id: 0
```
2. 查看

```
busyboy@busyboy:~/docker/ipc$ ipcs -q

------ Message Queues --------
key        msqid      owner      perms      used-bytes   messages
0xa33c2bdb 0          busyboy    644        0            0
```

之后，我们在==clone==中加上CLONE_NEWIPC 这个系统调用，我们就就看不到这个ipc：
```
root@container:~/docker/ipc# ipcs -q

------ Message Queues --------
key        msqid      owner      perms      used-bytes   messages
```
也就是说，刚才创建的IPC已经被隔离了。

#### PID Namespace
PID namespace 隔离非常实用，它对进程 PID 重新标号，即可以实现两个不同 namespace 下的进程可以有一个相同的PID。内核为每个PID namespace维护一个树状结构，最顶层的是系统初始化时所创建，我们称之为root namespace。他所创建新的pid namespace就称之为child namespace. 通过这种方式，不同的pid namespace会形成一个树状的等级体系，在这个树中，父namespace可以对子namespace产生影响，而反过来则不行。
我们来修改上面的程序:

添加CLONE_NEWPID 这个参数
```
int container_pid = clone(container_main, container_stack + STACK_SIZE, CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID | SIGCHLD, NULL);
```
查看子进程中答应对应的pid
```
printf("Container id: [%d] - inside the container!\n",getpid()); //打印pid
```
运行结果如下： 可以看到子进程的pid已经是1了。
```
busyboy@busyboy:~/docker/pid$ sudo ./pid.out
Parent - start a container!
Container id: [1] - inside the container!
```

还记得我们演示==clone==系统调用那个最初始的例子吗, 那是有当前pid namespace内核分配的，而在实现了新的pid namespace之后，内核会将第一个进程分配为pid为1,它管理这这个namespace下的进程生命周期。
```
busyboy@busyboy:~/docker/pid$ echo  $$
27028
busyboy@busyboy:~/docker/pid$ sudo ./pid.out
Parent - start a container!
Container id: [1] - inside the container!
root@container:~/docker/pid# echo $$
1
```
这里讲一讲pid为1的进程特殊作用：
1. 当我们新建一个 PID namespace 时，默认启动的进程 PID 为 1。我们知道，在传统的 UNIX 系统中，PID 为 1 的进程是 init，地位非常特殊。他作为所有进程的父进程，维护一张进程表，不断检查进程的状态，一旦有某个子进程因为程序错误成为了“孤儿”进程，init 就会负责回收资源并结束这个子进程。所以在你要实现的容器中，启动的第一个进程也需要实现类似 init 的功能，维护所有后续启动进程的运行状态。这样的设计非常有利于系统资源的监控和回收。Docker启动时，第一个进程也是这样的，负责子进程的资源回收。
2. PID namespace 中的 init 进程如此特殊，自然内核也为他赋予了特权——信号屏蔽。即同一个Namespace下的进程发送给它的信号都会被屏蔽，这个功能防止init进程被误杀。那么其父节点 PID namespace 中的进程发送同样的信号会被忽略吗？父节点中的进程发送的信号，如果不是 SIGKILL（销毁进程）或 SIGSTOP（暂停进程）也会被忽略。但如果发送 SIGKILL 或 SIGSTOP，子节点的 init 会强制执行（无法通过代码捕捉进行特殊处理），也就是说父节点中的进程有权终止子节点中的进程。

此时,进程已经被隔离了，如果我们执行ps、top命令是不是就看不到宿主机上的进程了呢，但事实真的如此吗？

这是因为像ps、top这样的命令会去读内核的/proc文件系统，但此时我们并没有对文件系统做隔离，所以还是会显示操作系统的信息。我们不妨在手动挂载下。

```
root@container:~/docker/pid# mount -t proc proc /proc/
root@container:~/docker/pid# ps aux
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.2  10232  4996 pts/1    S    07:47   0:00 /bin/bash
root        14  0.0  0.1  18976  3096 pts/1    R+   08:11   0:00 ps aux
```
可以看到实际的 PID namespace 就只有两个进程在运行。
注意：因为此时我们没有进行 mount namespace 的隔离，所以这一步操作实际上已经影响了 root namespace 的文件系统，当你退出新建的 PID namespace 以后操作系统的/proc文件系统已经损坏了，再次执行` mount -t proc proc /proc `就可以修复错误。

#### Mount Namespace
Mount Namespace隔离的是文件系统的挂载点，也就是说不同的namespace下的进程看到的文件系统结构不同。在Namespace内可以同mount和umount系统调用来修改。

```
clone 调用部分处修改，添加一个CLONE_NEWNS参数
int container_pid = clone(container_main, container_stack + STACK_SIZE, CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID | CLONE_NEWNS | SIGCHLD, NULL);
# 添加头文件
#include <stdlib.h>
# 执行系统调用
system("mount -t proc proc /proc");
```
此时我们在执行ps命令，可以只有两个进程，而且/proc文件也干净了很多。
```
root@container:/home/busyboy/docker/mount# ps aux
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.1   9028  3668 pts/0    S    08:37   0:00 /bin/bash
root        15  0.0  0.1  18976  3068 pts/0    R+   08:38   0:00 ps aux
```
在通过CLONE_NEWNS创建新的mount namespace后，父进程会把自己的文件结构复制给子进程。由于开启了隔离，子进程的所有mount操作都影响自身的文件系统，不会对外界产生任何影响。

你可能会问，我们是不是还有别的一些文件系统也需要这样mount?  == 是的。

你可以还会问，如果我插入一个新的磁盘，想让每个进程都可以看到这个磁盘，是不是要在每个mount namespace中都执行一遍挂载操作?。== 并不是。

了解Docker的朋友应该知道，这和Docker镜像中太不一样。Docker可是提供了一整套的rootfs。
接下来，我们使用chroot的工具，来模仿一个完整的Docker rootfs。
假设,我们现在有一个/opt/test目录，想让其作为/bin/bash进程的根目录。
```
root@busyboy:/home/busyboy/docker/mount# mkdir /opt/test
root@busyboy:/home/busyboy/docker/mount# mkdir -p /opt/test/{bin,lib64,lib}
root@busyboy:/opt/test/lib# mkdir x86_64-linux-gnu
```
把对应的目录copy到test目录对应的bin目录下：
```
root@busyboy:/home/busyboy/docker/mount# cp -v /bin/{bash,ls} /opt/test/bin/
```
接下来把命令所依赖的so文件和各种库文件copy到对应的lib目录下。
```
root@busyboy:/home/busyboy/docker/mount#  list="$(ldd /bin/ls | egrep -o '/lib.*\.[0-9]')"
root@busyboy:/opt/test/lib# for i in $list; do cp -v "$i" "${T}${i}"; done
root@busyboy:/opt/test/lib# cp /lib/x86_64-linux-gnu/libtinfo.so.6 /opt/test/lib/x86_64-linux-gnu/

busyboy@busyboy:/opt/test$ sudo chroot /opt/test/ /bin/bash
[sudo] password for busyboy:
bash-4.4# ls /
```
这时，如果你执行`ls -l`就会发现，它返回的是/opt/test目录下的内容，而不是宿主机中的内容。
实际上，Mount Namespace正是基于对chroot的不断改良才被发明出来的。

#### User Namespace
User Namespace主要隔离了安全相关的标识符和属性，包括用户ID、用户组等。说的通俗一点，一个普通用户的进程通过传递CLONE_NEWUSER 参数，Namespace内部看到的用户uid和gid已经和外部不同了。其默认为65534.(其设置定义在/proc/sys/kernel/overflowuid)
要把容器中的uid和系统中的uid关联起来，需要修改`/proc/pid/uid_map`和`/proc/pid/gid_map`这两个文件，文件格式如下：
```
busyboy@busyboy:~$ cat /proc/self/uid_map
         0            0            4294967295
      ID-inside-ns   ID-outside-ns   length
```
其中：

第一个字段ID-inside-ns表示容器内部显示的UID或者GID.
第二个字段ID-outside-ns表示容器外部映射的真实UID或者GID.
第三个字段表示映射的范围，一般填1，表示一一对应。如果该值大于1，则按顺序建立一一映射。
代码如下：
```
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/capability.h>
#include <stdio.h>
#include <sched.h>
#include <signal.h>
#include <unistd.h>

#define STACK_SIZE (1024 * 1024)

static char container_stack[STACK_SIZE];
char *const container_args[] = {
    "/bin/bash",
    NULL};

int pipefd[2];

void set_map(char *file, int inside_id, int outside_id, int len)
{
  FILE *mapfd = fopen(file, "w");
  if (NULL == mapfd)
  {
    perror("open file error");
    return;
  }
  fprintf(mapfd, "%d %d %d", inside_id, outside_id, len);
  fclose(mapfd);
}

void set_uid_map(pid_t pid, int inside_id, int outside_id, int len)
{
  char file[256];
  sprintf(file, "/proc/%d/uid_map", pid);
  set_map(file, inside_id, outside_id, len);
}

void set_gid_map(pid_t pid, int inside_id, int outside_id, int len)
{
  char file[256];
  sprintf(file, "/proc/%d/gid_map", pid);
  set_map(file, inside_id, outside_id, len);
}

int container_main(void *arg)
{

  printf("Container [%5d] - inside the container!\n", getpid());

  printf("Container: eUID = %ld;  eGID = %ld, UID=%ld, GID=%ld\n",
         (long)geteuid(), (long)getegid(), (long)getuid(), (long)getgid());

  /* 等待父进程通知后再往下执行（进程间的同步） */
  char ch;
  close(pipefd[1]);
  read(pipefd[0], &ch, 1);

  printf("Container [%5d] - setup hostname!\n", getpid());
  //set hostname
  sethostname("container", 10);

  //remount "/proc" to make sure the "top" and "ps" show container's information
  mount("proc", "/proc", "proc", 0, NULL);

  execv(container_args[0], container_args);
  printf("Something's wrong!\n");
  return 1;
}

int main()
{
  const int gid = getgid(), uid = getuid();

  printf("Parent: eUID = %ld;  eGID = %ld, UID=%ld, GID=%ld\n",
         (long)geteuid(), (long)getegid(), (long)getuid(), (long)getgid());

  pipe(pipefd);

  printf("Parent [%5d] - start a container!\n", getpid());

  int container_pid = clone(container_main, container_stack + STACK_SIZE,
                            CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | SIGCHLD, NULL);

  printf("Parent [%5d] - Container [%5d]!\n", getpid(), container_pid);

  //To map the uid/gid,
  //   we need edit the /proc/PID/uid_map (or /proc/PID/gid_map) in parent
  //The file format is
  //   ID-inside-ns   ID-outside-ns   length
  //if no mapping,
  //   the uid will be taken from /proc/sys/kernel/overflowuid
  //   the gid will be taken from /proc/sys/kernel/overflowgid

  set_uid_map(container_pid, 0, uid, 1);
  // 这里组有点问题，gid会发生改变
  set_gid_map(container_pid, 0, gid, 1);

  printf("Parent [%5d] - user/group mapping done!\n", getpid());

  /* 通知子进程 */
  close(pipefd[1]);

  waitpid(container_pid, NULL, 0);
  printf("Parent - container stopped!\n");
  return 0;
}
```
以普通用户运行如下:
```
busyboy@busyboy:~/docker/user$ gcc user.c -o user.out
busyboy@busyboy:~/docker/user$ ./user.out
Parent: eUID = 1000;  eGID = 1000, UID=1000, GID=1000
Parent [ 3212] - start a container!
Parent [ 3212] - Container [ 3213]!
Parent [ 3212] - user/group mapping done!
Container [    1] - inside the container!
Container: eUID = 0;  eGID = 65534, UID=0, GID=65534
Container [    1] - setup hostname!

root@container:~/docker/user# id
uid=0(root) gid=65534(nogroup) groups=65534(nogroup)
```
可以看到，容器里运行的用户id是0，也就是特权用户。但实际在容器外部，/bin/bash是以一个普通用户运行的。 这样就提供高了容器的安全性。

疑惑: 这里组ID并没有对应映射为1000,而是使用了默认值。查看子进程中对应的gid_map文件，发现这个文件为空，说明并没有写入进去。后续再研究研究。

#### Network Namespace

Network Namespace的主要功能是提供网络资源的隔离，包括网络设备、IPV4和IPV6协议栈、路由表、防火墙、Socket等。一个物理设备只能存在于一个Network Namespace中，但是我们在docker中可以看到每个容器都有一个自己的网卡，这又是怎么回事呢？

首先，我们先看下图，下图表示Docker在宿主机上的网络示意图。

上图中，Docker使用了一个私有网段，通常这个网络为172.17.0.0网络，当然这是可以配置的。
当你启动一个Docker容器后，可以是ip link show 或者ip addr show来查看当前宿主机的网络情况。如下：

```
[root@localhost ~]# ip link show
1: lo: <LOOPBACK> mtu 65536 qdisc noqueue state DOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: ens192: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 00:0c:29:f7:17:54 brd ff:ff:ff:ff:ff:ff
3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether 02:42:45:bb:fc:c8 brd ff:ff:ff:ff:ff:ff
25: veth6d92449@if24: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master docker0 state UP mode DEFAULT group default
    link/ether aa:77:c4:08:71:79 brd ff:ff:ff:ff:ff:ff link-netnsid 0
```
如上，Docker为一个容器创建了一个新的网卡**veth6d92449@if24**. 我们以Docker Daemon在启动容器Docker init的过程为例。 Docker Daemon在宿主机上负责创建一个网络虚拟设备(这个虚拟设备有两端)，并通过系统调用将其中的一端绑定在Docker0网桥上，一端连如新创建的Network Namespace中,这也就是我们在每个容器中看到的eth0设备。

下面我们来模拟这个过程:

###### 首先，我们使用ip命令创建一个Network Namespace,并激活里面的lo接口。
```
[root@localhost ~]# ip netns add ns1
[root@localhost ~]# ip netns exec ns1 ip link set dev lo up
```
测试lo网卡可用性
```
[root@localhost ~]# ip netns exec ns1 ping 127.0.0.1
```
###### 之后增加一对虚拟网卡并把其中一端放入容器中改名为eth0
```
[root@localhost ~]# ip link add veth-ns1 type veth peer name docker1.1 # 创建网卡
[root@localhost ~]# ip link set veth-ns1 netns ns1   #加入到ns1 namespace
[root@localhost ~]# ip netns exec ns1 ip link set dev veth-ns1 name eth0  # 修改名称
[root@localhost ~]# ip netns exec ns1 ifconfig eth0 10.10.1.10/24 up
```
此时，我们看ns1中的网卡
```
[root@localhost ~]# ip netns exec ns1 ifconfig -a
eth0: flags=4099<UP,BROADCAST,MULTICAST>  mtu 1500
        inet 10.10.1.10  netmask 255.255.255.0  broadcast 10.10.1.255
        ether ca:38:25:dc:46:df  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```
###### 最后分配网桥并设置默认路由

1. 将docker1.1 设置新的网卡
```
[root@localhost ~]# ifconfig docker1.1 10.10.1.11/24 up
[root@localhost ~]# ip netns exec ns1 ip route add default via 10.10.1.1
```
2. 测试和宿主机的网络连通性
```
[root@localhost ~]# ip netns exec ns1 ping 192.168.1.80
PING 192.168.1.80 (192.168.1.80) 56(84) bytes of data.
64 bytes from 192.168.1.80: icmp_seq=1 ttl=64 time=0.121 ms
```

到此，主机就可以和一个namespace中的网络通信了；但Docker并没有使用ip命令，而是自己实现了ip命令的一些功能。

## 四、总结
这篇文章讲解了Linux内核一个重要的功能Namespace技术。 从最开始的Namespace功能介绍、到内核提供的Clone系统调用，再到使用代码实现了每个Namespace功能。不难看出，Docker这个神秘的技术其底层还是一个进程，只是在创建的这个进程的时候我们为其添加了各式各式的参数来实现隔离。

试想一下，Docker的本质是一个进程，那么就有可能出现代码BUG从而导致这个进程占用了整个操作系统的资源，那又该如何避免这个问题呢？