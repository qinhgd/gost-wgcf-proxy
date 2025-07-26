#!/bin/sh
set -e

# ==============================================================================
# 脚本配置
# ==============================================================================
BEST_IP_FILE="/wgcf/best_ips.txt"
RECONNECT_FLAG_FILE="/wgcf/reconnect.flag"
OPTIMIZE_INTERVAL="${OPTIMIZE_INTERVAL:-21600}"
BEST_IP_COUNT="${BEST_IP_COUNT:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"

# --- Telegram Bot 配置 ---
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
HOSTNAME="${HOSTNAME:-WARP}"

# ==============================================================================
# 工具函数 和 TG通知函数
# ==============================================================================
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
send_tg_notification() { if [ -z "$TG_BOT_TOKEN" ]||[ -z "$TG_CHAT_ID" ];then return;fi;local message_text="$1";local prefixed_message="*[$HOSTNAME]*
$message_text";curl -sS -X POST --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${prefixed_message}" --data-urlencode "parse_mode=Markdown" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" > /dev/null 2>&1 & }


# ==============================================================================
# IP优选和连接功能
# ==============================================================================
run_ip_selection() {
    green "🚀 开始优选 WARP Endpoint IP..."
    /usr/local/bin/warp -p 0 > /dev/null
    if [ -f "result.csv" ]; then
        green "✅ 优选完成，正在处理结果..."
        awk -F, 'NR > 1 {print $1}' result.csv | sed 's/[[:space:]]//g' | head -n "$BEST_IP_COUNT" > "$BEST_IP_FILE"
        if [ -s "$BEST_IP_FILE" ]; then 
            green "✅ 已生成包含 $(wc -l < "$BEST_IP_FILE") 个IP的列表。"
            return 0
        fi
    fi
    red "⚠️ 未能生成有效IP列表，将使用默认地址。"
    echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"
    return 1
}

_downwgcf(){ yellow "正在清理 WireGuard 接口..."; wg-quick down wgcf >/dev/null 2>&1||true; ip link delete dev wgcf >/dev/null 2>&1||true; yellow "清理完成。"; exit 0;}
update_wg_endpoint(){ green "🔄 正在尝试 Endpoint: $1"; sed -i "s/^Endpoint = .*$/Endpoint = $1/" /etc/wireguard/wgcf.conf;}
_check_connection(){ local check_url="https://www.cloudflare.com/cdn-cgi/trace";local curl_opts="--interface wgcf -s -m ${HEALTH_CHECK_TIMEOUT}";for i in $(seq 1 3);do if curl ${curl_opts} ${check_url} 2>/dev/null|grep -q "warp=on";then return 0;fi;if [ "$i" -lt 3 ];then sleep 1;fi;done;return 1;}
_startProxyServices(){ if ! pgrep -f "gost">/dev/null;then yellow "starting GOST proxy services...";local GOST_COMMAND="gost";local SOCKS5_PORT="${PORT:-1080}";local AUTH_INFO="";[ -n "$USER" ]&&[ -n "$PASSWORD" ]&&AUTH_INFO="${USER}:${PASSWORD}@";local HOST_IP="${HOST:-0.0.0.0}";local SOCKS5_LISTEN_ADDR="socks5://${AUTH_INFO}${HOST_IP}:${SOCKS5_PORT}";GOST_COMMAND="${GOST_COMMAND} -L ${SOCKS5_LISTEN_ADDR}";green "✅ SOCKS5 代理已配置 (端口: ${SOCKS5_PORT})。";if [ -n "$HTTP_PORT" ];then local HTTP_LISTEN_ADDR="http://${AUTH_INFO}${HOST_IP}:${HTTP_PORT}";GOST_COMMAND="${GOST_COMMAND} -L ${HTTP_LISTEN_ADDR}";green "✅ HTTP 代理已配置 (端口: ${HTTP_PORT})。";fi;eval "${GOST_COMMAND} &";yellow "✅ GOST 服务已启动。";fi;}

# 连接函数
try_connect() {
    if [ ! -s "$BEST_IP_FILE" ]; then
        red "IP列表为空，无法尝试连接。"
        return 1
    fi
    
    # 恢复按顺序测试，而不是随机
    while IFS= read -r ip_to_try; do
        update_wg_endpoint "$ip_to_try"
        wg-quick up wgcf
        
        yellow "⏳ 等待1秒让连接稳定..."
        sleep 1

        if _check_connection; then
            SUCCESSFUL_IP="$ip_to_try"
            return 0
        else
            red "❌ Endpoint ${ip_to_try} 连接失败..."
            wg-quick down wgcf >/dev/null 2>&1 || true
            # 【核心修复】: 强制删除接口，确保清理干净
            ip link delete dev wgcf >/dev/null 2>&1 || true
        fi
    done < "$BEST_IP_FILE"
    
    return 1
}


# ==============================================================================
# 主运行函数
# ==============================================================================
runwgcf() {
    trap '_downwgcf' ERR TERM INT

    if [ ! -f "/wgcf/wgcf-account.toml" ]; then
        yellow "服务首次初始化..."
        wgcf register --accept-tos && wgcf generate
        cp wgcf-profile.conf /wgcf/
        cp wgcf-profile.conf /etc/wireguard/wgcf.conf
        sed -i '/\[Peer\]/a PersistentKeepalive = 25' /etc/wireguard/wgcf.conf
    else
        yellow "检测到已有配置，直接加载..."
        cp /wgcf/wgcf-profile.conf /etc/wireguard/wgcf.conf
    fi
    
    [ ! -f "$BEST_IP_FILE" ] && run_ip_selection

    (
        while true; do
            sleep "$OPTIMIZE_INTERVAL"
            yellow "🔄 [定时任务] 准备更新IP列表..."
            echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$RECONNECT_FLAG_FILE"
        done
    ) &

    while true; do
        RENEW_REASON="启动或重连"
        if [ -f "$RECONNECT_FLAG_FILE" ]; then
            RENEW_REASON="定时优选"
            yellow "🔔 [主循环] 收到定时优选信号，执行IP更新..."
            wg-quick down wgcf >/dev/null 2>&1 || true
            ip link delete dev wgcf >/dev/null 2>&1 || true
            run_ip_selection
            rm -f "$RECONNECT_FLAG_FILE"
        fi

        yellow "🚀 [$RENEW_REASON] 开始尝试使用现有列表连接..."
        if try_connect; then
            green "✅ WireGuard 连接成功！"
            local current_time=$(date '+%Y-%m-%d %H:%M:%S')
            send_tg_notification "*✅ WARP 连接成功*

*任务类型:* $RENEW_REASON
*成功连接IP:* \`$SUCCESSFUL_IP\`
*连接时间:* \`$current_time\`"
            
            _startProxyServices
            
            green "进入连接监控模式..."
            while true; do
                sleep "$HEALTH_CHECK_INTERVAL"
                if ! _check_connection; then
                    red "💔 连接已断开！"
                    send_tg_notification "*💔 WARP 连接已断开，将立即重连*"
                    wg-quick down wgcf >/dev/null 2>&1 || true
                    ip link delete dev wgcf >/dev/null 2>&1 || true
                    break
                fi
                if [ -f "$RECONNECT_FLAG_FILE" ]; then
                    break
                fi
            done

        else
            red "❌ 现有IP列表均已失效，强制进行新一轮IP优选..."
            send_tg_notification "*❌ WARP 连接失败*

当前所有优选IP均已失效，将强制进行新一轮IP优选..."
            run_ip_selection
            sleep 5
        fi
    done
}

# ==============================================================================
# 脚本入口
# ==============================================================================
cd /wgcf
runwgcf "$@"