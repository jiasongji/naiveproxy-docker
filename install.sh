#!/usr/bin/env bash
set -e
set -u
set -o pipefail

# ================================================================
# NaiveProxy Docker 一键部署 & 管理脚本
# 项目: https://github.com/jiasongji/naiveproxy-docker
#
# 功能:
#   1. 全新部署 - 交互式配置，智能默认值
#   2. 修改配置 - 热修改端口/账号/密码/反代地址，自动生效
#   3. 卸载     - 清理容器和数据
#
# 用法:
#   bash install.sh              # 交互式部署
#   bash install.sh --modify     # 修改已有配置
#   bash install.sh --uninstall  # 卸载
#   bash install.sh [选项]       # 非交互式部署
# ================================================================

VERSION="2.0.0"

# ------------ 终端颜色 ------------
exec 3>&1
if [ -t 1 ] && command -v tput >/dev/null; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
        B="$(tput bold || echo)"  N="$(tput sgr0 || echo)"
        R="$(tput setaf 1 || echo)" G="$(tput setaf 2 || echo)"
        Y="$(tput setaf 3 || echo)" C="$(tput setaf 6 || echo)"
    fi
fi

say()    { printf "%b\n" "${C:-}naive:${N:-} $1" >&3; }
warn()   { printf "%b\n" "${Y:-}naive: ⚠ $1${N:-}" >&3; }
err()    { printf "%b\n" "${R:-}naive: ✗ $1${N:-}" >&2; }
ok()     { printf "%b\n" "${G:-}naive: ✓ $1${N:-}" >&3; }
die()    { err "$1"; exit 1; }
info()   { printf "%b\n" "${B:-}  $1${N:-}" >&3; }

# ------------ 常量 ------------
GIT_RAW="https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main"
BT_CERT_BASE="/www/server/panel/vhost/cert"
BT_SITE_BASE="/www/wwwroot"
CONTAINER_NAME="naiveproxy"
IMAGE="jiasongji/naiveproxy-docker"
FAKE_HOSTS=("https://demo.cloudreve.org" "https://soft.xiaoz.org")

# ------------ 运行时变量 ------------
cfg_host=""
cfg_http_port=""
cfg_https_port=""
cfg_user=""
cfg_pass=""
cfg_cert_file=""
cfg_cert_key=""
cfg_fake_host=""
cfg_install_dir=""
cfg_verbose=false
cfg_auto_confirm=false
cfg_mode="install"   # install | modify | uninstall

# ------------ 工具函数 ------------
has_cmd()     { command -v "$1" >/dev/null 2>&1; }
is_bt()       { [ -d "/www/server/panel" ]; }
is_running()  { docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; }
exists()      { docker ps -a --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; }

# 生成随机字符串（字母+数字，12位）
gen_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 16 || \
    openssl rand -hex 8 2>/dev/null || \
    echo "naive$(date +%s)"
}

# 生成随机用户名
gen_username() {
    echo "np$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6 || echo $RANDOM)"
}

# 查找宝塔站点中可用的伪装站点（排除当前域名）
find_bt_fake_host() {
    local domain="$1"
    local candidates=()
    for dir in "$BT_SITE_BASE"/*/; do
        local d
        d="$(basename "$dir")"
        # 排除默认目录和当前域名
        [[ "$d" == "default" || "$d" == "panel_ssl_site" || "$d" == "$domain" || "$d" == "*."* ]] && continue
        # 检查是否有实际站点文件
        [ -f "${dir}index.html" ] || [ -f "${dir}index.php" ] || continue
        candidates+=("https://$d")
    done
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[0]}"
    else
        local idx=$(( RANDOM % ${#FAKE_HOSTS[@]} ))
        echo "${FAKE_HOSTS[$idx]}"
    fi
}

# 获取已有容器的安装目录（从 volume 映射推断）
get_install_dir() {
    if ! exists; then
        echo ""
        return
    fi
    local data_dir
    data_dir=$(docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -n "$data_dir" ]; then
        # data_dir 是 /path/data，取其父目录
        dirname "$data_dir"
    else
        echo ""
    fi
}

# 从已有 Caddyfile 读取当前配置
read_current_config() {
    local caddyfile="$1"
    if [ ! -f "$caddyfile" ]; then
        return 1
    fi
    # 提取 https_port
    cfg_https_port=$(grep -oP 'https_port\s+\K\d+' "$caddyfile" 2>/dev/null || echo "")
    cfg_http_port=$(grep -oP 'http_port\s+\K\d+' "$caddyfile" 2>/dev/null || echo "")
    # 提取域名
    cfg_host=$(grep -oP ':\d+,\s*\K[^ {]+' "$caddyfile" 2>/dev/null || echo "")
    # 提取 basic_auth 用户名和密码
    local auth_line
    auth_line=$(grep 'basic_auth' "$caddyfile" 2>/dev/null | head -1)
    cfg_user=$(echo "$auth_line" | awk '{print $2}' 2>/dev/null || echo "")
    cfg_pass=$(echo "$auth_line" | awk '{print $3}' 2>/dev/null || echo "")
    # 提取 reverse_proxy 目标
    cfg_fake_host=$(grep -oP 'reverse_proxy\s+\K\S+' "$caddyfile" 2>/dev/null | head -1 || echo "")
    # 提取证书路径
    cfg_cert_file=$(grep -oP 'tls\s+\K\S+' "$caddyfile" 2>/dev/null | head -1 || echo "")
    cfg_cert_key=$(grep -oP 'tls\s+\S+\s+\K\S+' "$caddyfile" 2>/dev/null | head -1 || echo "")
    return 0
}

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
        die "需要 curl 或 wget，请先安装"
    fi
}

# ------------ 参数解析 ------------
usage() {
    cat >&3 <<EOF
${B:-}NaiveProxy Docker 管理脚本 v${VERSION}${N:-}

${B:-}用法:${N:-}
  $(basename "$0")                  交互式全新部署
  $(basename "$0") --modify         修改已有配置
  $(basename "$0") --uninstall      卸载并清理

${B:-}部署选项:${N:-}
  -t, --host <HOST>            绑定域名
  -w, --http-port <PORT>       HTTP 端口 (默认 80)
  -s, --https-port <PORT>      HTTPS 端口 (默认 443)
  -u, --user <USER>            代理用户名 (默认自动生成)
  -p, --pwd <PASS>             代理密码 (默认自动生成)
  -f, --fake-host <URL>        伪装站点 (默认自动检测)
  -c, --cert-file <PATH>       证书文件路径 (默认宝塔证书)
  -k, --cert-key <PATH>        私钥文件路径 (默认宝塔证书)
  -d, --install-dir <DIR>      安装目录 (默认 /www/wwwroot/<域名>/naiveproxy)
  -y, --yes                    跳过确认
  -v, --verbose                调试模式
  -h, --help                   显示帮助
EOF
    exit 0
}

while [ $# -ne 0 ]; do
    name="$1"
    case "$name" in
    --modify|--reconfig|--reconfigure) cfg_mode="modify" ;;
    --uninstall|--remove)              cfg_mode="uninstall" ;;
    -t|--host)        shift; cfg_host="$1" ;;
    -w|--http-port)   shift; cfg_http_port="$1" ;;
    -s|--https-port)  shift; cfg_https_port="$1" ;;
    -u|--user)        shift; cfg_user="$1" ;;
    -p|--pwd)         shift; cfg_pass="$1" ;;
    -f|--fake-host)   shift; cfg_fake_host="$1" ;;
    -c|--cert-file)   shift; cfg_cert_file="$1" ;;
    -k|--cert-key)    shift; cfg_cert_key="$1" ;;
    -d|--install-dir) shift; cfg_install_dir="$1" ;;
    -y|--yes)         cfg_auto_confirm=true ;;
    --verbose|-v)     cfg_verbose=true ;;
    -h|--help)        usage ;;
    *) die "未知参数: $name (用 -h 查看帮助)" ;;
    esac
    shift
done

# ================================================================
#  卸载模式
# ================================================================
do_uninstall() {
    say "准备卸载 NaiveProxy..."
    local install_dir
    install_dir=$(get_install_dir)

    if [ -z "$install_dir" ]; then
        # 尝试从配置推断
        if [ -n "${cfg_host:-}" ]; then
            install_dir="$BT_SITE_BASE/$cfg_host/naiveproxy"
        else
            install_dir="/root/naiveproxy"
        fi
    fi

    say "将删除以下内容:"
    say "  容器:   $CONTAINER_NAME"
    say "  数据:   $install_dir"
    say ""

    if [ "$cfg_auto_confirm" != true ]; then
        read -rp "  确认卸载？此操作不可恢复 (y/N): " confirm
        [[ "${confirm,,}" == "y" ]] || die "已取消"
    fi

    if exists; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm   "$CONTAINER_NAME" 2>/dev/null || true
        ok "容器已移除"
    fi

    if [ -d "$install_dir" ]; then
        rm -rf "$install_dir"
        ok "数据目录已删除: $install_dir"
    fi

    ok "卸载完成"
    exit 0
}

# ================================================================
#  修改模式
# ================================================================
do_modify() {
    if ! exists; then
        die "未找到 $CONTAINER_NAME 容器，请先部署"
    fi

    local install_dir
    install_dir=$(get_install_dir)
    if [ -z "$install_dir" ]; then
        die "无法推断安装目录"
    fi

    local caddyfile="$install_dir/data/Caddyfile"
    if [ ! -f "$caddyfile" ]; then
        die "未找到 Caddyfile: $caddyfile"
    fi

    # 读取当前配置
    read_current_config "$caddyfile"
    local orig_host="$cfg_host"
    local orig_https_port="$cfg_https_port"
    local orig_http_port="$cfg_http_port"

    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  修改 NaiveProxy 配置"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  当前配置:"
    say "    域名:       $cfg_host"
    say "    HTTPS 端口: $cfg_https_port"
    say "    用户名:     $cfg_user"
    say "    密码:       $cfg_pass"
    say "    伪装站:     $cfg_fake_host"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say ""
    say "  直接回车保持当前值，输入新值则修改"
    say ""

    # HTTPS 端口
    local new_https_port="$cfg_https_port"
    read -rp "  HTTPS 端口 [$cfg_https_port]: " input
    [ -n "$input" ] && new_https_port="$input"

    # 用户名
    local new_user="$cfg_user"
    read -rp "  用户名 [$cfg_user]: " input
    [ -n "$input" ] && new_user="$input"

    # 密码
    local new_pass="$cfg_pass"
    read -rp "  密码 [$cfg_pass] (输入新密码或回车保持): " input
    [ -n "$input" ] && new_pass="$input"

    # 伪装站
    local new_fake_host="$cfg_fake_host"
    read -rp "  伪装站点 [$cfg_fake_host]: " input
    [ -n "$input" ] && new_fake_host="$input"

    # 检查是否有变化
    if [ "$new_https_port" == "$cfg_https_port" ] && \
       [ "$new_user" == "$cfg_user" ] && \
       [ "$new_pass" == "$cfg_pass" ] && \
       [ "$new_fake_host" == "$cfg_fake_host" ]; then
        say "配置未变更，无需更新"
        exit 0
    fi

    say ""
    say "  将更新为:"
    [ "$new_https_port" != "$cfg_https_port" ] && say "    HTTPS 端口: $cfg_https_port → $new_https_port"
    [ "$new_user" != "$cfg_user" ] && say "    用户名:     $cfg_user → $new_user"
    [ "$new_pass" != "$cfg_pass" ] && say "    密码:       (已修改)"
    [ "$new_fake_host" != "$cfg_fake_host" ] && say "    伪装站:     $cfg_fake_host → $new_fake_host"
    say ""

    if [ "$cfg_auto_confirm" != true ]; then
        read -rp "  确认修改？(Y/n): " confirm
        confirm="${confirm:-Y}"
        [[ "${confirm,,}" == "n" ]] && die "已取消"
    fi

    # 计算 HTTP 端口
    local new_http_port="$cfg_http_port"
    if [ "$new_https_port" != "$cfg_https_port" ]; then
        # 端口变了，HTTP 端口也跟着调整
        new_http_port=$((new_https_port - 1))
    fi

    # 重建 Caddyfile
    say "重新生成 Caddyfile..."
    local auto_https_line="auto_https off"
    local debug_line=""
    [ "$cfg_verbose" = true ] && debug_line="debug"

    cat > "$caddyfile" <<CADDYFILE
{
	${debug_line}
	http_port ${new_http_port}
	https_port ${new_https_port}
	${auto_https_line}
	order forward_proxy before file_server
}
:${new_https_port}, ${orig_host} {
	tls ${cfg_cert_file} ${cfg_cert_key}
	route {
		# proxy
		forward_proxy {
			basic_auth ${new_user} ${new_pass}
			hide_ip
			hide_via
			probe_resistance
		}

		# 伪装网址
		reverse_proxy ${new_fake_host} {
			header_up Host {upstream_hostport}
		}
	}
}
CADDYFILE

    # 如果端口变了，需要重建容器（host 网络模式下端口由 Caddy 内部监听，不需要重建）
    # 只需重启容器让 Caddy 重新加载配置
    say "重启容器使配置生效..."
    docker restart "$CONTAINER_NAME" 2>&1

    sleep 2
    if is_running; then
        ok "配置已更新并生效"
        say ""
        say "  新的客户端连接信息:"
        say "    naive+https://${new_user}:${new_pass}@${orig_host}:${new_https_port}#naive"
    else
        err "容器启动失败，查看日志:"
        docker logs --tail=20 "$CONTAINER_NAME" 2>&1
        exit 1
    fi

    exit 0
}

# ================================================================
#  部署模式
# ================================================================
do_install() {
    # ---- 前置检查 ----
    say "检查运行环境..."
    has_cmd "docker" || die "未找到 docker，请先安装"
    docker --version >&3
    if is_bt; then
        ok "检测到宝塔面板环境"
    else
        warn "未检测到宝塔面板，部分默认值将使用通用配置"
    fi

    # ---- 交互式输入 ----
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  NaiveProxy Docker 交互式部署"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say ""
    say "  提示: 直接回车使用 [默认值]"
    say ""

    # ---- 域名 ----
    if [ -z "${cfg_host:-}" ]; then
        if is_bt; then
            # 列出宝塔已有证书的域名供参考
            local cert_domains
            cert_domains=$(ls "$BT_CERT_BASE" 2>/dev/null | grep '\.' || true)
            if [ -n "$cert_domains" ]; then
                say "  宝塔已有证书的域名:"
                echo "$cert_domains" | while read -r line; do say "    - $line"; done
            fi
        fi
        read -rp "  请输入绑定域名: " cfg_host
    fi
    [ -n "${cfg_host:-}" ] || die "域名不能为空"
    ok "域名: $cfg_host"

    # ---- 安装目录 ----
    local default_dir
    if is_bt; then
        default_dir="$BT_SITE_BASE/$cfg_host/naiveproxy"
    else
        default_dir="/root/naiveproxy"
    fi
    if [ -z "${cfg_install_dir:-}" ]; then
        read -rp "  安装目录 [$default_dir]: " cfg_install_dir
        cfg_install_dir="${cfg_install_dir:-$default_dir}"
    fi
    ok "安装目录: $cfg_install_dir"

    # ---- 证书 ----
    local bt_cert_dir="$BT_CERT_BASE/$cfg_host"
    local default_cert="$bt_cert_dir/fullchain.pem"
    local default_key="$bt_cert_dir/privkey.pem"

    if [ -z "${cfg_cert_file:-}" ]; then
        if [ -f "$default_cert" ]; then
            read -rp "  证书文件 [$default_cert]: " cfg_cert_file
            cfg_cert_file="${cfg_cert_file:-$default_cert}"
        else
            read -rp "  证书文件路径 (fullchain.pem): " cfg_cert_file
        fi
    fi
    if [ -z "${cfg_cert_key:-}" ]; then
        if [ -f "$default_key" ]; then
            read -rp "  私钥文件 [$default_key]: " cfg_cert_key
            cfg_cert_key="${cfg_cert_key:-$default_key}"
        else
            read -rp "  私钥文件路径 (privkey.pem): " cfg_cert_key
        fi
    fi
    [[ "$cfg_cert_file" == /* ]] || die "证书路径必须为绝对路径"
    [[ "$cfg_cert_key" == /* ]]  || die "私钥路径必须为绝对路径"
    [ -f "$cfg_cert_file" ] || die "证书文件不存在: $cfg_cert_file"
    [ -f "$cfg_cert_key" ]  || die "私钥文件不存在: $cfg_cert_key"
    ok "证书: $cfg_cert_file"
    ok "私钥: $cfg_cert_key"

    # ---- HTTP 端口 ----
    if [ -z "${cfg_http_port:-}" ]; then
        read -rp "  HTTP 端口 [80]: " cfg_http_port
        cfg_http_port="${cfg_http_port:-80}"
    fi

    # ---- HTTPS 端口 ----
    if [ -z "${cfg_https_port:-}" ]; then
        read -rp "  HTTPS 端口 [443]: " cfg_https_port
        cfg_https_port="${cfg_https_port:-443}"
    fi
    ok "端口: HTTP=$cfg_http_port  HTTPS=$cfg_https_port"

    # ---- 用户名 ----
    local default_user
    default_user=$(gen_username)
    if [ -z "${cfg_user:-}" ]; then
        read -rp "  代理用户名 [$default_user]: " cfg_user
        cfg_user="${cfg_user:-$default_user}"
    fi
    ok "用户名: $cfg_user"

    # ---- 密码 ----
    local default_pass
    default_pass=$(gen_password)
    if [ -z "${cfg_pass:-}" ]; then
        read -rp "  代理密码 [$default_pass]: " cfg_pass
        cfg_pass="${cfg_pass:-$default_pass}"
    fi
    ok "密码: $cfg_pass"

    # ---- 伪装站 ----
    local default_fake
    if [ -z "${cfg_fake_host:-}" ] && is_bt; then
        default_fake=$(find_bt_fake_host "$cfg_host")
    else
        default_fake="${cfg_fake_host:-${FAKE_HOSTS[$(( RANDOM % ${#FAKE_HOSTS[@]} ))]}}"
    fi
    if [ -z "${cfg_fake_host:-}" ]; then
        read -rp "  伪装站点 [$default_fake]: " cfg_fake_host
        cfg_fake_host="${cfg_fake_host:-$default_fake}"
    fi
    ok "伪装站: $cfg_fake_host"

    # ---- 配置确认 ----
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  配置确认"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "  域名:       $cfg_host"
    say "  安装目录:   $cfg_install_dir"
    say "  证书:       $cfg_cert_file"
    say "  私钥:       $cfg_cert_key"
    say "  HTTP 端口:  $cfg_http_port"
    say "  HTTPS 端口: $cfg_https_port"
    say "  用户名:     $cfg_user"
    say "  密码:       $cfg_pass"
    say "  伪装站:     $cfg_fake_host"
    say "  调试模式:   $cfg_verbose"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say ""

    if [ "$cfg_auto_confirm" != true ]; then
        read -rp "  确认以上配置？(Y/n): " confirm
        confirm="${confirm:-Y}"
        [[ "${confirm,,}" == "n" ]] && die "已取消"
    fi

    # ---- 停止旧容器 ----
    if exists; then
        warn "检测到已有的 $CONTAINER_NAME 容器，将替换"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm   "$CONTAINER_NAME" 2>/dev/null || true
    fi

    # ---- 创建安装目录 ----
    say "创建安装目录: $cfg_install_dir"
    mkdir -p "$cfg_install_dir/data"
    mkdir -p "$cfg_install_dir/share"
    cd "$cfg_install_dir"

    # ---- 生成 entry.sh ----
    say "生成配置文件..."
    cat > ./data/entry.sh <<'ENTRY'
#!/bin/bash
set -e

# 不要使用 caddy fmt --overwrite，它会截断 basic_auth 密码字段
# Caddyfile 已由 install.sh 预格式化

echo "Start NaiveProxy"
/app/caddy start --config /data/Caddyfile

tail -f -n 50 /data/Caddyfile
ENTRY
    chmod +x ./data/entry.sh

    # ---- 生成 Caddyfile ----
    local debug_line=""
    [ "$cfg_verbose" = true ] && debug_line="debug"

    cat > ./data/Caddyfile <<CADDYFILE
{
	${debug_line}
	http_port ${cfg_http_port}
	https_port ${cfg_https_port}
	auto_https off
	order forward_proxy before file_server
}
:${cfg_https_port}, ${cfg_host} {
	tls ${cfg_cert_file} ${cfg_cert_key}
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

    # ---- 生成 docker-compose.yml ----
    cat > ./docker-compose.yml <<COMPOSE
version: '3.4'

services:
  naive:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
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

    ok "配置文件已生成"

    # ---- 启动容器 ----
    say "拉取镜像并启动容器..."
    if docker compose version >/dev/null 2>&1; then
        docker compose up -d
    elif docker-compose version >/dev/null 2>&1; then
        docker-compose up -d
    else
        docker run -d --network=host --name "$CONTAINER_NAME" \
            --restart=unless-stopped \
            -v "$PWD/data:/data" \
            -v "$PWD/share:/root/.local/share" \
            -v "$cfg_cert_file:$cfg_cert_file:ro" \
            -v "$cfg_cert_key:$cfg_cert_key:ro" \
            "$IMAGE" \
            /bin/bash /data/entry.sh
    fi

    # ---- 等待 & 验证 ----
    say "等待容器启动..."
    sleep 3

    if is_running; then
        ok "容器启动成功！"
        say ""
        say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        say "  ${G:-}部署完成${N:-}"
        say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        say ""
        say "  浏览器访问验证伪装站点:"
        info "https://${cfg_host}:${cfg_https_port}"
        say ""
        say "  客户端连接信息:"
        info "naive+https://${cfg_user}:${cfg_pass}@${cfg_host}:${cfg_https_port}#naive"
        say ""
        say "  管理命令:"
        say "    查看日志:  docker logs -f $CONTAINER_NAME"
        say "    重启:      docker restart $CONTAINER_NAME"
        say "    修改配置:  bash $(basename "$0") --modify"
        say "    更新镜像:  cd $cfg_install_dir && docker compose pull && docker compose up -d"
        say "    卸载:      bash $(basename "$0") --uninstall"
        say ""
        say "  文件位置:"
        say "    Caddyfile: $cfg_install_dir/data/Caddyfile"
        say "    Compose:   $cfg_install_dir/docker-compose.yml"
        say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        err "容器启动失败，查看日志:"
        docker logs --tail=30 "$CONTAINER_NAME" 2>&1
        exit 1
    fi
}

# ================================================================
#  主入口
# ================================================================
case "$cfg_mode" in
    uninstall) do_uninstall ;;
    modify)    do_modify ;;
    install)   do_install ;;
    *)         die "未知模式: $cfg_mode" ;;
esac
