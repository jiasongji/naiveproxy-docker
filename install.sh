#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# ================================================================
# NaiveProxy Docker 一键部署脚本
# 项目: https://github.com/jiasongji/naiveproxy-docker
# 基于 jiasongji/naiveproxy-docker 镜像，修复了原版多项 BUG
# ================================================================

# ------------ 终端颜色 ------------
exec 3>&1
if [ -t 1 ] && command -v tput >/dev/null; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
        bold="$(tput bold || echo)"
        normal="$(tput sgr0 || echo)"
        red="$(tput setaf 1 || echo)"
        green="$(tput setaf 2 || echo)"
        yellow="$(tput setaf 3 || echo)"
        cyan="$(tput setaf 6 || echo)"
    fi
fi

say()    { printf "%b\n" "${cyan:-}naive:${normal:-} $1" >&3; }
warn()   { printf "%b\n" "${yellow:-}naive: ⚠ $1${normal:-}" >&3; }
err()    { printf "%b\n" "${red:-}naive: ✗ $1${normal:-}" >&2; }
ok()     { printf "%b\n" "${green:-}naive: ✓ $1${normal:-}" >&3; }
die()    { err "$1"; exit 1; }

# ------------ 变量 ------------
GIT_RAW="https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main"
INSTALL_DIR=""

cfg_host=""
cfg_cert_mode=""
cfg_cert_file=""
cfg_cert_key=""
cfg_mail=""
cfg_http_port=""
cfg_https_port=""
cfg_user=""
cfg_pass=""
cfg_fake_host=""
cfg_verbose=false
cfg_auto_confirm=false

fake_host_default="https://soft.xiaoz.org"

# ------------ 工具函数 ------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
    local src="$1" dst="${2:-}"
    local curl_opts="-sSL -f --retry 5 --retry-delay 2 --connect-timeout 15 --create-dirs"
    if has_cmd "curl"; then
        if [ -n "$dst" ]; then
            curl $curl_opts -o "$dst" "$src" 2>&1 || return 1
        else
            curl $curl_opts "$src" 2>&1 || return 1
        fi
    elif has_cmd "wget"; then
        if [ -n "$dst" ]; then
            wget -q --tries 5 -O "$dst" "$src" 2>&1 || return 1
        else
            wget -q --tries 5 -O - "$src" 2>&1 || return 1
        fi
    else
        die "需要 curl 或 wget，请先安装其一"
    fi
}

# ------------ 参数解析 ------------
usage() {
    local sn
    sn="$(basename "$0")"
    cat >&3 <<EOF
NaiveProxy Docker 一键部署脚本

用法: $sn [选项]

选项:
  -d, --install-dir <DIR>      安装目录 (默认: /root/naiveproxy)
  -t, --host <HOST>            绑定域名
  -o, --cert-mode <1|2>       证书模式: 1=自动申请  2=使用现有证书
  -m, --mail <MAIL>            邮箱 (自动申请证书时需要)
  -c, --cert-file <PATH>       证书文件路径 (模式2)
  -k, --cert-key <PATH>        私钥文件路径 (模式2)
  -w, --http-port <PORT>       HTTP 端口 (默认: 80)
  -s, --https-port <PORT>      HTTPS 端口 (默认: 443)
  -u, --user <USER>            代理用户名
  -p, --pwd <PASS>             代理密码
  -f, --fake-host <URL>        伪装站点 (默认: $fake_host_default)
  -y, --yes                    跳过确认，自动执行
  -v, --verbose                开启调试模式
  -h, --help                   显示帮助
EOF
    exit 0
}

while [ $# -ne 0 ]; do
    name="$1"
    case "$name" in
    -d|--install-dir)   shift; INSTALL_DIR="$1" ;;
    -t|--host)          shift; cfg_host="$1" ;;
    -o|--cert-mode)     shift; cfg_cert_mode="$1" ;;
    -m|--mail)          shift; cfg_mail="$1" ;;
    -c|--cert-file)     shift; cfg_cert_file="$1" ;;
    -k|--cert-key)      shift; cfg_cert_key="$1" ;;
    -w|--http-port)     shift; cfg_http_port="$1" ;;
    -s|--https-port)    shift; cfg_https_port="$1" ;;
    -u|--user)          shift; cfg_user="$1" ;;
    -p|--pwd)           shift; cfg_pass="$1" ;;
    -f|--fake-host)     shift; cfg_fake_host="$1" ;;
    -y|--yes)          cfg_auto_confirm=true ;;
    -v|--verbose)       cfg_verbose=true ;;
    -h|--help)          usage ;;
    *) die "未知参数: $name" ;;
    esac
    shift
done

# ------------ 前置检查 ------------
say "检查运行环境..."
has_cmd "docker" || die "未找到 docker，请先安装"
docker --version >&3

# 检查是否已有运行中的 naiveproxy 容器
if docker ps -a --filter "name=naiveproxy" --format '{{.Names}}' | grep -q '^naiveproxy$'; then
    warn "检测到已有的 naiveproxy 容器，将先停止并移除"
    docker stop naiveproxy 2>/dev/null || true
    docker rm   naiveproxy 2>/dev/null || true
fi

# ------------ 交互式输入 ------------
say ""
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say "  NaiveProxy Docker 交互式部署"
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say ""

# 域名
if [ -z "${cfg_host:-}" ]; then
    read -rp "  请输入绑定域名 (如 proxy.example.com): " cfg_host
fi
[ -n "${cfg_host:-}" ] || die "域名不能为空"
ok "域名: $cfg_host"

# 证书模式
if [ -z "${cfg_cert_mode:-}" ]; then
    read -rp "  证书模式 [1] 自动申请  [2] 使用现有证书 (默认1): " cfg_cert_mode
    cfg_cert_mode="${cfg_cert_mode:-1}"
fi
[[ "$cfg_cert_mode" == "1" || "$cfg_cert_mode" == "2" ]] || die "证书模式只能选 1 或 2"

if [ "$cfg_cert_mode" == "1" ]; then
    warn "自动申请证书需要开放 80 端口，请确保 80 端口未被占用"
    cfg_http_port="80"
    if [ -z "${cfg_mail:-}" ]; then
        read -rp "  请输入邮箱 (用于 ACME 证书申请): " cfg_mail
    fi
    [ -n "${cfg_mail:-}" ] || die "自动申请证书时邮箱不能为空"
    ok "邮箱: $cfg_mail"
else
    if [ -z "${cfg_cert_file:-}" ]; then
        read -rp "  请输入证书文件路径 (fullchain.pem): " cfg_cert_file
    fi
    if [ -z "${cfg_cert_key:-}" ]; then
        read -rp "  请输入私钥文件路径 (privkey.pem): " cfg_cert_key
    fi
    [[ "$cfg_cert_file" == /* ]] || die "证书路径必须为绝对路径"
    [[ "$cfg_cert_key" == /* ]]  || die "私钥路径必须为绝对路径"
    [ -f "$cfg_cert_file" ] || die "证书文件不存在: $cfg_cert_file"
    [ -f "$cfg_cert_key" ]  || die "私钥文件不存在: $cfg_cert_key"
    ok "证书: $cfg_cert_file"
    ok "私钥: $cfg_cert_key"
fi

# HTTP 端口
if [ -z "${cfg_http_port:-}" ]; then
    if [ "$cfg_cert_mode" == "2" ]; then
        read -rp "  HTTP 端口 (默认80): " cfg_http_port
        cfg_http_port="${cfg_http_port:-80}"
    else
        cfg_http_port="80"
    fi
fi
ok "HTTP 端口: $cfg_http_port"

# HTTPS 端口
if [ -z "${cfg_https_port:-}" ]; then
    read -rp "  HTTPS 端口 (默认443): " cfg_https_port
    cfg_https_port="${cfg_https_port:-443}"
fi
ok "HTTPS 端口: $cfg_https_port"

# 用户名
if [ -z "${cfg_user:-}" ]; then
    read -rp "  代理用户名: " cfg_user
fi
[ -n "${cfg_user:-}" ] || die "用户名不能为空"
ok "用户名: $cfg_user"

# 密码
if [ -z "${cfg_pass:-}" ]; then
    read -rp "  代理密码: " cfg_pass
fi
[ -n "${cfg_pass:-}" ] || die "密码不能为空"
ok "密码: **** (已设置)"

# 伪装站
if [ -z "${cfg_fake_host:-}" ]; then
    read -rp "  伪装站点 (默认 $fake_host_default): " cfg_fake_host
    cfg_fake_host="${cfg_fake_host:-$fake_host_default}"
fi
ok "伪装站: $cfg_fake_host"

# 安装目录
if [ -z "${INSTALL_DIR:-}" ]; then
    INSTALL_DIR="/root/naiveproxy"
fi

# ------------ 配置确认 ------------
say ""
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say "  配置确认"
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say "  域名:       $cfg_host"
say "  证书模式:   $([ "$cfg_cert_mode" == "1" ] && echo "自动申请" || echo "使用现有证书")"
[ "$cfg_cert_mode" == "1" ] && say "  邮箱:       $cfg_mail"
[ "$cfg_cert_mode" == "2" ] && { say "  证书:       $cfg_cert_file"; say "  私钥:       $cfg_cert_key"; }
say "  HTTP 端口:  $cfg_http_port"
say "  HTTPS 端口: $cfg_https_port"
say "  用户名:     $cfg_user"
say "  密码:       ****"
say "  伪装站:     $cfg_fake_host"
say "  安装目录:   $INSTALL_DIR"
say "  调试模式:   $cfg_verbose"
say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
say ""

if [ "$cfg_auto_confirm" = true ]; then
    ok "自动确认 (--yes)"
else
    read -rp "  确认以上配置无误？(Y/n): " confirm
    confirm="${confirm:-Y}"
    [[ "${confirm,,}" == "n" ]] && die "用户取消部署"
fi

# ------------ 创建安装目录 ------------
say "创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data"
cd "$INSTALL_DIR"

# ------------ 生成 entry.sh ------------
say "生成 entry.sh..."
cat > ./data/entry.sh <<'ENTRY'
#!/bin/bash
set -e

# 注意：不要使用 caddy fmt --overwrite 格式化 Caddyfile
# caddy fmt 会截断 forward_proxy basic_auth 中的密码字段
# Caddyfile 已由 install.sh 预格式化

echo "Start server"
/app/caddy start --config /data/Caddyfile

tail -f -n 50 /data/Caddyfile
ENTRY
chmod +x ./data/entry.sh
ok "entry.sh 已生成"

# ------------ 生成 Caddyfile ------------
say "生成 Caddyfile..."

# 构建 TLS 配置行
if [ "$cfg_cert_mode" == "1" ]; then
    tls_line="tls ${cfg_mail}"
    auto_https_line=""
else
    tls_line="tls ${cfg_cert_file} ${cfg_cert_key}"
    auto_https_line="auto_https off"
fi

# 构建 debug 行
debug_line=""
if [ "$cfg_verbose" = true ]; then
    debug_line="debug"
fi

# 整体写入 Caddyfile（不使用 caddy fmt，避免密码字段被截断）
cat > ./data/Caddyfile <<CADDYFILE
{
	${debug_line}
	http_port ${cfg_http_port}
	https_port ${cfg_https_port}
	${auto_https_line}
	order forward_proxy before file_server
}
:${cfg_https_port}, ${cfg_host} {
	${tls_line}
	route {
		# proxy
		forward_proxy {
			basic_auth ${cfg_user} ${cfg_pass}
			hide_ip
			hide_via
			probe_resistance
		}

		# 伪装网址
		reverse_proxy ${cfg_fake_host} {
			header_up Host {upstream_hostport}
		}
	}
}
CADDYFILE

ok "Caddyfile 已生成"

# ------------ 生成 docker-compose.yml ------------
say "生成 docker-compose.yml..."

if [ "$cfg_cert_mode" == "2" ]; then
    cat > ./docker-compose.yml <<COMPOSE
version: '3.4'

services:
  naive:
    image: jiasongji/naiveproxy-docker
    container_name: naiveproxy
    tty: true
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./data:/data
      - ./share:/root/.local/share
      - ${cfg_cert_file}:${cfg_cert_file}:ro
      - ${cfg_cert_key}:${cfg_cert_key}:ro
    command: ["/bin/bash", "/data/entry.sh"]
COMPOSE
else
    cat > ./docker-compose.yml <<COMPOSE
version: '3.4'

services:
  naive:
    image: jiasongji/naiveproxy-docker
    container_name: naiveproxy
    tty: true
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./data:/data
      - ./share:/root/.local/share
    command: ["/bin/bash", "/data/entry.sh"]
COMPOSE
fi

ok "docker-compose.yml 已生成"

# ------------ 启动容器 ------------
say "拉取镜像并启动容器..."
if docker compose version >/dev/null 2>&1; then
    docker compose up -d
elif docker-compose version >/dev/null 2>&1; then
    docker-compose up -d
else
    # 兜底: 直接 docker run
    vols="-v $PWD/data:/data -v $PWD/share:/root/.local/share"
    if [ "$cfg_cert_mode" == "2" ]; then
        vols="$vols -v $cfg_cert_file:$cfg_cert_file:ro -v $cfg_cert_key:$cfg_cert_key:ro"
    fi
    # shellcheck disable=SC2086
    docker run -d --network=host --name naiveproxy \
        --restart=unless-stopped \
        $vols \
        jiasongji/naiveproxy-docker \
        /bin/bash /data/entry.sh
fi

# ------------ 等待 & 检查结果 ------------
say "等待容器启动..."
sleep 3

if docker ps --filter "name=naiveproxy" --format '{{.Names}}' | grep -q '^naiveproxy$'; then
    ok "容器启动成功！"
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  部署完成"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say ""
    say "  浏览器访问以下地址验证伪装站点:"
    say "    https://${cfg_host}:${cfg_https_port}"
    say ""
    say "  客户端连接信息:"
    say "    naive+https://${cfg_user}:${cfg_pass}@${cfg_host}:${cfg_https_port}#naive"
    say ""
    say "  常用命令:"
    say "    查看日志:   docker logs -f naiveproxy"
    say "    重启:       docker restart naiveproxy"
    say "    更新镜像:   cd $INSTALL_DIR && docker compose pull && docker compose up -d"
    say "    卸载:       docker stop naiveproxy && docker rm naiveproxy && rm -rf $INSTALL_DIR"
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    err "容器启动失败，查看日志:"
    docker logs naiveproxy 2>&1 | tail -30
    exit 1
fi
