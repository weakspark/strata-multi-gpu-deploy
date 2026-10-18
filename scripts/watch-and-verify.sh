#!/usr/bin/env bash
# 等 Strata 安装(setup.py)结束后自动启动服务并验证
# 自动 picking 最新的 run-*.sh(不同 family/模型的脚本名不同)
LOG="$HOME/strata-install.log"
WLOG="$HOME/watch.log"
# 必须先亲眼见到安装进程在跑,再等它结束(避免安装启动前的空窗期误判)
seen=0
while :; do
    if pgrep -f "setup[.]py" >/dev/null; then
        seen=1
        sleep 30
        continue
    fi
    [ "$seen" = 1 ] && break
    sleep 10
done
sleep 5
if grep -q "Setup stopped" "$LOG"; then
    echo "[$(date '+%F %T')] 安装失败,未启动,详见 $LOG" >> "$WLOG"
    exit 1
fi
RUN=$(ls -t "$HOME"/Strata/run-*.sh 2>/dev/null | head -1)
if [ -z "$RUN" ]; then
    echo "[$(date '+%F %T')] 找不到 run-*.sh 启动脚本,详见 $LOG" >> "$WLOG"
    exit 1
fi
echo "[$(date '+%F %T')] 安装结束,用 $RUN 启动并验证" >> "$WLOG"
cd "$HOME/Strata"
nohup "./$(basename "$RUN")" >> strata-server.out 2>&1 &
ok=0
for _ in $(seq 1 60); do
    curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 && { ok=1; break; }
    sleep 5
done
if [ "$ok" != 1 ]; then
    echo "[$(date '+%F %T')] 服务 5 分钟未就绪,详见 Strata/strata-server.out" >> "$WLOG"
    exit 1
fi
KEY=""
[ -f "$HOME/Strata/.api-key" ] && KEY=$(head -n1 "$HOME/Strata/.api-key")
AUTH=()
[ -n "$KEY" ] && AUTH=(-H "Authorization: Bearer $KEY")
ANSWER=$(curl -sf "${AUTH[@]}" http://127.0.0.1:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"strata","messages":[{"role":"user","content":"用一句话介绍你自己"}],"max_tokens":60}')
if [ -n "$ANSWER" ]; then
    echo "[$(date '+%F %T')] 验证成功:服务在 http://${SERVER_IP:-<your.server.ip>}:8080,/health 与对话接口均正常" >> "$WLOG"
    echo "$ANSWER" > /tmp/strata-smoke.json
else
    echo "[$(date '+%F %T')] 服务就绪但对话接口测试失败" >> "$WLOG"
fi
