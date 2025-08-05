#!/bin/bash

# Blackbox Exporter 安装脚本
# 支持 Debian/Alpine, amd64/arm64 架构
# 监听地址: 127.0.0.1:9115

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统"
        exit 1
    fi
    
    # 标准化OS名称
    if [[ "$OS" == *"Debian"* ]]; then
        OS_TYPE="debian"
    elif [[ "$OS" == *"Alpine"* ]]; then
        OS_TYPE="alpine"
    else
        log_error "不支持的操作系统: $OS"
        exit 1
    fi
    
    log_info "检测到操作系统: $OS_TYPE"
}

# 检测架构
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            NODE_ARCH="amd64"
            ;;
        aarch64|arm64)
            NODE_ARCH="arm64"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "检测到架构: $NODE_ARCH"
}

# 获取最新版本
get_latest_version() {
    log_info "获取Blackbox Exporter最新版本..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
    if [ -z "$LATEST_VERSION" ]; then
        log_error "无法获取最新版本信息"
        exit 1
    fi
    log_info "最新版本: $LATEST_VERSION"
}

# 下载Blackbox Exporter
download_blackbox_exporter() {
    local download_url="https://github.com/prometheus/blackbox_exporter/releases/download/v${LATEST_VERSION}/blackbox_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    local archive_name="blackbox_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    
    log_info "下载Blackbox Exporter..."
    cd /tmp
    if ! curl -L -o "$archive_name" "$download_url"; then
        log_error "下载失败"
        exit 1
    fi
    
    # 验证下载
    if [ ! -f "$archive_name" ]; then
        log_error "下载文件不存在"
        exit 1
    fi
}

# 安装Blackbox Exporter
install_blackbox_exporter() {
    local archive_name="blackbox_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    local extract_dir="blackbox_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}"
    
    log_info "解压文件..."
    tar xzf "$archive_name"
    
    log_info "安装Blackbox Exporter..."
    # 创建用户
    if ! id "blackbox_exporter" &>/dev/null; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            useradd -rs /bin/false blackbox_exporter
        elif [[ "$OS_TYPE" == "alpine" ]]; then
            adduser -D -S -s /bin/false blackbox_exporter
        fi
    fi
    
    # 移动二进制文件
    mv "$extract_dir/blackbox_exporter" /usr/local/bin/
    chown blackbox_exporter:blackbox_exporter /usr/local/bin/blackbox_exporter
    chmod +x /usr/local/bin/blackbox_exporter
    
    # 创建配置目录
    mkdir -p /etc/blackbox_exporter
    chown blackbox_exporter:blackbox_exporter /etc/blackbox_exporter
    
    # 复制示例配置文件
    cp "$extract_dir/blackbox.yml" /etc/blackbox_exporter/
    chown blackbox_exporter:blackbox_exporter /etc/blackbox_exporter/blackbox.yml
    
    # 清理临时文件
    rm -rf "$archive_name" "$extract_dir"
}

# 创建默认配置文件
create_config() {
    log_info "创建默认配置文件..."
    cat > /etc/blackbox_exporter/blackbox.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: GET
      preferred_ip_protocol: "ip4"
      ip_protocol_fallback: false

  http_post_2xx:
    prober: http
    timeout: 5s
    http:
      method: POST
      preferred_ip_protocol: "ip4"
      ip_protocol_fallback: false

  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: "ip4"
      ip_protocol_fallback: false

  icmp_ping:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"
      ip_protocol_fallback: false

  dns_query:
    prober: dns
    dns:
      preferred_ip_protocol: "ip4"
      query_name: "google.com"
      query_type: "A"
      valid_rcodes:
        - NOERROR
      validate_answer_rrs:
        fail_if_not_matches_regexp:
          - "google.com"
EOF

    chown blackbox_exporter:blackbox_exporter /etc/blackbox_exporter/blackbox.yml
    chmod 644 /etc/blackbox_exporter/blackbox.yml
}

# 创建systemd服务 (Debian)
create_systemd_service() {
    log_info "创建systemd服务..."
    cat > /etc/systemd/system/blackbox_exporter.service << EOF
[Unit]
Description=Blackbox Exporter
After=network.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter \
  --config.file=/etc/blackbox_exporter/blackbox.yml \
  --web.listen-address=127.0.0.1:9115
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 创建OpenRC服务 (Alpine)
create_openrc_service() {
    log_info "创建OpenRC服务..."
    cat > /etc/init.d/blackbox_exporter << 'EOF'
#!/sbin/openrc-run

name="blackbox_exporter"
description="Blackbox Exporter for Prometheus"
command="/usr/local/bin/blackbox_exporter"
command_args="--config.file=/etc/blackbox_exporter/blackbox.yml --web.listen-address=127.0.0.1:9115"
pidfile="/var/run/blackbox_exporter.pid"
user="blackbox_exporter"
group="blackbox_exporter"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o ${user} -g ${group} $(dirname $pidfile)
}
EOF

    chmod +x /etc/init.d/blackbox_exporter
    
    # 创建sysconfig文件
    mkdir -p /etc/conf.d
    echo 'BLACKBOX_EXPORTER_OPTS="--config.file=/etc/blackbox_exporter/blackbox.yml --web.listen-address=127.0.0.1:9115"' > /etc/conf.d/blackbox_exporter
}

# 启动服务
start_service() {
    log_info "启动Blackbox Exporter服务..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        systemctl enable blackbox_exporter
        systemctl restart blackbox_exporter
        systemctl status blackbox_exporter --no-pager
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        rc-update add blackbox_exporter default
        rc-service blackbox_exporter restart
        rc-service blackbox_exporter status
    fi
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    sleep 3
    
    if curl -s http://127.0.0.1:9115/metrics | grep -q "blackbox_exporter"; then
        log_info "Blackbox Exporter安装成功！"
        log_info "监听地址: http://127.0.0.1:9115/metrics"
        log_info "配置文件位置: /etc/blackbox_exporter/blackbox.yml"
        return 0
    else
        log_error "Blackbox Exporter安装验证失败"
        return 1
    fi
}

# 显示使用示例
show_usage() {
    log_info "Blackbox Exporter使用示例:"
    echo
    log_info "1. HTTP探测示例:"
    echo "   curl 'http://127.0.0.1:9115/probe?module=http_2xx&target=https://www.google.com'"
    echo
    log_info "2. TCP探测示例:"
    echo "   curl 'http://127.0.0.1:9115/probe?module=tcp_connect&target=google.com:443'"
    echo
    log_info "3. ICMP探测示例:"
    echo "   curl 'http://127.0.0.1:9115/probe?module=icmp_ping&target=8.8.8.8'"
    echo
    log_info "如需修改配置，请编辑: /etc/blackbox_exporter/blackbox.yml"
    echo
}

# 主函数
main() {
    log_info "开始安装Blackbox Exporter..."
    
    check_root
    detect_os
    detect_arch
    get_latest_version
    download_blackbox_exporter
    install_blackbox_exporter
    create_config
    
    # 根据操作系统创建相应的服务
    if [[ "$OS_TYPE" == "debian" ]]; then
        create_systemd_service
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        create_openrc_service
    fi
    
    start_service
    verify_installation
    show_usage
    
    log_info "安装完成！"
    log_info "服务状态信息如上所示"
    log_info "如需查看详细指标，请访问: http://127.0.0.1:9115/metrics"
}

# 清理函数
cleanup() {
    log_warn "安装被中断，正在清理..."
    rm -f /tmp/blackbox_exporter-*.tar.gz
    rm -rf /tmp/blackbox_exporter-*
    exit 1
}

# 设置信号处理
trap cleanup INT TERM

# 执行主函数
main
