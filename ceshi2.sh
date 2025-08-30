#!/bin/bash
#====================================================
# warp-rule.sh - 全自动智能 WARP 域名分流脚本
# 支持: sing-box / X-UI / 3X-UI / Hiddify / fscarmen
# 功能:
#   1. 自动安装 warp-go
#   2. 自动生成 WireGuard 配置
#   3. 用户输入域名 -> WARP
#   4. 其他流量走 VPS 本地 IP
#   5. 智能三通道分流 + 节点健康检查 + 自动切换
#   6. 自动检测所有节点配置文件并合并规则
#====================================================

set -e

log() { echo -e "[`date '+%F %T'`] $*"; }

#-----------------------------
# 系统依赖安装
#-----------------------------
install_deps() {
    log "检测系统依赖..."
    for pkg in jq curl ping; do
        if ! command -v $pkg >/dev/null 2>&1; then
            log "安装 $pkg..."
            apt-get update && apt-get install -y $pkg
        fi
    done
}

#-----------------------------
# 面板检测和节点路径扫描
#-----------------------------
detect_panel_and_nodes() {
    log "检测面板和节点配置..."
    PANEL=""
    NODE_FILES=()

    if [ -f /etc/sing-box/config.json ]; then
        PANEL="sing-box"
        CONFIG_FILE="/etc/sing-box/config.json"
        NODE_FILES=(/etc/sing-box/nodes/*.json)
    elif [ -f /usr/local/x-ui/bin/config.json ]; then
        PANEL="x-ui"
        CONFIG_FILE="/usr/local/x-ui/bin/config.json"
        NODE_FILES=(/usr/local/x-ui/bin/nodes/*.json)
    elif [ -f /usr/local/etc/3x-ui/xray/config.json ]; then
        PANEL="3x-ui"
        CONFIG_FILE="/usr/local/etc/3x-ui/xray/config.json"
        NODE_FILES=(/usr/local/etc/3x-ui/xray/nodes/*.json)
    elif [ -f /etc/hiddify/xray/config.json ]; then
        PANEL="hiddify"
        CONFIG_FILE="/etc/hiddify/xray/config.json"
        NODE_FILES=(/etc/hiddify/xray/nodes/*.json)
    elif [ -f /etc/fscarmen/sing-box/config.json ]; then
        PANEL="fscarmen"
        CONFIG_FILE="/etc/fscarmen/sing-box/config.json"
        NODE_FILES=(/etc/fscarmen/sing-box/nodes/*.json)
    else
        log "未找到支持的面板配置文件，请手动检查"; exit 1
    fi

    log "检测到面板: $PANEL"
    log "主配置文件路径: $CONFIG_FILE"
    log "检测到节点配置文件: ${NODE_FILES[@]}"
}

#-----------------------------
# warp-go 安装
#-----------------------------
install_warp() {
    log "检测 warp-go..."
    if ! command -v warp-go >/dev/null 2>&1; then
        log "安装 warp-go..."
        curl -fsSL https://gitlab.com/ProjectWARP/warp-go/-/raw/main/warp-go-linux-amd64 -o /usr/local/bin/warp-go
        chmod +x /usr/local/bin/warp-go
    fi
}

#-----------------------------
# warp 注册并生成配置
#-----------------------------
register_warp() {
    log "注册 warp 并生成 WireGuard 配置..."
    WARP_DIR="/etc/warp-go"
    mkdir -p $WARP_DIR
    WARP_CONF="$WARP_DIR/warp.conf"
    warp-go --register > $WARP_CONF 2>&1

    PRIVATE_KEY=$(grep PrivateKey $WARP_CONF | awk '{print $3}' || echo "")
    PUBLIC_KEY=$(grep PublicKey $WARP_CONF | awk '{print $3}' || echo "")
    ENDPOINT=$(grep Endpoint $WARP_CONF | awk '{print $3}' || echo "162.159.193.10:2408")

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        log "获取 warp 密钥失败，请检查 warp-go"; exit 1
    fi
    log "warp 私钥、公钥、endpoint 已获取"
}

#-----------------------------
# 用户输入域名
#-----------------------------
read_domains() {
    echo
    read -rp "请输入需要走 WARP 的域名 (空格分隔): " DOMAIN_INPUT
    if [ -z "$DOMAIN_INPUT" ]; then log "未输入域名，退出"; exit 1; fi
    IFS=' ' read -r -a DOMAIN_LIST <<< "$DOMAIN_INPUT"
}

#-----------------------------
# 配置文件修改
#-----------------------------
modify_config_file() {
    local FILE=$1
    log "备份原配置文件: $FILE"
    cp $FILE ${FILE}.bak.$(date +%s)

    CONFIG_JSON=$(cat $FILE)

    # 添加 warp 出站
    if ! echo "$CONFIG_JSON" | jq '.outbounds[] | select(.tag=="warp")' >/dev/null 2>&1; then
        CONFIG_JSON=$(echo "$CONFIG_JSON" | jq \
            --arg pk "$PRIVATE_KEY" \
            --arg pub "$PUBLIC_KEY" \
            --arg ep "$ENDPOINT" \
            '.outbounds += [{
                "type":"wireguard",
                "tag":"warp",
                "server":($ep | split(":")[0]),
                "server_port":($ep | split(":")[1]|tonumber),
                "local_address":["172.16.0.2/32"],
                "private_key":$pk,
                "peer_public_key":$pub
            }]'
        )
    fi

    # 添加/更新分流规则
    DOMAIN_JSON=$(printf '"%s",' "${DOMAIN_LIST[@]}")
    DOMAIN_JSON="[${DOMAIN_JSON%,}]"

    if ! echo "$CONFIG_JSON" | jq '.route.rules[] | select(.outbound=="warp")' >/dev/null 2>&1; then
        CONFIG_JSON=$(echo "$CONFIG_JSON" | jq \
            --argjson domains "$DOMAIN_JSON" \
            '.route.rules += [{
                "domain": $domains,
                "outbound": "warp"
            }]'
        )
    else
        CONFIG_JSON=$(echo "$CONFIG_JSON" | jq \
            --argjson domains "$DOMAIN_JSON" \
            '(.route.rules[] | select(.outbound=="warp")).domain = $domains'
        )
    fi

    # 默认 outbound
    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq '.route.default = "direct"')

    echo "$CONFIG_JSON" > $FILE
    log "修改完成: $FILE"
}

#-----------------------------
# 节点健康检查 + WARP 自动切换
#-----------------------------
health_check_warp() {
    log "开始 WARP 节点健康检查..."
    if ! ping -c 2 162.159.193.10 >/dev/null 2>&1; then
        log "WARP 节点不可用，重新注册..."
        register_warp
        for f in "${NODE_FILES[@]}"; do
            modify_config_file "$f"
        done
        modify_config_file "$CONFIG_FILE"
        restart_service
        log "WARP 自动切换完成"
    else
        log "WARP 节点正常"
    fi
}

#-----------------------------
# 重启服务
#-----------------------------
restart_service() {
    log "重启面板服务..."
    if [[ "$PANEL" =~ ^(sing-box|fscarmen)$ ]]; then
        systemctl restart sing-box
        sleep 2
        systemctl status sing-box --no-pager -l | tail -n 10
    else
        systemctl restart xray
        sleep 2
        systemctl status xray --no-pager -l | tail -n 10
    fi
    log "服务重启完成"
}

#-----------------------------
# 主流程
#-----------------------------
main() {
    log "脚本启动"
    install_deps
    detect_panel_and_nodes
    install_warp
    register_warp
    read_domains

    # 修改主配置文件
    modify_config_file "$CONFIG_FILE"
    # 修改节点配置文件
    for f in "${NODE_FILES[@]}"; do
        if [ -f "$f" ]; then
            modify_config_file "$f"
        fi
    done

    restart_service
    health_check_warp

    log "所有 WARP 分流配置完成！指定域名走 WARP，其他流量走 VPS 本地 IP"
}

main "$@"
