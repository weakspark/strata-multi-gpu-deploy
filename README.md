# 基于 Strata 的多显卡多并发改造:4× RX 7900 XTX 数据并行 + 共享专家池部署实录

> 建议仓库名:`strata-multi-gpu-deploy`(或 `strata-4x7900xtx-parallel`)

在 4 张 RX 7900 XTX + **单颗** AMD EPYC 7K62(48 核 96 线程)+ 128GB 内存的"穷人顶配"上,把 [Strata](https://github.com/Niko1221/Strata)(Qwen3.8-Flash-Next 125B MoE 本地推理 UD-IQ4_XS 版本)从官方默认配置改造成 **4 路真并发、聚合 188.6 tok/s、256K 上下文**——专家权重在内存里只放**一份**,四张卡按需取用。

> English summary at the bottom. / [English intro](#english-summary)

## 这个仓库是什么,不是什么

**是**:基于上游 [Strata](https://github.com/Niko1221/Strata) 的**部署配置改造与调优实录**。最终方案**零引擎代码改动**,全部通过 Strata 自带的配置项(`replicas`、`--shared-expert-arena`、`STRATA_ARENA_PIN_GIB`)组合实现,外加一个被实测定位、已准备好上报上游的 ROCm 缺陷及其旁路。

**不是**:Strata 的 fork。引擎二进制就是上游 0.1.45(commit 477ac13),本仓库不改它的源码、不跟它的发布节奏耦合,`update.sh` 升级上游后本仓库的配置依然适用(参数语义由上游定义)。

## 为什么要改(动机,全部有实测数字)

| 官方默认/常见配置的问题 | 实测 |
|---|---|
| 单引擎 4 卡层切分:单流快,但**整机只有一条流水线**,多请求全排队 | 单流 63.5,第二个请求起只能等 |
| `--parallel` 批槽并发:此负载下**负优化** | 聚合只有 44.4(比单流还低) |
| 常规多副本(replicas):每副本**各自复制一份内存专家池**,128GB 撑不起 4 路 | 4×私有预算直接内存墙(5.9 tok/s) |

目标:4 张卡各自独立服务一路请求(**真 4 并发**),同时 128GB 内存里只放**一份** 56GB 专家池(**省内存**)。结果:聚合 188.6 tok/s,是官方默认单流的 **3 倍**、默认配置并发能力的 **4.6 倍**。

改造过程中还定位并绕过了一个 ROCm 缺陷(多进程大范围 `hipHostRegister` 崩溃,详见 [docs/ROCM-SHARED-ARENA.md](docs/ROCM-SHARED-ARENA.md)),这部分的完整证据链对任何多卡 ROCm 用户都有参考价值。

## 最终架构(全部实测)

```
客户端 → http://<服务器IP>:8080(自动路由到最空闲的一路)
          ├─ 副本1(GPU0)─ 显存 ~16GB 热专家缓存 + 16GB 零拷贝注册
          ├─ 副本2(GPU1)─      ……
          ├─ 副本3(GPU2)─  共享:56GB 专家池(MAP_SHARED,全机一份)
          └─ 副本4(GPU3)─        + 每路 12 个独占物理核 + 256K 独立 KV
```

| 架构演进(中文小说负载,2000 token/请求) | 每路 tok/s | 聚合 tok/s |
|---|---|---|
| **4 副本 + 共享池 + 16GB 注册(本仓库,定档)** | 45.6~52.4 | **188.6** |
| 4 副本 + 8GB 私有预算 + 页缓存 | 24~30 | 102.3 |
| 2 副本(2卡/路)+ 25GB 私有预算 | 51~53 | 101.8 |
| 单引擎 4 卡层切分(纯单流最优) | 63.5 | 63.5 |
| parallel=4 批槽 | 8~20 | 44.4(负优化,弃用) |
| 4 副本 + 共享池 + 全量注册 | —— | 崩溃(见下) |

## 关键发现:ROCm 大范围 hipHostRegister 是 4 路共享池的崩点,也是解法所在

**问题**:4 个引擎共享一份 56GB 池、每进程全量注册(`hipHostRegister`)时,注册返回"成功"但 ROCm 运行时内部状态已损,启动尾声确定性集体 SIGSEGV(1~2 进程完全正常)。反汇编定位:内部映射描述符表指针为 NULL 仍被写标志位。

**根因**:AMD 官方将大范围 `hipHostRegister` 标记为永久性限制(ROCM-29767"Performance and Kernel Stability Limitations with Large Registrations";TheRock #8939 同款"注册成功但状态已损"签名)。

**解法(一个环境变量,零改码)**:

```json
"env": {"STRATA_ARENA_PIN_GIB": "16"}
```

每进程只向 GPU 注册 16GB(阶梯实测:1GB=46.9 稳、4GB=53.2 稳、**16GB=51.3 稳**、25GB 崩),其余 40GB 照常 mlock 驻留——CPU 专家池读内存**不需要**注册,GPU 侧由显存缓存+注册窗覆盖。相比 1GB 档提速 8~13%,4 路全稳。注意 16GB 档启动装载约 8~10 分钟(每进程钉 400 万页),属正常。

完整取证(反汇编、排除矩阵、注册尺寸实验)见 [docs/ROCM-SHARED-ARENA.md](docs/ROCM-SHARED-ARENA.md);已整理成上游 issue 模板,欢迎去 Strata 仓库顶帖。

## 快速部署

```bash
# 1. 系统准备(Ubuntu 22.04/24.04,内核 amdgpu 驱动,无需系统级 ROCm)
bash scripts/01-prepare-system.sh

# 2. 安装 Strata(克隆/编译/模型下载,免交互;国内网络已适配,见下节)
STRATA_HOST=0.0.0.0 bash scripts/02-install-strata.sh

# 3. 切换到 4 副本 + 共享专家池架构(本文档的主角)
bash scripts/04-enable-shared-arena.sh

# 4. 验证
bash scripts/03-verify.sh
```

网络适配(中国大陆实测):模型走 ModelScope(`STRATA_SOURCE=modelscope`,实测 ~40MB/s)、PyPI 走阿里/清华镜像、ROCm TheRock 轮子直连(实测 2~5MB/s)、GitHub 慢时仓库可从任意快机 rsync 过去。详见脚本内注释。

## 运维要点

- **服务器重启后必须**:`sudo mount -o remount,size=70G /dev/shm && sudo systemctl restart strata`(tmpfs 重置,共享池自动重建;16GB 注册档首启约 **8~10 分钟**,勿误判卡死)
- `--shared-expert-arena` 与 `--resident-budget-gib` 互斥;无预算标志 = 完整池
- 内核参数(iommu=pt、ttm.pages_limit、amdgpu gttsize)保留无害
- 版本锚点:Strata 0.1.45(477ac13)/ ROCm TheRock 7.14.0a20260612(gfx110X-all)/ Ubuntu 24.04.5
- 并发压测脚本:`python3 scripts/concurrency-test.py 4`

## 硬件账本(为什么这么配)

- 专家池 59.5GB:4×24GB 显存摊不下单卡,但"4 卡显存缓存 + 一份 56GB 共享内存主本"刚好全覆盖
- KV 只有 12+1 层(其余 36 层是 DeltaNet 循环状态):每 token 仅 13.4KB,4×256K 上下文只吃 14.4GB 内存
- CPU 专家池 ~15 worker 饱和,48 物理核 ÷ 4 路每路 12 核,仅损失 5~10%
- 内存 8 通道只插 4 条 = 带宽腰斩;补 4 条既翻带宽又解锁更富余的共享池

## English summary

**Multi-GPU, multi-stream deployment recipes on top of upstream [Strata](https://github.com/Niko1221/Strata)** — a configuration-level rework (no engine fork; final solution is zero engine-code change) that turns the stock single-pipeline setup into **4 truly concurrent inference lanes on 4× RX 7900 XTX + one EPYC 7K62 + 128 GB RAM**: 4 data-parallel engines sharing ONE 56 GB expert pool in RAM (MAP_SHARED + pack-hash-checked `--shared-expert-arena`), 4 concurrent streams at 45–52 tok/s each, **188.6 tok/s aggregate** (3× the stock single-stream), 256K context. Why rework: the stock layer-split serves one request at a time (63.5 tok/s), batch slots are a net negative here (44.4), and naive replicas hit a RAM wall (each replica duplicates the expert pool). Key finding along the way: whole-arena `hipHostRegister` across 4 processes deterministically SIGSEGVs inside libamdhip64 (a documented permanent ROCm limitation for very large registrations); capping registration via `STRATA_ARENA_PIN_GIB` (1/4/16 GiB tested stable; we ship 16 GiB) is a zero-code workaround. Full evidence, benchmarks for six architecture variants, China-network install cookbook, and ops notes inside. Versions: Strata 0.1.45 (upstream, unmodified), TheRock ROCm 7.14.0a20260612, Ubuntu 24.04.5.

## License

MIT. Benchmark numbers are from our specific box (see "版本锚点"); your mileage will vary — measure on your own hardware.
