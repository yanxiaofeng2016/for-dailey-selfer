# 海光节点 glibc 2.28 memcpy 段错误

glibc 2.28 不认识海光的 CPUID，把 `__x86_shared_non_temporal_threshold` 算成 0。`memcpy` 因此对任意长度都走进大块拷贝，并执行 `movups xmm4, [rsi+0x1000]`，读到未映射的下一页后触发段错误。把该阈值设为 201326592，或把镜像里的 glibc 升到 2.29，可以避开这个问题。

## 现象

`workload-operator` 在海光节点上启动时段错误，退出码 139。同一镜像直接进 shell 也会崩。

镜像：`registry-hulk.sankuai.com/k8s/kubernetes/workload-operator:v0.3.20-b2662442`

不加 `GLIBC_TUNABLES` 时，`docker exec` 进入 bash 会段错误：

```bash
docker run -d --name workload-debug \
  --entrypoint sleep \
  -v /home/test-9800212504276878/debug/mt-qs/k8s/kube.cfg:/kube.cfg:ro \
  -e KUBECONFIG=/kube.cfg \
  -e WATCH_NAMESPACE=kube-operator \
  registry-hulk.sankuai.com/k8s/kubernetes/workload-operator:v0.3.20-b2662442 \
  infinity

docker exec -it workload-debug bash
```

加上阈值后可以正常进入 bash：

```bash
docker run -d --name workload-debug \
  --entrypoint sleep \
  -v /home/test-9800212504276878/debug/mt-qs/k8s/kube.cfg:/kube.cfg:ro \
  -e KUBECONFIG=/kube.cfg \
  -e WATCH_NAMESPACE=kube-operator \
  -e GLIBC_TUNABLES=glibc.cpu.x86_non_temporal_threshold=201326592 \
  registry-hulk.sankuai.com/k8s/kubernetes/workload-operator:v0.3.20-b2662442 \
  infinity

docker exec -it workload-debug bash
```

节点上 `getconf LEVEL3_CACHE_SIZE` 为 268435456（256MB），其四分之三即 201326592（192MB）。

## 原因

内核日志里的故障指令是 `0f 10 a6 00 10 00 00`，即 `movups xmm4, [rsi+0x1000]`。这是 glibc 2.28 SSE2 `memcpy` 大块拷贝的预读：不判断本次拷贝长度，直接从源地址再往后 4096 字节读 16 字节。同一页内多读是安全的，跨到下一页则不一定。故障地址的页内偏移都是 `0x320`，说明 `rsi` 在当前页 `+0x320`，这一页只剩 3296 字节，`+0x1000` 落在下一页的 `+0x320`。下一页没有映射，于是缺页，`error 4`，进程收到 `SIGSEGV`。

这条路径由 `__x86_shared_non_temporal_threshold` 控制，计算在 `sysdeps/x86/cacheinfo.c` 的 `init_cacheinfo()` 末尾：

```c
__x86_shared_non_temporal_threshold
  = __x86_shared_cache_size * threads * 3 / 4;
```

glibc 2.28 不认识海光的 Vendor ID `HygonGenuine`，CPU 被标成 `arch_kind_other`，读不到缓存大小，`__x86_shared_cache_size` 为 0，阈值也是 0。于是任意长度的 `memcpy` 都走进上述预读。bash 启动时的小块拷贝也会执行 `movups [rsi+0x1000]`，从而段错误。

glibc 2.29 已把海光合入 AMD 分支，缓存按 `CPUID 0x8000001D` 读取，阈值恢复为「共享缓存 × 线程数 × 3/4」：

https://sourceware.org/git/?p=glibc.git;a=commit;h=ade8b817fead73b302d08c88cd44ea2ea56793d4

## 解决方案

1. 在 Deployment 或 Pod 的 YAML 里写上固定阈值。容器内的 `getconf` 在这份 glibc 上可能仍是 0，不要写 shell 表达式。

```yaml
env:
  - name: GLIBC_TUNABLES
    value: "glibc.cpu.x86_non_temporal_threshold=201326592"
```

2. 把镜像中的 glibc 升级到 2.29 或更高版本，使海光 CPUID 被识别，阈值按真实 L3 计算。
