# NaiveProxy Docker

> 基于 Docker 的 NaiveProxy 一键部署方案，支持宝塔面板深度集成

基于 [jiasongji/naiveproxy-docker](https://hub.docker.com/r/jiasongji/naiveproxy-docker) 镜像，内建 Caddy + forward_proxy 插件。

## 目录

- [功能特性](#功能特性)
- [工作原理](#工作原理)
- [前置要求](#前置要求)
- [快速开始](#快速开始)
  - [交互式部署](#交互式部署)
  - [非交互式部署](#非交互式部署)
  - [使用宝塔面板证书](#使用宝塔面板证书)
- [管理命令](#管理命令)
  - [修改配置](#修改配置)
  - [更新镜像](#更新镜像)
  - [查看日志](#查看日志)
  - [卸载](#卸载)
- [参数说明](#参数说明)
- [客户端连接](#客户端连接)
- [自定义 Caddyfile](#自定义-caddyfile)
- [常见问题](#常见问题)
- [版本历史](#版本历史)

---

## 功能特性

- **三种模式**：部署 / 修改配置 / 卸载
- **宝塔集成**：自动检测宝塔面板证书和站点目录
- **智能默认值**：所有配置项均可回车使用默认值
  - 安装目录：`/www/wwwroot/<域名>/naiveproxy`（宝塔环境）
  - 证书：自动定位 `/www/server/panel/vhost/cert/<域名>/`
  - 用户名/密码：随机生成
  - 伪装站：从候选列表中随机选择，或自动检测宝塔站点
- **热修改**：在线修改端口、账号、密码、反代地址，改完即生效
- **一键卸载**：清理容器和数据目录

## 工作原理

NaiveProxy 由客户端和服务端组成，本项目部署的是服务端。

服务端本质是带 [forward_proxy](https://github.com/klzgrad/forwardproxy) 插件的 Caddy。当请求到达时：

1. **认证通过** → 走代理隧道，实现科学上网
2. **认证失败 / 无认证** → `probe_resistance` 静默丢弃请求，转发到伪装站点

效果：浏览器访问看到的是一个正常网站，只有客户端才知道它是代理。

```
客户端请求 ──→ Caddy (NaiveProxy)
                ├─ 认证通过 → 代理隧道 → 目标网站
                └─ 无认证   → 伪装站点（看起来是普通网站）
```

## 前置要求

| 要求 | 说明 |
|------|------|
| 域名 | 已解析到服务器 IP |
| Docker | 已安装 Docker 和 Docker Compose |
| 端口 | 如果自备证书，HTTPS 端口需开放；如果自动申请证书，80 和 443 端口需开放 |
| 证书（可选） | 如有宝塔面板或已持有 SSL 证书可直接使用；否则 Caddy 可自动申请 |

---

## 快速开始

### 交互式部署

最简单的方式——运行脚本，按提示输入（直接回车使用默认值）：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh)
```

脚本会依次询问：

```
  请输入绑定域名: proxy.example.com
  安装目录 [/www/wwwroot/proxy.example.com/naiveproxy]: ← 回车
  证书文件 [/www/server/panel/vhost/cert/proxy.example.com/fullchain.pem]: ← 回车
  私钥文件 [/www/server/panel/vhost/cert/proxy.example.com/privkey.pem]: ← 回车
  HTTP 端口 [80]: ← 回车
  HTTPS 端口 [443]: ← 回车
  代理用户名 [npa3x9fk]: ← 回车（或输入自定义用户名）
  代理密码 [R4m8kX2pN9vL3qH7]: ← 回车（或输入自定义密码）
  伪装站点 [https://demo.cloudreve.org]: ← 回车
```

部署完成后会输出客户端连接信息：

```
  ✓ 容器启动成功！

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    部署完成
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    客户端连接信息:
      naive+https://npa3x9fk:R4m8kX2pN9vL3qH7@proxy.example.com:443#naive
```

### 非交互式部署

通过命令行参数指定全部配置，加上 `--yes` 跳过确认，适合脚本化部署：

```bash
curl -sSL -o ./install.sh https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh \
&& chmod +x ./install.sh \
&& ./install.sh \
  -t proxy.example.com \
  -u myuser \
  -p MyPassword123 \
  --yes
```

> 不指定证书路径时，脚本会自动检测宝塔证书目录，或提示手动输入。

### 使用宝塔面板证书

如果你的服务器安装了宝塔面板，且已在面板中为域名申请了 SSL 证书，直接运行即可——脚本会自动检测证书路径：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh)
```

也可以显式指定证书路径：

```bash
./install.sh \
  -t proxy.example.com \
  -c /www/server/panel/vhost/cert/proxy.example.com/fullchain.pem \
  -k /www/server/panel/vhost/cert/proxy.example.com/privkey.pem \
  -w 80 -s 443 \
  -u myuser -p MyPassword123 \
  -d /www/wwwroot/proxy.example.com/naiveproxy \
  --yes
```

---

## 管理命令

### 修改配置

交互式修改端口、用户名、密码、伪装站点，改完自动重启生效：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --modify
```

运行效果：

```
  当前配置:
    域名:       proxy.example.com
    HTTPS 端口: 443
    用户名:     myuser
    密码:       MyPassword123
    伪装站:     https://demo.cloudreve.org

  直接回车保持当前值，输入新值则修改

  HTTPS 端口 [443]: 8443
  用户名 [myuser]:
  密码 [MyPassword123]: NewPass456
  伪装站点 [https://demo.cloudreve.org]:

  ✓ 配置已更新并生效
```

### 更新镜像

```bash
cd /www/wwwroot/proxy.example.com/naiveproxy \
&& docker compose pull \
&& docker compose up -d
```

### 查看日志

```bash
# 实时跟踪
docker logs -f naiveproxy

# 查看最近 100 行
docker logs --tail=100 naiveproxy
```

### 卸载

完全移除容器和数据：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --uninstall
```

---

## 参数说明

```
./install.sh [选项]

部署选项:
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

管理模式:
  --modify                     修改已有配置
  --uninstall                  卸载并清理
```

---

## 客户端连接

部署完成后，使用输出的连接信息在客户端配置：

```
naive+https://用户名:密码@域名:HTTPS端口#naive
```

### 支持的客户端

| 平台 | 客户端 |
|:----:|:------:|
| Windows | V2RayN / NekoRay |
| Linux | NekoRay |
| macOS | NekoRay |
| Android | SagerNet / NekoBox |
| iOS | Shadowrocket |

以 V2RayN 为例：

1. 服务器 → 添加 [NaiveProxy] 服务器
2. 填入地址（域名）、端口、用户名、密码
3. 网络传输协议选择 `naive`
4. 连接测试

---

## 自定义 Caddyfile

Caddyfile 位于安装目录下的 `data/Caddyfile`，可直接编辑：

```bash
vim /www/wwwroot/proxy.example.com/naiveproxy/data/Caddyfile
```

修改后重载配置：

```bash
docker exec naiveproxy /app/caddy reload --config /data/Caddyfile
```

### 多用户示例

添加多个 `forward_proxy` 块实现多用户：

```
{
	http_port 80
	https_port 443
	auto_https off
	order forward_proxy before file_server
}
:443, proxy.example.com {
	tls /path/to/fullchain.pem /path/to/privkey.pem
	route {
		forward_proxy {
			basic_auth user1 password1
			hide_ip
			hide_via
			probe_resistance
		}
		forward_proxy {
			basic_auth user2 password2
			hide_ip
			hide_via
			probe_resistance
		}

		reverse_proxy https://demo.cloudreve.org {
			header_up Host {upstream_hostport}
		}
	}
}
```

> ⚠️ 注意：不要使用 `caddy fmt --overwrite` 格式化 Caddyfile，它会截断 `basic_auth` 中的密码字段。

> ⚠️ 注意：端口必须写在域名前面，即 `:443, proxy.example.com`，反过来会报错。

---

## 常见问题

### 部署后浏览器访问域名看不到伪装站点？

检查 HTTPS 端口是否在防火墙/安全组中放行。

### 自动申请证书失败？

自动申请需要 80 端口开放且未被占用。检查：
1. 80 端口是否被 Nginx/Apache 占用：`ss -tlnp | grep :80`
2. 域名是否正确解析到服务器 IP：`dig your-domain.com`

如果 80 端口被占用，建议在宝塔面板申请证书后使用「使用现有证书」模式。

### 如何更换端口？

使用修改模式：
```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --modify
```
输入新的 HTTPS 端口，回车跳过其他选项即可。

### 容器启动后日志报 ACME 错误？

这是 Caddy 尝试自动获取证书。如果你已经使用了自有证书，可以忽略——脚本已设置 `auto_https off` 来禁用此行为。

---

## 版本历史

详见 [CHANGELOG.md](CHANGELOG.md)。

### v2.0

- 全新交互式管理脚本，支持部署/修改/卸载三种模式
- 宝塔面板深度集成（自动检测证书、站点目录、伪装站）
- 所有配置项支持智能默认值（回车即用）
- 用户名/密码自动生成
- 修复 `caddy fmt` 截断密码、docker-compose 证书卷格式错误、ACME 无限重试等 BUG
