#!/bin/sh
set -e

# ==============================================================================
# 脚本配置
# ==============================================================================
BEST_IP_FILE="/wgcf/best_ips.txt"
RECONNECT_FLAG_FILE="/wgcf/reconnect.flag"
# 定时优选周期 (秒), 默认6小时
OPTIMIZE_INTERVAL="${OPTIMIZE_INTERVAL:-21600}"
# 优选IP的数量
BEST_IP_COUNT="${BEST_IP_COUNT:-30}"
# 连接成功后, 健康检查的周期 (秒), 默认60秒
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
# 健康检查的超时时间 (秒), 默认10秒
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"
# 健康检查失败后的重试次数
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-3}"
# 每次连接尝试后的稳定等待时间
STABILIZATION_WAIT="${STABILIZATION_WAIT:-3}"


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
        # 过滤掉无效行和空格,并取前 BEST_IP_COUNT 个
        awk -F, 'NR > 1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/ {print $1}' result.csv | sed 's/[[:space:]]//g' | head -n "$BEST_IP_COUNT" > "$BEST_IP_FILE"
        if [ -s "$BEST_IP_FILE" ]; then 
            green "✅ 已生成包含 $(wc -l < "$BEST_IP_FILE") 个IP的列表。"
            return 0
        fi
    fi
    red "⚠️ 未能生成有效IP列表，将使用Cloudflare官方地址作为保底。"
    echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"
    return 1
}

# 强制清理wgcf接口
_downwgcf() {
    yellow "正在清理 WireGuard 接口 (wgcf)..."
    wg-quick down wgcf >/dev/null 2>&1 || true
    # 强制删除, 避免"Device or resource busy"的问题
    ip link delete dev wgcf >/dev/null 2>&1 || true
    yellow "清理完成。"
}

# --- 核心改进: 带重试的健康检查 ---
_check_connection() {
    local check_url="https://www.cloudflare.com/cdn-cgi/trace"
    local curl_opts="--interface wgcf -s -m ${HEALTH_CHECK_TIMEOUT}"
    yellow "🩺 (检查) 正在执行网络连通性检查..."
    for i in $(seq 1 "$HEALTH_CHECK_RETRIES"); do
        # 尝试通过wgcf接口访问, 并检查是否返回 warp=on
        if curl ${curl_opts} ${check_url} 2>/dev/null | grep -q "warp=on"; then
            green "🩺 (检查) 第 $i 次尝试成功, 网络通畅。"
            return 0 # 成功
        fi
        if [ "$i" -lt "$HEALTH_CHECK_RETRIES" ]; then
            yellow "🩺 (检查) 第 $i 次尝试失败, 将在2秒后重试..."
            sleep 2
        fi
    done
    red "🩺 (检查) 所有 $HEALTH_CHECK_RETRIES 次尝试均失败, 判定连接已断开。"
    return 1 # 失败
}

_startProxyServices(){ if ! pgrep -f "gost">/dev/null;then yellow "starting GOST proxy services...";local GOST_COMMAND="gost";local SOCKS5_PORT="${PORT:-1080}";local AUTH_INFO="";[ -n "$USER" ]&&[ -n "$PASSWORD" ]&&AUTH_INFO="${USER}:${PASSWORD}@";local HOST_IP="${HOST:-0.0.0.0}";local SOCKS5_LISTEN_ADDR="socks5://${AUTH_INFO}${HOST_IP}:${SOCKS5_PORT}";GOST_COMMAND="${GOST_COMMAND} -L ${SOCKS5_LISTEN_ADDR}";green "✅ SOCKS5 代理已配置 (端口: ${SOCKS5_PORT})。";if [ -n "$HTTP_PORT" ];then local HTTP_LISTEN_ADDR="http://${AUTH_INFO}${HOST_IP}:${HTTP_PORT}";GOST_COMMAND="${GOST_COMMAND} -L ${HTTP_LISTEN_ADDR}";green "✅ HTTP 代理已配置 (端口: ${HTTP_PORT})。";fi;eval "${GOST_COMMAND} &";yellow "✅ GOST 服务已启动。";fi;}

# 连接函数
try_connect() {
    if [ ! -s "$BEST_IP_FILE" ]; then
        red "IP列表为空，无法尝试连接。"
        return 1
    fi
    
    # 遍历IP列表进行尝试
    while IFS= read -r ip_to_try; do
        if [ -z "$ip_to_try" ]; then continue; fi
        
        green "🔄 正在尝试 Endpoint: $ip_to_try"
        sed -i "s/^Endpoint = .*$/Endpoint = $ip_to_try/" /etc/wireguard/wgcf.conf
        
        # 启动WireGuard接口
        wg-quick up wgcf
        
        yellow "⏳ 等待 ${STABILIZATION_WAIT} 秒让连接稳定..."
        sleep "$STABILIZATION_WAIT"

        if _check_connection; then
            SUCCESSFUL_IP="$ip_to_try"
            return 0 # 连接成功，跳出函数
        else
            red "❌ Endpoint ${ip_to_try} 连接失败或不稳定。"
            # 执行彻底的清理
            _downwgcf
        fi
    done < "$BEST_IP_FILE"
    
    return 1 # 如果列表中的所有IP都尝试失败
}


# ==============================================================================
# 主运行函数
# ==============================================================================
runwgcf() {
    # 设置一个退出陷阱，当脚本被终止时，执行清理函数
    trap '_downwgcf; exit 0' TERM INT

    # 首次运行检查与配置初始化
    if [ ! -f "/wgcf/wgcf-account.toml" ] || [ ! -f "/wgcf/wgcf-profile.conf" ]; then
        yellow "服务首次初始化..."
        wgcf register --accept-tos && wgcf generate
        # 在配置文件中添加Keepalive以保持连接
        sed -i '/\[Peer\]/a PersistentKeepalive = 25' wgcf-profile.conf
        cp wgcf-profile.conf /wgcf/
    fi
    
    yellow "加载现有配置..."
    cp /wgcf/wgcf-profile.conf /etc/wireguard/wgcf.conf

    # 如果IP列表不存在，则立即运行一次优选
    [ ! -f "$BEST_IP_FILE" ] && run_ip_selection

    # 后台启动一个定时任务，用于定期触发IP优选
    (
        while true; do
            sleep "$OPTIMIZE_INTERVAL"
            yellow "🔄 [定时任务] 准备更新IP列表..."
            # 创建一个标志文件来通知主循环需要重新优选了
            echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$RECONNECT_FLAG_FILE"
        done
    ) &

    # 主循环
    while true; do
        RENEW_REASON="启动或重连"
        # 检查是否需要执行定时优选
        if [ -f "$RECONNECT_FLAG_FILE" ]; then
            RENEW_REASON="定时优选"
            yellow "🔔 [主循环] 收到定时优选信号，执行IP更新..."
            _downwgcf # 在优选前，先断开当前连接
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
            
            green "进入连接监控模式 (每 ${HEALTH_CHECK_INTERVAL} 秒检查一次)..."
            while true; do
                sleep "$HEALTH_CHECK_INTERVAL"
                # 如果健康检查失败，或收到了重新优选的信号，就跳出监控循环
                if ! _check_connection || [ -f "$RECONNECT_FLAG_FILE" ]; then
                    if [ -f "$RECONNECT_FLAG_FILE" ]; then
                        yellow "🔔 [监控] 收到定时优选信号，准备重新连接..."
                    else
                        red "💔 连接已断开！"
                        send_tg_notification "*💔 WARP 连接已断开，将立即重连*"
                    fi
                    _downwgcf # 彻底清理
                    break # 跳出监控循环，进入外层的主循环以重新连接
                else
                    green "💚 连接状态良好。"
                fi
            done

        else
            red "❌ 现有IP列表均已失效，强制进行新一轮IP优选..."
            send_tg_notification "*❌ WARP 连接失败*

当前所有优选IP均已失效，将强制进行新一轮IP优选..."
            run_ip_selection
            sleep 5 # 等待5秒再开始下一轮尝试
        fi
    done
}

# ==============================================================================
# 脚本入口
# ==============================================================================
cd /wgcf
runwgcf "$@"
