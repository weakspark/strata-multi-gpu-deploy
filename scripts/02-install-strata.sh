#!/usr/bin/env bash
# Strata 推理服务器 - 步骤 2/3:克隆仓库并免交互安装(ROCm 进 venv + 现场编译引擎 + 下载模型)
# 环境变量(均有默认值):
#   STRATA_DIR     安装目录,默认 ~/Strata
#   DATA_DIR       模型数据目录,默认在仓库旁边的 Strata-data;磁盘紧张时指到大 NVMe,如 /data/strata
#   STRATA_FAMILY  模型家族,默认 qwen(可选 unsloth / swift / coder)
#   STRATA_MODEL   量化档位,默认 IQ3_S(128G 内存推荐;追求质量用 unsloth + UD-IQ4_XS)
#   STRATA_HOST    监听地址,默认 127.0.0.1;对局域网开放设 0.0.0.0(会强制配 API key)
#   STRATA_API_KEY 对外开放时的 API 密钥;设了 0.0.0.0 又没给 key 时自动生成并存入 $STRATA_DIR/.api-key
#   STRATA_GPUS    使用的卡,默认 all(2 张和 4 张 7900 XTX 都直接用 all)
set -euo pipefail

say() { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }

STRATA_DIR="${STRATA_DIR:-$HOME/Strata}"
DATA_DIR="${DATA_DIR:-}"
FAMILY="${STRATA_FAMILY:-qwen}"
MODEL="${STRATA_MODEL:-IQ3_S}"
HOST="${STRATA_HOST:-127.0.0.1}"
API_KEY="${STRATA_API_KEY:-}"
GPUS="${STRATA_GPUS:-all}"

if [[ "$(id -u)" -eq 0 ]]; then
    say "当前是 root。建议用普通用户(已在 render/video 组)运行本脚本,便于后续 systemd 以该用户常驻"
fi

# ---------- 对外开放必须带密钥(官方安全要求) ----------
if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" && -z "$API_KEY" ]]; then
    API_KEY="$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -n1)"
    say "已生成 API 密钥(同时会写入 $STRATA_DIR/.api-key):$API_KEY"
fi

# ---------- 克隆 ----------
say "获取 Strata 代码到 $STRATA_DIR"
if [[ ! -d "$STRATA_DIR/.git" ]]; then
    git clone https://github.com/Niko1221/Strata.git "$STRATA_DIR"
else
    echo "目录已存在,跳过克隆(更新请进目录执行 ./update.sh)"
fi
cd "$STRATA_DIR"

# ---------- 组装安装参数 ----------
ARGS=(--backend hip --gpus "$GPUS" --family "$FAMILY" --model "$MODEL"
      --yes --no-start --no-browser)
[[ -n "$DATA_DIR"  ]] && ARGS+=(--data-dir "$DATA_DIR")
if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]]; then
    ARGS+=(--host "$HOST")
    [[ -n "$API_KEY" ]] && ARGS+=(--api-key "$API_KEY")
fi

say "开始安装(参数:${ARGS[*]})"
say "预计耗时:ROCm 轮子下载 ~10GB + 引擎编译 10~20 分钟 + 模型下载 ~84GB(支持断点续传,中断后重跑本脚本即可续传)"
./setup.sh "${ARGS[@]}"

# ---------- 收尾 ----------
if [[ -n "$API_KEY" ]]; then
    umask 077
    printf '%s\n' "$API_KEY" > .api-key
fi

RUN_SCRIPT="run-$(echo "$MODEL" | tr 'A-Z' 'a-z').sh"
say "安装完成。下一步:"
echo "  1) 首次启动并验证:  bash 03-verify.sh"
echo "     (或手动: nohup ./$RUN_SCRIPT > strata-server.out 2>&1 & 然后 curl http://127.0.0.1:8080/health)"
echo "  2) 常驻服务:        参照 systemd/strata.service(把用户名、路径、$RUN_SCRIPT 核对后安装)"
[[ -f .api-key ]] && echo "  3) API 密钥在 $STRATA_DIR/.api-key,客户端用 Authorization: Bearer <密钥>"
