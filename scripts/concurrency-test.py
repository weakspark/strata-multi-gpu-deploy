#!/usr/bin/env python3
"""Strata 并发压测:N 个线程各自持续生成不同话题,统计每流速度与总吞吐。用法: concurrency-test.py [流数,默认4] 只用标准库。"""
import json, os, threading, time, urllib.request, sys

N = max(1, min(4, int(sys.argv[1]) if len(sys.argv) > 1 else 4))

BASE = os.environ.get("STRATA_BASE", "http://127.0.0.1:8080")
KEY = open(os.path.join(os.environ.get("STRATA_DIR", os.path.expanduser("~/Strata")), ".api-key")).read().strip()
ISSUE_WINDOW = 240   # 持续发起新请求的窗口(秒);尾部等最后一个请求收尾,总时长约4.5-5分钟
MAX_TOKENS = 900

TOPICS = [
    ["写一篇科幻小说,主角是飞船工程师林晚,持续写正文",
     "继续这篇小说,写林晚发现引擎异常后的剧情"],
    ["写一篇武侠小说,主角柳青崖夜探黑风寨,持续写正文",
     "继续写柳青崖与寨主的交锋"],
    ["写一篇奇幻小说,见习法师艾拉在图书馆禁书区的冒险,持续写正文",
     "继续写艾拉解开第一道封印"],
    ["写一篇都市悬疑小说,外卖员陈默发现每次配送的地址都不存在,持续写正文",
     "继续写陈默按图索骥找到规律"],
]

results = [[] for _ in range(N)]

def worker(idx, prompts):
    topic = 0
    t_end_issue = time.time() + ISSUE_WINDOW
    while time.time() < t_end_issue - 70:   # 留出尾部,避免最后发不完
        p = prompts[topic % len(proms := prompts)]
        topic += 1
        body = json.dumps({"model": "strata", "messages": [{"role": "user", "content": p}],
                           "max_tokens": MAX_TOKENS}).encode()
        req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + KEY})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                out = json.loads(r.read())
            dt = time.time() - t0
            toks = out["usage"]["completion_tokens"]
            results[idx].append((toks, dt))
            print(f"[流{idx}] {toks} tok / {dt:.1f}s = {toks/dt:.1f} tok/s", flush=True)
        except Exception as e:
            print(f"[流{idx}] 请求失败: {e}", flush=True)
            time.sleep(2)

t0 = time.time()
threads = [threading.Thread(target=worker, args=(i, TOPICS[i])) for i in range(N)]
for t in threads: t.start()
for t in threads: t.join()
total_t = time.time() - t0

print("\n===== 汇总 =====")
grand = 0
for i, rs in enumerate(results):
    toks = sum(r[0] for r in rs); n = len(rs)
    gen_t = sum(r[1] for r in rs)
    grand += toks
    per = toks / gen_t if gen_t else 0
    print(f"流{i}: {n} 个请求, {toks} tokens, 生成占用 {gen_t:.0f}s, 平均 {per:.1f} tok/s")
print(f"总时长: {total_t:.0f}s | 总token: {grand} | 聚合吞吐: {grand/total_t:.1f} tok/s")
