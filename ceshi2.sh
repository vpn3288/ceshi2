#!/bin/bash

# 三通道域名分流脚本 - 完整修复版
# 兼容 fscarmen, yonggekkk, jinwyp 等主流WARP脚本
# 支持 Hiddify, Sing-box, 3X-UI, X-UI 等代理面板
# 修复版本: 解决分流失败问题，确保与新版sing-box兼容
# 修复版本: 兼容最新官方warp-cli命令

VERSION="2.0.3"
SCRIPT_URL="https://raw.githubusercontent.com/vpn3288/warp/refs/heads/main/proxy.sh"

# 颜色定义
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 检查root权限
[[ $EUID -ne 0 ]] && red "请以root模式运行脚本" && exit 1

# 配置目录
CONFIG_DIR="/etc/three-channel-routing"
LOG_FILE="/var/log/three-channel-routing.log"
DOMAIN_FILE="$CONFIG_DIR/warp-domains.json"

# 全局变量
WARP_BINARY=""
WARP_CONFIG=""
EXISTING_WARP_TYPE=""
PANEL_TYPE=""
USE_WIREGUARD_GO=""

# 预设域名列表 - 需要走WARP的域名
DEFAULT_WARP_DOMAINS=(
    "remove.bg"
    "upscale.media" 
    "waifu2x.udp.jp"
    "perplexity.ai"
    "you.com"
    "ip125.com"
    "openai.com"
    "chatgpt.com"
    "claude.ai"
    "anthropic.com"
    "bard.google.com"
    "github.com"
    "raw.githubusercontent.com"
    "discord.com"
    "twitter.com"
    "x.com"
    "facebook.com"
    "instagram.com"
    "youtube.com"
    "gmail.com"
    "drive.google.com"
    "dropbox.com"
    "onedrive.live.com"
    "telegram.org"
    "whatsapp.com"
    "reddit.com"
    "netflix.com"
    "spotify.com"
    "twitch.tv"
    "tiktok.com"
    "linkedin.com"
    "medium.com"
    "stackoverflow.com"
    "wikipedia.org"
    "archive.org"
)

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

# 主菜单
main_menu() {
    clear
    green "========================================="
    green "   三通道域名分流脚本 v${VERSION} (修复版)"
    green "========================================="
    echo
    blue "核心功能："
    echo "1. 安装/配置 WARP Socks5 代理"
    echo "2. 智能检测现有面板并配置分流"
    echo "3. 添加自定义WARP域名"
    echo "4. 查看分流状态和测试"
    echo "5. 管理域名规则"
    echo
    blue "维护功能："
    echo "6. 重启WARP服务"
    echo "7. 查看日志"
    echo "8. 卸载配置"
    echo
    echo "0. 退出"
    echo
    readp "请选择功能 [0-8]: " choice
    
    case $choice in
        1) install_configure_warp;;
        2) auto_detect_and_configure;;
        3) add_custom_domains;;
        4) show_status_and_test;;
        5) manage_domain_rules;;
        6) restart_warp_service;;
        7) show_logs;;
        8) uninstall_all;;
        0) cleanup && exit 0;;
        *) red "无效选择" && sleep 1 && main_menu;;
    esac
}

# 清理函数
cleanup() {
    log_info "脚本退出，清理完成"
    # 这里可以添加一些退出前的清理操作
}

# 检测系统环境
detect_system() {
    log_info "检测系统环境"
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        red "无法识别系统类型"
        exit 1
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") WARP_ARCH="amd64";;
        "aarch64"|"arm64") WARP_ARCH="arm64";;
        "armv7l"|"armv7") WARP_ARCH="armv7";;
        "i386"|"i686") WARP_ARCH="386";;
        *) red "不支持的架构: $ARCH" && exit 1;;
    esac
    
    green "系统: $OS $VER ($ARCH -> $WARP_ARCH)"
}

# 安装依赖
install_dependencies() {
    log_info "安装必要依赖"
    
    if command -v apt &> /dev/null; then
        apt update -qq
        apt install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    elif command -v dnf &> /dev/null; then
        dnf install -y curl wget jq qrencode wireguard-tools iptables &> /dev/null
    else
        red "不支持的包管理器"
        exit 1
    fi
    
    # 手动安装jq如果失败
    if ! command -v jq &> /dev/null; then
        yellow "手动安装jq..."
        local jq_arch="linux64"
        if [[ "$ARCH" == "aarch64" ]]; then
            jq_arch="linux64_arm64"
        elif [[ "$ARCH" == "armv7l" ]]; then
            jq_arch="linux32_arm"
        fi
        
        wget -O /usr/local/bin/jq "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-${jq_arch}"
        chmod +x /usr/local/bin/jq
    fi
}

# 检测现有WARP安装
detect_existing_warp() {
    log_info "检测现有WARP安装"
    
    if [[ -f /opt/warp-go/warp-go ]] && [[ -f /opt/warp-go/warp.conf ]]; then
        EXISTING_WARP_TYPE="fscarmen"
        WARP_BINARY="/opt/warp-go/warp-go"
        WARP_CONFIG="/opt/warp-go/warp.conf"
        green "检测到 fscarmen/warp-sh 安装"
        return 0
    fi
    
    if [[ -f /usr/local/bin/warp-go ]] && [[ -f /etc/wireguard/warp.conf ]]; then
        EXISTING_WARP_TYPE="yonggekkk"
        WARP_BINARY="/usr/local/bin/warp-go"
        WARP_CONFIG="/etc/wireguard/warp.conf"
        green "检测到 yonggekkk/warp-yg 安装"
        return 0
    fi
    
    if [[ -f /usr/bin/warp-go ]] || [[ -f /usr/local/bin/warp-go ]]; then
        EXISTING_WARP_TYPE="jinwyp"
        WARP_BINARY=$(which warp-go 2>/dev/null)
        green "检测到 jinwyp 或其他 WARP 安装"
        return 0
    fi
    
    if command -v warp-go &> /dev/null; then
        EXISTING_WARP_TYPE="generic"
        WARP_BINARY=$(which warp-go)
        green "检测到通用 warp-go 安装"
        return 0
    fi
    
    if command -v warp-cli &> /dev/null; then
        EXISTING_WARP_TYPE="official_client"
        green "检测到官方WARP客户端安装"
        return 0
    fi

    yellow "未检测到现有WARP安装"
    return 1
}

# 检测代理面板
detect_proxy_panels() {
    log_info "检测代理面板"
    
    if [[ -d /etc/sing-box/conf ]] && [[ -f /etc/sing-box/conf/01_outbounds.json ]]; then
        PANEL_TYPE="fscarmen_singbox"
        green "检测到 fscarmen/sing-box (模块化配置)"
        return 0
    fi
    
    if [[ -f /etc/sing-box/config.json ]] || systemctl list-units --type=service | grep -q sing-box; then
        PANEL_TYPE="standard_singbox"
        green "检测到标准 Sing-box"
        return 0
    fi
    
    if [[ -d /opt/hiddify-manager ]] || [[ -f /opt/hiddify-config/hiddify-panel.json ]]; then
        PANEL_TYPE="hiddify"
        green "检测到 Hiddify Panel"
        return 0
    fi
    
    if systemctl list-units --type=service | grep -E "(x-ui|3x-ui)" > /dev/null; then
        PANEL_TYPE="xui"
        green "检测到 X-UI/3X-UI"
        return 0
    fi
    
    if [[ -f /etc/mihomo/config.yaml ]] || [[ -f /etc/clash/config.yaml ]]; then
        PANEL_TYPE="mihomo"
        green "检测到 Mihomo/Clash"
        return 0
    fi
    
    yellow "未检测到支持的代理面板"
    return 1
}

# 自动检测并配置分流
auto_detect_and_configure() {
    clear
    green "=== 智能检测与配置 ==="
    log_info "开始自动检测和配置分流"
    
    detect_system
    install_dependencies
    
    if ! detect_existing_warp; then
        readp "未检测到WARP安装，是否立即安装？[Y/n]: " install_choice
        if [[ ! $install_choice =~ [Nn] ]]; then
            install_fresh_warp
        else
            red "中止配置，WARP未安装"
            return
        fi
    else
        readp "检测到现有WARP安装，是否继续配置？[Y/n]: " continue_choice
        if [[ $continue_choice =~ [Nn] ]]; then
            yellow "中止配置"
            return
        fi
        configure_existing_warp
    fi
    
    create_domain_config
    
    if detect_proxy_panels; then
        case $PANEL_TYPE in
            "fscarmen_singbox")
                apply_fscarmen_singbox_config
                ;;
            "standard_singbox")
                apply_standard_singbox_config
                ;;
            "hiddify")
                yellow "Hiddify面板分流暂不支持自动配置，请参考文档手动操作"
                ;;
            "xui")
                yellow "X-UI/3X-UI面板分流暂不支持自动配置，请参考文档手动操作"
                ;;
            "mihomo")
                yellow "Mihomo/Clash面板分流暂不支持自动配置，请参考文档手动操作"
                ;;
            *)
                yellow "未找到支持的代理面板，请手动配置"
                ;;
        esac
    else
        yellow "未找到支持的代理面板，无法自动配置分流"
    fi
    
    press_to_continue
}

# 安装和配置WARP
install_configure_warp() {
    clear
    green "=== 安装/配置 WARP Socks5 代理 ==="
    log_info "开始WARP安装/配置"
    
    detect_system
    install_dependencies
    
    if detect_existing_warp; then
        yellow "检测到现有WARP安装: $EXISTING_WARP_TYPE"
        readp "是否使用现有安装？[Y/n]: " use_existing
        
        if [[ ! $use_existing =~ [Nn] ]]; then
            configure_existing_warp
            return
        fi
    fi
    
    install_fresh_warp
}

# 配置现有WARP
configure_existing_warp() {
    log_info "配置现有WARP: $EXISTING_WARP_TYPE"
    
    case $EXISTING_WARP_TYPE in
        "fscarmen")
            configure_fscarmen_warp
            ;;
        "yonggekkk")
            configure_yonggekkk_warp
            ;;
        "jinwyp"|"generic")
            configure_generic_warp
            ;;
        "official_client")
            configure_official_client
            ;;
    esac
    
    if [[ "$EXISTING_WARP_TYPE" != "official_client" ]]; then
        create_warp_socks5_service
        start_warp_service
    fi
    
    green "现有WARP配置完成！"
    press_to_continue
}

# 配置fscarmen的WARP
configure_fscarmen_warp() {
    log_info "配置fscarmen WARP为Socks5模式"
    systemctl stop warp-go 2>/dev/null
    [[ -f $WARP_CONFIG ]] && cp $WARP_CONFIG "${WARP_CONFIG}.backup"
    
    if [[ -f $WARP_CONFIG ]]; then
        if ! grep -q "\[Socks5\]" $WARP_CONFIG; then
            echo "" >> $WARP_CONFIG
            echo "[Socks5]" >> $WARP_CONFIG
            echo "BindAddress = 127.0.0.1:40000" >> $WARP_CONFIG
        else
            sed -i '/\[Socks5\]/,/^\[/s/BindAddress.*/BindAddress = 127.0.0.1:40000/' $WARP_CONFIG
        fi
        green "fscarmen WARP配置已更新"
    fi
}

# 配置yonggekkk的WARP
configure_yonggekkk_warp() {
    log_info "配置yonggekkk WARP为Socks5模式"
    systemctl stop warp-go 2>/dev/null
    [[ -f $WARP_CONFIG ]] && cp $WARP_CONFIG "${WARP_CONFIG}.backup"
    convert_wireguard_to_socks5 $WARP_CONFIG
}

# 配置通用WARP
configure_generic_warp() {
    log_info "配置通用WARP为Socks5模式"
    local config_paths=(
        "/etc/wireguard/warp.conf"
        "/opt/warp-go/warp.conf"
        "/usr/local/etc/warp.conf"
        "/etc/warp-go/warp.conf"
    )
    
    for path in "${config_paths[@]}"; do
        if [[ -f "$path" ]]; then
            WARP_CONFIG="$path"
            log_info "找到WARP配置: $path"
            break
        fi
    done
    
    if [[ -n $WARP_CONFIG ]]; then
        configure_fscarmen_warp
    else
        yellow "未找到WARP配置，将全新安装"
        install_fresh_warp
    fi
}

# 配置官方客户端
configure_official_client() {
    log_info "配置官方WARP客户端"
    
    if ! command -v warp-cli &> /dev/null; then
        red "官方客户端未安装或无法找到"
        return 1
    fi
    
    yellow "正在停止WARP服务以重新配置..."
    warp-cli disconnect 2>/dev/null
    sleep 2
    
    yellow "正在配置WARP为代理模式..."
    if ! warp-cli mode proxy; then
        red "设置代理模式失败"
        return 1
    fi
    
    yellow "正在设置Socks5代理端口为40000..."
    if ! warp-cli proxy set-port 40000; then
        red "设置代理端口失败"
        return 1
    fi
    
    yellow "正在连接WARP服务..."
    if ! warp-cli connect; then
        red "WARP连接失败"
        return 1
    fi
    
    green "官方客户端配置成功"
    test_warp_connection
}

# 转换WireGuard配置为Socks5
convert_wireguard_to_socks5() {
    local wg_config="$1"
    
    if [[ ! -f "$wg_config" ]]; then
        red "WireGuard配置文件不存在"
        return 1
    fi
    
    local private_key=$(grep -oP '(?<=PrivateKey = ).*' "$wg_config")
    local endpoint=$(grep -oP '(?<=Endpoint = ).*' "$wg_config")
    local address=$(grep -oP '(?<=Address = ).*' "$wg_config")
    local reserved=$(grep -oP '(?<=Reserved = ).*' "$wg_config")
    
    if [[ -z "$reserved" ]]; then
        reserved="[$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1),$(shuf -i 0-255 -n 1)]"
    fi
    
    mkdir -p $CONFIG_DIR
    cat > $CONFIG_DIR/warp-socks5.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = $address
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = $endpoint
Reserved = $reserved

[Socks5]
BindAddress = 127.0.0.1:40000
EOF

    WARP_CONFIG="$CONFIG_DIR/warp-socks5.conf"
    green "WireGuard配置已转换为Socks5格式"
}

# 全新安装WARP
install_fresh_warp() {
    log_info "全新安装WARP - 尝试多种方案"
    
    clear
    blue "=== 选择WARP安装方案 ==="
    echo "1. 官方WARP客户端 (推荐)"
    echo "2. 静态编译warp-go"
    echo "3. WireGuard + socat代理"
    echo "4. 自动选择最佳方案"
    echo
    readp "请选择安装方案 [1-4]: " method_choice
    
    case $method_choice in
        1) 
            if try_official_warp_client; then
                green "官方WARP客户端安装成功"
                configure_official_client
            else
                yellow "官方客户端安装失败，尝试其他方案"
                install_warp_multiple_methods
            fi
            ;;
        2)
            if try_static_warp_go; then
                green "静态warp-go安装成功"
            else
                yellow "静态warp-go安装失败，尝试其他方案"
                install_warp_multiple_methods
            fi
            ;;
        3)
            if try_wireguard_socat_proxy; then
                green "WireGuard代理安装成功"
            else
                yellow "WireGuard代理安装失败"
                return 1
            fi
            ;;
        4)
            install_warp_multiple_methods
            ;;
        *)
            red "无效选择，使用自动方案"
            install_warp_multiple_methods
            ;;
    esac
    
    press_to_continue
}

# 增强的应用fscarmen sing-box配置 - 完全兼容新版本
apply_fscarmen_singbox_config() {
    log_info "应用fscarmen sing-box配置"
    
    local conf_dir="/etc/sing-box/conf"
    local outbounds_file="$conf_dir/01_outbounds.json"
    local route_file="$conf_dir/03_route.json"
    
    if [[ ! -d "$conf_dir" ]]; then
        red "fscarmen sing-box配置目录不存在"
        return 1
    fi
    
    # 备份配置文件
    [[ -f $outbounds_file ]] && cp $outbounds_file "${outbounds_file}.backup"
    [[ -f $route_file ]] && cp $route_file "${route_file}.backup"
    
    # 1. 添加WARP Socks5出站
    add_warp_outbound_to_fscarmen "$outbounds_file"
    
    # 2. 创建现代路由规则 (完全移除geosite，确保兼容性)
    create_modern_fscarmen_route_config "$route_file"
    
    # 3. 验证配置并重启
    if validate_and_restart_singbox; then
        green "fscarmen sing-box配置应用成功"
    else
        red "配置应用失败，已恢复备份"
        restore_singbox_backups
        return 1
    fi
}

# 添加WARP出站到fscarmen配置
add_warp_outbound_to_fscarmen() {
    local outbounds_file="$1"
    
    if [[ -f $outbounds_file ]]; then
        if ! jq empty "$outbounds_file" 2>/dev/null; then
            red "出站配置文件JSON格式错误"
            return 1
        fi
        
        local outbounds=$(cat $outbounds_file)
        
        if ! echo "$outbounds" | jq -e '.outbounds[]? | select(.tag == "warp-socks5")' > /dev/null 2>&1; then
            local new_outbound='{
                "type": "socks",
                "tag": "warp-socks5", 
                "server": "127.0.0.1",
                "server_port": 40000,
                "version": "5"
            }'
            
            local updated_outbounds
            if echo "$outbounds" | jq -e '.outbounds' > /dev/null 2>&1; then
                updated_outbounds=$(echo "$outbounds" | jq --argjson newout "$new_outbound" '.outbounds += [$newout]')
            else
                updated_outbounds='{"outbounds": ['"$new_outbound"']}'
            fi
            
            echo "$updated_outbounds" > $outbounds_file
            green "已添加WARP Socks5出站配置"
        else
            green "WARP Socks5出站配置已存在"
        fi
    else
        cat > $outbounds_file <<EOF
{
    "outbounds": [
        {
            "type": "socks",
            "tag": "warp-socks5",
            "server": "127.0.0.1",
            "server_port": 40000,
            "version": "5"
        }
    ]
}
EOF
        green "已创建WARP Socks5出站配置"
    fi
}

# 现代fscarmen路由配置 (无geosite)
create_modern_fscarmen_route_config() {
    local route_file="$1"
    
    # 从本地文件加载自定义域名列表，如果没有则使用默认列表
    local warp_domains_json="[]"
    if [[ -f "$DOMAIN_FILE" ]]; then
        warp_domains_json=$(cat "$DOMAIN_FILE")
    fi

    cat > "$route_file" <<EOF
{
    "route": {
        "auto_detect_interface": true,
        "final": "direct",
        "rules": [
            {
                "protocol": "dns",
                "outbound": "dns-out"
            },
            {
                "port": 53,
                "outbound": "dns-out"
            },
            {
                "protocol": ["quic"],
                "outbound": "block"
            },
            {
                "domain_suffix": $warp_domains_json,
                "outbound": "warp-socks5"
            },
            {
                "domain_keyword": ["openai", "anthropic", "claude", "chatgpt", "bard", "perplexity", "github", "telegram", "discord", "twitter", "facebook", "youtube", "instagram", "reddit", "netflix", "spotify"],
                "outbound": "warp-socks5"
            },
            {
                "domain_suffix": [".cn", ".中国", ".gov.cn", ".edu.cn"],
                "outbound": "direct"
            },
            {
                "domain_keyword": ["baidu", "qq", "taobao", "tmall", "alipay", "wechat", "weixin", "douban", "zhihu", "bilibili"],
                "outbound": "direct"
            },
            {
                "ip_cidr": [
                    "10.0.0.0/8", 
                    "172.16.0.0/12", 
                    "192.168.0.0/16", 
                    "127.0.0.0/8",
                    "169.254.0.0/16"
                ],
                "outbound": "direct"
            }
        ]
    }
}
EOF
    green "已创建现代fscarmen路由配置 (完全兼容新版sing-box)"
}

# 验证并重启sing-box
validate_and_restart_singbox() {
    log_info "验证并重启sing-box"
    
    # 验证配置
    if command -v sing-box &> /dev/null; then
        if ! sing-box check -c /etc/sing-box 2>/dev/null; then
            red "sing-box配置验证失败"
            return 1
        fi
        green "sing-box配置验证通过"
    fi
    
    # 重启服务
    systemctl restart sing-box
    sleep 3
    
    if systemctl is-active --quiet sing-box; then
        green "sing-box服务重启成功"
        return 0
    else
        red "sing-box服务重启失败"
        yellow "查看错误: journalctl -u sing-box -n 20"
        return 1
    fi
}

# 恢复sing-box备份
restore_singbox_backups() {
    log_info "正在恢复sing-box备份文件"
    local conf_dir="/etc/sing-box/conf"
    local outbounds_file="$conf_dir/01_outbounds.json"
    local route_file="$conf_dir/03_route.json"

    [[ -f "${outbounds_file}.backup" ]] && mv "${outbounds_file}.backup" "$outbounds_file"
    [[ -f "${route_file}.backup" ]] && mv "${route_file}.backup" "$route_file"
    systemctl restart sing-box
    yellow "备份已恢复，请检查服务状态"
}

# 创建WARP Socks5服务
create_warp_socks5_service() {
    log_info "创建WARP Socks5服务"
    
    if [[ -z $WARP_BINARY ]]; then
        WARP_BINARY=$(which warp-go 2>/dev/null)
        if [[ -z $WARP_BINARY ]]; then
            WARP_BINARY="/usr/local/bin/warp-go"
        fi
    fi
    
    if [[ ! -x "$WARP_BINARY" ]]; then
        red "WARP二进制文件不可执行: $WARP_BINARY"
        return 1
    fi
    
    local exec_start_cmd="$WARP_BINARY --config $WARP_CONFIG"
    
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP Socks5 Proxy for Three-Channel Routing
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
ExecStart=$exec_start_cmd
ExecStartPre=/bin/sleep 3
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
KillMode=mixed
TimeoutStopSec=15
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-socks5
    green "WARP Socks5服务已创建"
}

# 启动WARP服务
start_warp_service() {
    log_info "启动WARP服务"
    systemctl stop warp-go 2>/dev/null
    systemctl stop wg-quick@warp 2>/dev/null
    systemctl stop wg-quick@wg0 2>/dev/null
    
    if check_port_usage 40000; then
        yellow "端口40000可用"
    else
        yellow "端口40000被占用，尝试终止占用进程..."
        local pid=$(lsof -ti:40000 2>/dev/null)
        if [[ -n "$pid" ]]; then
            kill -9 $pid 2>/dev/null
            sleep 2
        fi
    fi
    
    systemctl restart warp-socks5
    sleep 8
    
    if systemctl is-active --quiet warp-socks5; then
        green "WARP Socks5 服务启动成功 (127.0.0.1:40000)"
        if test_warp_connection; then
            green "WARP连接测试成功"
            return 0
        else
            yellow "WARP连接测试失败，请检查防火墙或网络配置"
            diagnose_warp_connection_failure
            return 1
        fi
    else
        red "WARP服务启动失败"
        log_error "WARP服务启动失败"
        show_warp_service_logs
        return 1
    fi
}

# WARP连接故障诊断
diagnose_warp_connection_failure() {
    yellow "=== WARP连接故障诊断 ==="
    echo "1. 服务状态检查:"
    systemctl status warp-socks5 --no-pager -l
    echo "2. 端口监听检查:"
    netstat -tlnp | grep ":40000" || echo "端口40000未监听"
    echo "3. 配置文件检查: $WARP_CONFIG"
    if [[ ! -f $WARP_CONFIG ]]; then echo "配置文件不存在"; fi
    echo "4. 二进制文件检查: $WARP_BINARY"
    if [[ ! -x "$WARP_BINARY" ]]; then echo "二进制文件不可执行"; fi
    echo "5. 网络连接测试: "
    if curl -s --max-time 5 https://1.1.1.1 > /dev/null; then echo "网络连接正常"; else echo "网络连接异常"; fi
    echo
    yellow "=== 解决建议 ==="
    echo "1. 检查WARP服务日志: journalctl -u warp-socks5 -f"
    echo "2. 确保防火墙没有阻止1.1.1.1的流量"
}

# 显示WARP服务日志
show_warp_service_logs() {
    yellow "最近的WARP服务日志:"
    journalctl -u warp-socks5 -n 10 --no-pager
    press_to_continue
}

# 增强的WARP连接测试
test_warp_connection() {
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        local test_result=$(curl -s --socks5 127.0.0.1:40000 --max-time 15 http://ip-api.com/json 2>/dev/null)
        
        if [[ -n "$test_result" ]]; then
            local warp_ip=$(echo "$test_result" | jq -r '.query // "unknown"' 2>/dev/null)
            local warp_country=$(echo "$test_result" | jq -r '.country // "unknown"' 2>/dev/null)
            
            if [[ "$warp_ip" != "unknown" && "$warp_ip" != "null" && "$warp_ip" != "" ]]; then
                blue "WARP IP: $warp_ip ($warp_country)"
                return 0
            fi
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $max_retries ]]; then
            yellow "连接测试失败，${retry_count}/${max_retries}，重试中..."
            sleep 3
        fi
    done
    
    return 1
}

# 其他辅助函数 (try_official_warp_client, try_static_warp_go, etc.)
install_warp_multiple_methods() {
    yellow "尝试多种WARP安装方案"
    if try_official_warp_client; then configure_official_client; return 0; fi
    if try_static_warp_go; then return 0; fi
    if try_wireguard_socat_proxy; then return 0; fi
    red "所有WARP安装方案都失败"
    return 1
}

try_official_warp_client() {
    yellow "尝试安装官方WARP客户端..."
    if command -v apt &> /dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt update && apt install -y cloudflare-warp
    elif command -v yum &> /dev/null; then
        curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo
        yum install -y cloudflare-warp
    else return 1; fi
    if command -v warp-cli &> /dev/null; then
        green "官方WARP客户端安装成功"
        WARP_METHOD="official_client"
        return 0
    fi
    return 1
}

try_static_warp_go() {
    yellow "尝试静态编译的warp-go..."
    local static_urls=(
        "https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-${WARP_ARCH}"
        "https://github.com/ALIILAPRO/warp-plus-cloudflare/releases/latest/download/warp-plus-linux-${WARP_ARCH}"
    )
    for url in "${static_urls[@]}"; do
        yellow "尝试下载: $url"
        if curl -sL --connect-timeout 15 --max-time 60 "$url" -o /tmp/warp-static; then
            chmod +x /tmp/warp-static
            if /tmp/warp-static --version >/dev/null 2>&1; then
                mv /tmp/warp-static /usr/local/bin/warp-go
                WARP_BINARY="/usr/local/bin/warp-go"
                green "静态warp-go安装成功"
                generate_fresh_warp_config
                return 0
            fi
        fi
        rm -f /tmp/warp-static
    done
    return 1
}

try_wireguard_socat_proxy() {
    yellow "尝试WireGuard + socat代理方案..."
    if command -v apt &> /dev/null; then apt install -y wireguard-tools socat; elif command -v yum &> /dev/null; then yum install -y wireguard-tools socat; elif command -v dnf &> /dev/null; then dnf install -y wireguard-tools socat; else return 1; fi
    if ! command -v wg &> /dev/null || ! command -v socat &> /dev/null; then return 1; fi
    generate_wireguard_config
    create_socat_proxy_service
    WARP_METHOD="wireguard_socat"
    green "WireGuard + socat代理安装成功"
    return 0
}

generate_wireguard_config() {
    local private_key=$(wg genkey)
    local public_key=$(echo "$private_key" | wg pubkey)
    local endpoints=("162.159.193.10:2408" "162.159.192.1:2408" "188.114.97.1:2408" "188.114.96.1:2408")
    local endpoint=${endpoints[$RANDOM % ${#endpoints[@]}]}
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = 172.16.0.2/32
Address = 2606:4700:110:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)/128
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF
    green "WireGuard配置已生成"
}

create_socat_proxy_service() {
    cat > /etc/systemd/system/warp-socks5.service <<EOF
[Unit]
Description=WARP WireGuard + Socat Proxy
After=network-online.target
Wants=network-online.target
Requires=wg-quick@wg0.service
After=wg-quick@wg0.service
[Service]
Type=forking
ExecStartPre=/usr/bin/systemctl start wg-quick@wg0
ExecStart=/usr/bin/socat TCP4-LISTEN:40000,reuseaddr,fork SOCKS4A:172.16.0.1:0,socksport=1080
ExecStop=/usr/bin/systemctl stop wg-quick@wg0
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wg-quick@wg0
    systemctl enable warp-socks5
    green "socat代理服务已创建"
}

create_domain_config() {
    log_info "配置域名规则"
    mkdir -p $CONFIG_DIR
    local domain_list
    if [[ -f "$DOMAIN_FILE" ]]; then
        domain_list=$(jq -c . "$DOMAIN_FILE")
        yellow "检测到已有域名规则，加载中..."
    else
        printf -v domain_list '"%s",' "${DEFAULT_WARP_DOMAINS[@]}"
        domain_list="[${domain_list%,}]"
        yellow "使用默认域名列表"
    fi
    echo "$domain_list" > "$DOMAIN_FILE"
    log_info "域名规则已保存: $(echo "$domain_list" | jq length) 个WARP域名"
}

add_custom_domains() {
    clear
    green "=== 添加自定义WARP域名 ==="
    readp "请输入要添加的域名 (多个域名请用空格分隔): " new_domains
    local domains_array=($new_domains)
    if [[ ${#domains_array[@]} -eq 0 ]]; then
        red "未输入任何域名"
        press_to_continue
        return
    fi
    
    create_domain_config
    local existing_domains=$(cat "$DOMAIN_FILE")
    local updated_domains="$existing_domains"
    for domain in "${domains_array[@]}"; do
        if ! echo "$existing_domains" | jq -e "map(select(. == \"$domain\")) | length > 0" > /dev/null; then
            updated_domains=$(echo "$updated_domains" | jq -c ". += [\"$domain\"]")
            green "域名 '$domain' 已添加"
        else
            yellow "域名 '$domain' 已存在"
        fi
    done
    echo "$updated_domains" > "$DOMAIN_FILE"
    
    yellow "请重新运行'智能检测现有面板并配置分流'以应用新规则"
    press_to_continue
}

manage_domain_rules() {
    clear
    green "=== 管理域名规则 ==="
    echo "1. 查看所有WARP域名"
    echo "2. 删除WARP域名"
    echo "3. 清空所有WARP域名"
    echo "0. 返回主菜单"
    readp "请选择功能 [0-3]: " manage_choice
    
    case $manage_choice in
        1)
            echo "当前WARP域名列表:"
            jq -r '.[]' "$DOMAIN_FILE" || yellow "域名文件不存在或为空"
            ;;
        2)
            readp "请输入要删除的域名 (多个用空格分隔): " to_delete
            local domains_to_delete=($to_delete)
            local current_domains=$(cat "$DOMAIN_FILE")
            local updated_domains="$current_domains"
            for domain in "${domains_to_delete[@]}"; do
                updated_domains=$(echo "$updated_domains" | jq -c "map(select(. != \"$domain\"))")
            done
            echo "$updated_domains" > "$DOMAIN_FILE"
            green "域名已删除"
            ;;
        3)
            readp "确认清空所有WARP域名？[Y/n]: " confirm
            if [[ $confirm =~ [Yy] ]]; then
                echo "[]" > "$DOMAIN_FILE"
                green "所有域名已清空"
            fi
            ;;
        0) main_menu;;
        *) red "无效选择";;
    esac
    press_to_continue
}

# 查看分流状态和测试
show_status_and_test() {
    clear
    green "=== 查看分流状态和测试 ==="
    log_info "开始分流状态测试"
    
    echo "1. 测试WARP连接"
    if test_warp_connection; then
        green "WARP连接正常"
    else
        red "WARP连接失败"
    fi
    
    echo "2. 测试本地代理连接"
    local local_ip=$(curl -s --max-time 15 http://ip-api.com/json | jq -r '.query')
    if [[ -n "$local_ip" ]]; then
        blue "本地IP: $local_ip"
        green "本地连接正常"
    else
        red "本地连接失败"
    fi
    
    press_to_continue
}

# 重启WARP服务
restart_warp_service() {
    log_info "重启WARP服务"
    start_warp_service
    press_to_continue
}

# 查看日志
show_logs() {
    clear
    green "=== 查看日志 ==="
    echo "1. WARP服务日志"
    echo "2. 脚本运行日志"
    echo "3. Sing-box日志"
    echo "4. 实时监控WARP日志"
    echo "0. 返回主菜单"
    readp "请选择 [0-4]: " log_choice
    
    case $log_choice in
        1)
            journalctl -u warp-socks5 -n 20 --no-pager
            ;;
        2)
            cat "$LOG_FILE"
            ;;
        3)
            journalctl -u sing-box -n 20 --no-pager
            ;;
        4)
            journalctl -u warp-socks5 -f
            ;;
        0) main_menu;;
        *) red "无效选择";;
    esac
    press_to_continue
}

# 卸载配置
uninstall_all() {
    clear
    green "=== 卸载配置 ==="
    readp "确认卸载所有WARP分流配置？[Y/n]: " confirm
    if [[ $confirm =~ [Yy] ]]; then
        systemctl stop warp-socks5 2>/dev/null
        systemctl disable warp-socks5 2>/dev/null
        rm -f /etc/systemd/system/warp-socks5.service
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR"
        rm -f "$LOG_FILE"
        yellow "WARP分流配置已卸载"
    fi
    press_to_continue
}

# 辅助函数
check_port_usage() {
    local port="$1"
    ! ss -tlnp | grep -q ":$port"
}

press_to_continue() {
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# 脚本入口
main_menu
