#!/usr/bin/env bash
# 切换到最终架构:4 副本数据并行 + 共享专家池 + 16GB GPU 注册上限 + 预填/投机调优
# 前提:已跑过 02-install-strata.sh(模型就绪),systemd 服务为 strata
# 用法:bash 04-enable-shared-arena.sh [STRATA_DIR,默认 ~/Strata]
set -euo pipefail

STRATA_DIR="${1:-$HOME/Strata}"
CFG="$STRATA_DIR/strata-unsloth-ud-iq4_xs.json"
ARENA=/dev/shm/strata-expert-arena

[ -f "$CFG" ] || { echo "找不到 $CFG,先跑 02-install-strata.sh"; exit 1; }

# /dev/shm 默认只有内存一半,装不下 56GB 池
sudo mount -o remount,size=70G /dev/shm

rm -f "$ARENA"   # 旧池作废,首引擎会重建(16GB 注册档首启约 8~10 分钟)

python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["replicas"] = 4
a = c["args"]
def set_flag(flag, value):
    """幂等写入二元参数:先删旧值再追加"""
    if flag in a:
        i = a.index(flag); del a[i:i+2]
    a += [flag, value]
# 与 --shared-expert-arena 互斥:无预算标志 = 引擎装载完整池
if "--resident-budget-gib" in a:
    i = a.index("--resident-budget-gib"); del a[i:i+2]
if "--shared-expert-arena" not in a:
    a += ["--shared-expert-arena", "/dev/shm/strata-expert-arena"]
# 调优:长提示词预填分段 +13%(694→785 tok/s @35K prompt),投机草稿门槛 0.7(接受率 53%~83%)
set_flag("--prefill", "auto:32768")
set_flag("--spec-min-p", "0.7")
# 关键:大范围 hipHostRegister 在多进程下会崩(ROCM-29767),
# 每进程只注册 16GB(阶梯实测 1/4/16GB 稳、25GB+ 崩),比 1GB 档快 8~13%
c.setdefault("env", {})["STRATA_ARENA_PIN_GIB"] = "16"
c["env"]["GPU_PINNED_MIN_XFER_SIZE"] = "1048576"
json.dump(c, open(p, "w"), indent=2)
print("已写入:", {k: c[k] for k in ("replicas",) if k in c}, "| env =", c["env"])
PYEOF

sudo systemctl restart strata
echo "已重启。16GB 注册档装载约 8~10 分钟(每进程钉 ~400 万页,较慢属正常),用 03-verify.sh 或 curl http://127.0.0.1:8080/health 等待 loaded:true"
