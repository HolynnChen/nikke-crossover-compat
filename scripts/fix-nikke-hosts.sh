#!/bin/bash
# NIKKE /etc/hosts 优化与体检（并发版）。
#
# 背景（为什么要有这个脚本）
#   NIKKE 的多个域名在国内被解析污染：
#       cloud.nikke-kr.com, *-lobby.nikke-kr.com, *-match.nikke-kr.com
#       cos-dev.nikke-kr.com        -> 0.0.0.1
#       nikke-kr.com, nikke-en.com  -> 127.0.0.1
#   所以 /etc/hosts 里的写死条目不是"优化"，是"保命"——不写就根本连不上。
#   但条目会过期，且旧版只修 cloud 一个域名，其余没人验证，
#   一旦过期表现为"登录不上"。
#
# 它做什么
#   1) 体检：逐个检查 hosts 里已 pin 的域名是否还能连通（TCP+TLS）
#   2) 选优：对 CDN 类域名，从多个地区的解析结果里挑当前最快的节点
#   3) 默认 CDN 类与网关类都写入；加 --cdn-only 可只动 CDN 类
#      （网关类改动会影响能否登录，写入后请进游戏确认；--dry-run 可先预览）
#
# ★ 候选 IP 怎么来
#   用 EDNS Client Subnet（ECS）：Google DoH 支持
#       dns.google/resolve?name=X&type=A&edns_client_subnet=<某地区网段>
#   于是可以用各地区网段去问，拿到"该地区会得到的答案"，
#   再从本机实测这些候选的连通性与延迟，取最快的。
#   旧版靠硬编码的 CloudFront 兜底清单，实测其中 18.238.96.1 的 RTT
#   高达 374ms，而香港边缘只有 28ms —— 清单本身就是最差选项之一。
#
# ★ 并发
#   全流程都是网络等待，因此 ECS 解析与候选实测都并发跑（默认 12 路）。
#   每个任务由本脚本以内部模式（--_ecs / --_measure）拉起的子进程完成，
#   结果按行汇总后统一排序。串行需要 5-8 分钟，并发约 20-40 秒。
#
# 用法：
#   bash fix-nikke-hosts.sh --dry-run            # 体检+测速，不写 hosts（免 root）
#   sudo bash fix-nikke-hosts.sh                 # 体检 + 优化（默认含网关类）
#   sudo bash fix-nikke-hosts.sh --cdn-only      # 只优化 CDN 类，网关只体检不写入
#   JOBS=24 bash fix-nikke-hosts.sh --dry-run    # 调整并发度
#
set -uo pipefail

HOSTS=/etc/hosts
MARKER="#UHE_"
JOBS=${JOBS:-12}
DRY_RUN=0
INCLUDE_GATEWAYS=1

DOMAINS="
cloud.nikke-kr.com:cdn
global-lobby.nikke-kr.com:gateway
global-match.nikke-kr.com:gateway
jp-lobby.nikke-kr.com:gateway
jp-match.nikke-kr.com:gateway
kr-lobby.nikke-kr.com:gateway
kr-match.nikke-kr.com:gateway
sea-lobby.nikke-kr.com:gateway
sea-match.nikke-kr.com:gateway
hmt-lobby.nikke-kr.com:gateway
hmt-match.nikke-kr.com:gateway
cos-dev.nikke-kr.com:plain
nikke-kr.com:plain
"

# 用于"模拟各地区解析"的网段。不需要很精确，只需能代表该地区。
REGIONS="
210.140.0.0/24:日本
168.126.63.0/24:韩国
203.116.0.0/24:新加坡
202.64.0.0/24:香港
168.95.0.0/24:台湾
203.113.0.0/24:越南
171.100.0.0/24:泰国
8.8.8.0/24:美国西部
4.2.2.0/24:美国东部
80.128.0.0/24:德国
1.128.0.0/24:澳洲
49.32.0.0/24:印度
"

# ---------------------------------------------------------------- 内部工作进程
# 单独一次 ECS 解析：打印 "ECS<空格>域名<空格>地区<空格>IP"
if [ "${1:-}" = "--_ecs" ]; then
    domain=$2; subnet=$3; region=$4
    ips=$(curl -s --max-time 8 -H 'accept: application/dns-json' \
          "https://dns.google/resolve?name=$domain&type=A&edns_client_subnet=$subnet" 2>/dev/null \
          | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(' '.join(sorted({a['data'] for a in d.get('Answer', []) if a.get('type') == 1})))
except Exception:
    pass" 2>/dev/null)
    for ip in $ips; do
        case "$ip" in 0.0.0.1|127.0.0.1) continue ;; esac
        printf 'ECS %s %s %s\n' "$domain" "$region" "$ip"
    done
    exit 0
fi

# 单独一次候选实测：打印 "RES<空格>域名<空格>IP<空格>延迟<空格>可达"
# 延迟优先用 ICMP 真实 RTT；拿不到就退回 TLS 握手秒数（前缀 ~ 表示）
if [ "${1:-}" = "--_measure" ]; then
    domain=$2; ip=$3
    # ping 与 curl 并行：很多 CDN 节点不回 ICMP，串行会白等一个超时
    pingout=$(mktemp)
    ( ping -c 2 -t 2 "$ip" 2>/dev/null | tail -1 \
      | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | cut -d/ -f2 > "$pingout" ) &
    pingjob=$!
    code=$(curl -s -o /dev/null -w '%{http_code} %{time_appconnect}' --max-time 6 \
           --resolve "$domain:443:$ip" "https://$domain/" 2>/dev/null)
    wait "$pingjob" 2>/dev/null
    rtt=$(cat "$pingout" 2>/dev/null)
    rm -f "$pingout" 
    http=${code%% *}
    tls=${code##* }
    if [ -n "$rtt" ]; then lat=$rtt; else lat="~${tls:-x}"; fi
    ok="✗"; { [ -n "$http" ] && [ "$http" != "000" ]; } && ok="✓"
    printf 'RES %s %s %s %s\n' "$domain" "$ip" "$lat" "$ok"
    exit 0
fi

# ---------------------------------------------------------------------- 主流程
# 参数解析用 while + shift：在 for 循环里 shift 不会生效
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)          DRY_RUN=1; shift ;;
        --include-gateways) INCLUDE_GATEWAYS=1; shift ;;
        --cdn-only)         INCLUDE_GATEWAYS=0; shift ;;
        --jobs)             JOBS=${2:-12}; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done
command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; exit 1; }

current_pin() { # domain -> ip
    awk -v d="$1" '$0 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == d) { print $1; exit } }' "$HOSTS"
}

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

START=$(date +%s)
echo "=========================================================="
echo " NIKKE hosts 体检 + 优化（并发 ${JOBS} 路）"
[ "$DRY_RUN" -eq 1 ] && echo " 模式：--dry-run（不会修改 /etc/hosts）"
[ "$INCLUDE_GATEWAYS" -eq 1 ] && echo " 范围：CDN 类 + 网关类" || echo " 范围：仅 CDN 类（--cdn-only）"
echo "=========================================================="
echo
echo "[1/3] 并发解析各地区的候选 IP ..."

# 生成 ECS 任务清单：域名 网段 地区
: > "$WORK/ecs-tasks"
for entry in $DOMAINS; do
    domain=${entry%%:*}
    for r in $REGIONS; do
        printf '%s %s %s\n' "$domain" "${r%%:*}" "${r##*:}" >> "$WORK/ecs-tasks"
    done
done
# shellcheck disable=SC2016
awk '{print $1, $2, $3}' "$WORK/ecs-tasks" \
  | xargs -P "$JOBS" -n 3 "$0" --_ecs > "$WORK/ecs-results" 2>/dev/null
printf '      完成：%s 条候选记录\n' "$(grep -c '^ECS' "$WORK/ecs-results" 2>/dev/null || echo 0)"

echo "[2/3] 并发实测连通性与延迟 ..."
# 生成实测任务清单：域名 IP（含各候选 + hosts 现值）
: > "$WORK/measure-tasks"
for entry in $DOMAINS; do
    domain=${entry%%:*}
    pin=$(current_pin "$domain")
    [ -n "$pin" ] && printf '%s %s\n' "$domain" "$pin" >> "$WORK/measure-tasks"
    grep "^ECS $domain " "$WORK/ecs-results" 2>/dev/null | awk '{print $2, $4}' >> "$WORK/measure-tasks"
done
sort -u "$WORK/measure-tasks" > "$WORK/measure-uniq"
TOTAL=$(wc -l < "$WORK/measure-uniq" | tr -d ' ')
xargs -P "$JOBS" -n 2 "$0" --_measure < "$WORK/measure-uniq" > "$WORK/results" 2>/dev/null
printf '      完成：实测 %s 个候选（去重后 %s 个任务）\n' \
       "$(grep -c '^RES' "$WORK/results" 2>/dev/null || echo 0)" "$TOTAL"

echo "[3/3] 汇总"
echo
BEST_OF_ALL=""
PENDING=0
for entry in $DOMAINS; do
    domain=${entry%%:*}
    kind=${entry##*:}
    echo "── $domain  [$kind]"
    pin=$(current_pin "$domain")
    if [ -n "$pin" ]; then
        line=$(grep "^RES $domain $pin " "$WORK/results" 2>/dev/null | head -1)
        lat=$(echo "$line" | awk '{print $4}'); ok=$(echo "$line" | awk '{print $5}')
        if [ "$ok" = "✓" ]; then
            printf '   hosts 现值 : %-16s 可达 ✓  延迟 %s\n' "$pin" "${lat:-?}"
        else
            printf '   hosts 现值 : %-16s ✗ 不可达（过期了，需要换）\n' "$pin"
        fi
    else
        printf '   hosts 现值 : （未 pin）\n'
    fi

    if [ "$kind" != "plain" ]; then
        cands=$(grep "^ECS $domain " "$WORK/ecs-results" 2>/dev/null \
                | awk '{print $3" "$4}' | sort -u)
        if [ -n "$cands" ]; then
            printf '   候选(ECS 各地区解析):\n'
            echo "$cands" | awk '{printf "     %-10s %s\n", $1, $2}'
            echo "   实测:"
            best=""; best_score=999999
            while read -r region ip; do
                line=$(grep "^RES $domain $ip " "$WORK/results" 2>/dev/null | head -1)
                lat=$(echo "$line" | awk '{print $4}'); ok=$(echo "$line" | awk '{print $5}')
                [ -z "$lat" ] && continue
                case "$lat" in
                    ~*) score=$(python3 -c "print(int(float('${lat#\~}')*1000))" 2>/dev/null || echo 999999) ;;
                    x)  score=999999 ;;
                    *)  score=${lat%%.*} ;;
                esac
                printf '     %-16s %s  延迟 %-10s\n' "$ip" "${ok:-?}" "$lat"
                if [ "${ok:-}" = "✓" ] && [ "$score" -lt "$best_score" ] 2>/dev/null; then
                    best=$ip; best_score=$score
                fi
            done <<< "$cands"
            [ -n "$best" ] && printf '   → 最快: %s\n' "$best"

            if [ -n "$best" ] && [ "$best" != "$pin" ]; then
                if [ "$kind" = "cdn" ] || [ "$INCLUDE_GATEWAYS" -eq 1 ]; then
                    if [ "$DRY_RUN" -eq 1 ]; then
                        printf '   [dry-run] 将写入: %s %s\n' "$best" "$domain"
                        PENDING=1
                    else
                        BEST_OF_ALL="$BEST_OF_ALL$domain=$best;"
                    fi
                else
                    printf '   （网关类；如只想动 CDN 类请加 --cdn-only）\n'
                fi
            elif [ -n "$best" ]; then
                printf '   （现值已是最快，无需改动）\n'
            fi
        else
            printf '   （没有候选，跳过）\n'
        fi
    fi
    echo
done

# 写入
if [ -n "$BEST_OF_ALL" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 才能改 $HOSTS：请用 sudo 重新运行。" >&2
        exit 1
    fi
    STAMP=$(date +%Y%m%d-%H%M%S)
    cp -p "$HOSTS" "$HOSTS.bak-nikke-$STAMP"
    echo "已备份: $HOSTS.bak-nikke-$STAMP"
    python3 - "$HOSTS" "$BEST_OF_ALL" "$MARKER" <<'PY'
import sys
hosts, pairs, marker = sys.argv[1], sys.argv[2], sys.argv[3]
wanted = dict(p.split("=", 1) for p in pairs.strip(";").split(";") if p)
lines = open(hosts, encoding="utf-8").read().splitlines()
out, done = [], set()
for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
        body = stripped.split("#", 1)[0].split()
        if len(body) >= 2:
            hit = next((d for d in wanted if d in body[1:]), None)
            if hit:
                out.append(f"{wanted[hit]} {hit} {marker}")
                done.add(hit)
                continue
    out.append(line)
for d, ip in wanted.items():
    if d not in done:
        out.append(f"{ip} {d} {marker}")
open(hosts, "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"已更新 {len(wanted)} 个域名: " + ", ".join(f"{d}->{i}" for d, i in wanted.items()))
PY
    echo
    echo "--- 改动对比 ---"
    diff "$HOSTS.bak-nikke-$STAMP" "$HOSTS" || true
    echo
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    echo "DNS 缓存已刷新。重启游戏生效。"
elif [ "$PENDING" -eq 1 ]; then
    echo "结论：有可优化的节点（见上方 [dry-run] 行）；去掉 --dry-run 即会写入。"
else
    echo "结论：无需写入任何改动。"
fi

printf '\n耗时 %s 秒（并发 %s 路）\n' "$(( $(date +%s) - START ))" "$JOBS"
