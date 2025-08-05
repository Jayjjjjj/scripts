#!/bin/bash

# Node Exporter 安装脚本
# 支持 Debian/Alpine, amd64/arm64 架构
# 监听地址: 127.0.0.1:9100

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
    log_info "获取Node Exporter最新版本..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
    if [ -z "$LATEST_VERSION" ]; then
        log_error "无法获取最新版本信息"
        exit 1
    fi
    log_info "最新版本: $LATEST_VERSION"
}

# 下载Node Exporter
download_node_exporter() {
    local download_url="https://github.com/prometheus/node_exporter/releases/download/v${LATEST_VERSION}/node_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    local archive_name="node_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    
    log_info "下载Node Exporter..."
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

# 安装Node Exporter
install_node_exporter() {
    local archive_name="node_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}.tar.gz"
    local extract_dir="node_exporter-${LATEST_VERSION}.linux-${NODE_ARCH}"
    
    log_info "解压文件..."
    tar xzf "$archive_name"
    
    log_info "安装Node Exporter..."
    # 创建用户
    if ! id "node_exporter" &>/dev/null; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            useradd -rs /bin/false node_exporter
        elif [[ "$OS_TYPE" == "alpine" ]]; then
            adduser -D -S -s /bin/false node_exporter
        fi
    fi
    
    # 移动二进制文件
    mv "$extract_dir/node_exporter" /usr/local/bin/
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    chmod +x /usr/local/bin/node_exporter
    
    # 清理临时文件
    rm -rf "$archive_name" "$extract_dir"
}

# 创建systemd服务 (Debian)
create_systemd_service() {
    log_info "创建systemd服务..."
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 创建OpenRC服务 (Alpine)
create_openrc_service() {
    log_info "创建OpenRC服务..."
    cat > /etc/init.d/node_exporter << 'EOF'
#!/sbin/openrc-run

name="node_exporter"
description="Node Exporter for Prometheus"
command="/usr/local/bin/node_exporter"
command_args="--web.listen-address=127.0.0.1:9100"
pidfile="/var/run/node_exporter.pid"
user="node_exporter"
group="node_exporter"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o ${user} -g ${group} $(dirname $pidfile)
}
EOF

    chmod +x /etc/init.d/node_exporter
    
    # 创建sysconfig文件
    mkdir -p /etc/conf.d
    echo 'NODE_EXPORTER_OPTS="--web.listen-address=127.0.0.1:9100"' > /etc/conf.d/node_exporter
}

# 启动服务
start_service() {
    log_info "启动Node Exporter服务..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        systemctl enable node_exporter
        systemctl restart node_exporter
        systemctl status node_exporter --no-pager
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        rc-update add node_exporter default
        rc-service node_exporter restart
        rc-service node_exporter status
    fi
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    sleep 3
    
    if curl -s http://127.0.0.1:9100/metrics | grep -q "node_exporter"; then
        log_info "Node Exporter安装成功！"
        log_info "监听地址: http://127.0.0.1:9100/metrics"
        return 0
    else
        log_error "Node Exporter安装验证失败"
        return 1
    fi
}

# 主函数
main() {
    log_info "开始安装Node Exporter..."
    
    check_root
    detect_os
    detect_arch
    get_latest_version
    download_node_exporter
    install_node_exporter
    
    # 根据操作系统创建相应的服务
    if [[ "$OS_TYPE" == "debian" ]]; then
        create_systemd_service
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        create_openrc_service
    fi
    
    start_service
    verify_installation
    
    log_info "安装完成！"
    log_info "服务状态信息如上所示"
    log_info "如需查看详细指标，请访问: http://127.0.0.1:9100/metrics"
}

# 清理函数
cleanup() {
    log_warn "安装被中断，正在清理..."
    rm -f /tmp/node_exporter-*.tar.gz
    rm -rf /tmp/node_exporter-*
    exit 1
}

# 设置信号处理
trap cleanup INT TERM

# 执行主函数
main
