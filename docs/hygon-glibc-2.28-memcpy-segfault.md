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

### `__x86_shared_cache_size` 和 `threads`

`__x86_shared_cache_size` 是每个逻辑处理器分到的共享缓存，单位是字节。`init_cacheinfo()` 先用 CPUID 读最高一级共享缓存的总大小（通常是 L3；没有 L3 就退回 L2），放在局部变量 `shared` 里，再执行 `shared /= threads`。写进 `__x86_shared_cache_size` 的是拆开后的这一份，并向下对齐到 256 字节的倍数。这个全局量的静态初值是 `1024 * 1024`（1 MiB），只有 `shared > 0` 时才被探测结果覆盖。

`threads` 是共享这一级缓存的逻辑处理器个数，是计数。

Intel（`arch_kind_intel`）的缓存大小由 `handle_intel()` 读取。现代 CPU 在 CPUID leaf 2 里给出描述符 `0xff`，实际容量用 leaf 4 计算。`threads` 同样来自 leaf 4：EAX bit 25:14 是「共享该级缓存的逻辑处理器」字段，值非 0 时再加 1。最大 CPUID 不小于 11 时，这个字段是可寻址 ID 的上限，函数再用 leaf 11 收成实际个数。leaf 4 没有给出信息时，退回 CPUID leaf 1 里的逻辑处理器计数。

AMD（`arch_kind_amd`）的 L3 大小来自 CPUID `0x80000006`，L1 来自 `0x80000005`。glibc 2.28 的 `cacheinfo.c` 不用 `0x8000001D`；那个叶子是后来的 glibc 才用来枚举 AMD 缓存拓扑。有 L3 时，`threads` 来自 CPUID `0x80000008` 的 APIC ID 宽度：`threads = 1 << ((ecx >> 12) & 0x0f)`。最大扩展功能号小于 `0x80000008` 时这段不会执行，`threads` 仍为 0，改用 CPUID leaf 1 的逻辑处理器个数（HTT 置位时取 EBX bit 23:16）。除完之后还会把整份 L2 加回 `shared`，因为 AMD 的 L2 与 L3 互斥。

`__x86_shared_cache_size * threads` 把每逻辑处理器的份额乘回去，得到总共享缓存，再 `* 3 / 4` 是这份总量的四分之三。赋值上方的注释写的就是这件事：大块 `memcpy` 的微基准在 8 核 CPU 上测得，非临时存储大约在共享缓存的 6 倍以上才更快，而那正好是总共享缓存的四分之三。`threads` 为 8 时 `8 * 3 / 4 = 6`，与旧公式 `__x86_shared_cache_size * 6` 相同；核数更多时阈值随 `threads` 增大。2.25 及更早直接写 `* 6`，2.26 起改成现在这一行。

节点上 `getconf LEVEL3_CACHE_SIZE` 为 268435456（256MB）。这是 L3 总字节数，也就是探测成功时 `__cache_sysconf` 返回的、执行 `shared /= threads` 之前的大小。没有把 L2 再加回去时，它等于 `__x86_shared_cache_size * threads`。`268435456 * 3 / 4 = 201326592`，所以规避用的阈值是 201326592。

海光的 Vendor ID `HygonGenuine` 在 glibc 2.28 的 `cpu-features.c` 里对不上 `GenuineIntel` 和 `AuthenticAMD`，`kind` 被设成 `arch_kind_other`，上面两条探测都不执行。`shared` 停在 -1，`threads` 停在 0，`__x86_shared_cache_size` 保持初值 1 MiB。阈值是 `1048576 * 0 * 3 / 4 = 0`：`threads` 没有被写成这块 CPU 的逻辑处理器个数，公式里这个乘数就是 0。同一份代码里 `__cache_sysconf()` 对未知厂商直接返回 0，容器内的 `getconf` 因此也可能是 0；上面的 256MB 是节点上能识别这块 CPU 的 glibc 测到的 L3 总量。

阈值是 0 之后，任意长度的 `memcpy` 都走进上述预读。bash 启动时的小块拷贝也会执行 `movups [rsi+0x1000]`，从而段错误。

glibc 2.29 已把 `HygonGenuine` 并入 AMD 分支，L3 仍按 CPUID `0x80000006` 读取，阈值恢复为「每逻辑处理器的共享缓存 × `threads` × 3/4」：

https://sourceware.org/git/?p=glibc.git;a=commit;h=ade8b817fead73b302d08c88cd44ea2ea56793d4

## 解决方案

1. 在 Deployment 或 Pod 的 YAML 里写上固定阈值。容器内的 `getconf` 在这份 glibc 上可能仍是 0，不要写 shell 表达式。

```yaml
env:
  - name: GLIBC_TUNABLES
    value: "glibc.cpu.x86_non_temporal_threshold=201326592"
```

2. 把镜像中的 glibc 升级到 2.29 或更高版本，使海光 CPUID 被识别，阈值按真实 L3 计算。
