#!/usr/bin/env bash
# Strata 推理服务器 - 步骤 1/3:系统准备与硬件自检
# 在 Ubuntu 22.04/24.04 服务器上以普通用户(sudo 权限)执行
set -euo pipefail

say()  { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }

# ---------- 系统版本 ----------
say "检查系统版本"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "发行版: ${PRETTY_NAME:-未知}  内核: $(uname -r)"
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
        echo "OK:官方支持的全自动安装版本"
    else
        warn "推荐 Ubuntu 22.04 或 24.04 LTS;其他版本未必能走全自动路径,可继续但留意报错"
    fi
else
    warn "无法读取 /etc/os-release,按非 Ubuntu 处理,以下 apt 步骤可能失败"
fi

# ---------- 安装依赖 ----------
# Strata 在 Linux/AMD 上的最小系统依赖:Python3(带 venv)、C++ 编译器、git。
# cmake/ninja/ROCm 都由 setup 装进项目 venv,无需系统级安装。
say "安装系统依赖(python3 python3-venv build-essential git curl pciutils)"
# DPkg::Lock::Timeout:全新系统首开机的 unattended-upgrades 可能持锁,等它而不是失败
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get -o DPkg::Lock::Timeout=600 install -y python3 python3-venv build-essential git curl pciutils

# ---------- GPU 自检 ----------
say "检查 AMD GPU(7900 XTX 的 PCI ID 是 1002:744c)"
lspci -nn | grep -Ei 'VGA|Display|1002:744c' || true
XTX_COUNT=$(lspci -nn 2>/dev/null | grep -ci '1002:744c' || true)
if (( XTX_COUNT >= 2 )); then
    echo "OK:检测到 ${XTX_COUNT} 张 RX 7900 XTX"
elif (( XTX_COUNT == 1 )); then
    warn "只检测到 1 张 7900 XTX,请检查另一张卡的供电/插槽(lspci -nn | grep -i amd)"
else
    warn "未检测到 7900 XTX:lspci 看不到卡先查硬件;看得到但驱动未绑(amdgpu)则更新内核"
fi
if [[ -e /dev/kfd ]]; then
    echo "OK:/dev/kfd 存在(amdgpu 内核驱动已加载)"
else
    warn "/dev/kfd 不存在:amdgpu 未加载或卡未被接管,dmesg | grep -i amdgpu 排查"
fi
ls -l /dev/dri/ 2>/dev/null || warn "/dev/dri 不存在,图形设备节点缺失"

# ---------- 用户组权限 ----------
# 访问 /dev/kfd 与 /dev/dri/renderD* 需要 render 和 video 组(Strata 官方要求)
say "检查 GPU 访问权限(render/video 组)"
if [[ "$(id -u)" -eq 0 ]]; then
    warn "当前是 root:能直接访问 GPU,但建议用普通用户部署和运行服务"
elif id -nG "$USER" | grep -qw render && id -nG "$USER" | grep -qw video; then
    echo "OK:${USER} 已在 render 和 video 组"
else
    sudo usermod -aG render,video "$USER"
    warn "已把 ${USER} 加入 render,video 组 —— 必须【注销重新登录】(或重启)后才生效,然后重新运行本脚本确认"
fi

# ---------- 资源报告 ----------
say "资源报告"
echo "CPU:$(nproc) 线程 | 内存:$(free -h | awk '/^Mem:/{print $2}') 总量,可用 $(free -h | awk '/^Mem:/{print $7}')"
echo "内存低于 64GB 只能跑低档量化;128GB 可全驻留 IQ3_S / UD-IQ4_XS"
echo
df -h / /home 2>/dev/null | sort -u
echo
warn_if_low=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 999)
if (( warn_if_low < 250 )); then
    warn "根分区可用空间不足 250GB:模型+ROCm+缓存会很紧张,建议把数据目录指到大 NVMe(安装脚本支持 DATA_DIR=)"
fi

say "系统准备完成。若上面提示了重新登录,先重登;否则继续执行 02-install-strata.sh"
