#!/usr/bin/env bash
# Strata 推理服务器 - 步骤 3/3:首次启动 + 健康检查 + API 冒烟测试
# 环境变量:STRATA_DIR(默认 ~/Strata)、STRATA_MODEL(默认 IQ3_S)、PORT(默认 8080)
set -euo pipefail

say() { printf '\n\033[1;32m== %s\033[0m\n' "$*"; }

STRATA_DIR="${STRATA_DIR:-$HOME/Strata}"
MODEL="${STRATA_MODEL:-IQ3_S}"
PORT="${PORT:-8080}"
RUN_SCRIPT="run-$(echo "$MODEL" | tr 'A-Z' 'a-z').sh"
BASE="http://127.0.0.1:${PORT}"

# 带密钥访问(安装时对外开放的话)
AUTH=()
if [[ -f "$STRATA_DIR/.api-key" ]]; then
    AUTH=(-H "Authorization: Bearer $(head -n1 "$STRATA_DIR/.api-key")")
fi

# ---------- 启动(若未在跑) ----------
if curl -sf "$BASE/health" >/dev/null 2>&1; then
    say "服务已在运行,直接验证"
else
    [[ -x "$STRATA_DIR/$RUN_SCRIPT" ]] || {
        echo "找不到 $STRATA_DIR/$RUN_SCRIPT:确认模型名(STRATA_MODEL)是否与安装时一致,或先跑 02-install-strata.sh"
        exit 1
    }
    say "启动引擎(首次要把 35~55GB 装载进内存,等 1~3 分钟属正常)"
    cd "$STRATA_DIR"
    nohup "./$RUN_SCRIPT" >> strata-server.out 2>&1 &
    echo "服务进程 PID:$!(日志:$STRATA_DIR/strata-server.out)"
fi

# ---------- 等健康检查通过 ----------
say "等待 /health 就绪(最长 5 分钟)"
ok=0
for _ in $(seq 1 60); do
    if curl -sf "$BASE/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 5
done
if (( ! ok )); then
    echo "超时:服务 5 分钟内未就绪。查看日志:tail -100 $STRATA_DIR/strata-server.out"
    exit 1
fi
echo "OK:/health 通过"

# ---------- 模型列表 ----------
say "已加载模型"
curl -sf "${AUTH[@]}" "$BASE/v1/models" && echo

# ---------- 冒烟测试 ----------
say "发送一条测试对话(OpenAI 兼容接口)"
curl -sf "${AUTH[@]}" "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"strata","messages":[{"role":"user","content":"用一句话介绍你自己"}],"max_tokens":100}' \
    | tee /tmp/strata-smoke.json
echo
if command -v python3 >/dev/null; then
    python3 - <<'PY' 2>/dev/null || true
import json
try:
    r = json.load(open('/tmp/strata-smoke.json'))
    print("\n模型回复:", r['choices'][0]['message']['content'][:200])
except Exception:
    pass
PY
fi

say "验证完成。接入方式:"
echo "  OpenAI 兼容:   POST $BASE/v1/chat/completions"
echo "  Anthropic 兼容: POST $BASE/v1/messages(或 /anthropic 路径,见官方 docs)"
echo "  Web 界面:       浏览器打开 http://${SERVER_IP:-<your.server.ip>}:$PORT(对外开放时需带密钥)"
[[ ${#AUTH[@]} -gt 0 ]] && echo "  API 密钥:       $(head -n1 "$STRATA_DIR/.api-key")"
