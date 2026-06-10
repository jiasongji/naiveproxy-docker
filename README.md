# NaiveProxy Docker

> 基于 Docker 的 NaiveProxy 一键部署方案，支持宝塔面板集成

[![Docker](https://img.shields.io/docker/v/jiasongji/naiveproxy-docker?label=Docker%20Hub)](https://hub.docker.com/r/jiasongji/naiveproxy-docker)

## 目录

- [功能特性](#功能特性)
- [工作原理](#工作原理)
- [前置要求](#前置要求)
- [快速开始](#快速开始)
  - [交互式部署（推荐）](#交互式部署推荐)
  - [非交互式部署](#非交互式部署)
- [管理命令](#管理命令)
  - [修改配置](#修改配置)
  - [更新镜像](#更新镜像)
  - [查看日志](#查看日志)
  - [卸载](#卸载)
- [参数说明](#参数说明)
- [客户端连接](#客户端连接)
- [自定义 Caddyfile](#自定义-caddyfile)
- [常见问题](#常见问题)

---

## 功能特性

- **一键部署** — 运行脚本，全部配置回车即用默认值，脚本自动创建目录并生成配置
- **智能默认值** — 自动检测宝塔证书、随机生成高位端口 / 用户名 / 密码 / 伪装站
- **热修改** — 在线修改端口、账号、密码、反代地址，改完即生效
- **一键卸载** — 清理容器和数据目录
- **宝塔集成** — 自动检测证书路径和站点目录

## 工作原理

NaiveProxy 由客户端和服务端组成，本项目部署的是服务端。

服务端本质是带 [forward_proxy](https://github.com/klzgrad/forwardproxy) 插件的 Caddy。当请求到达时：

- **认证通过** → 走代理隧道
- **无认证** → `probe_resistance` 静默将请求转发到伪装站点

效果：浏览器访问看到的是一个正常网站，只有持有正确凭证的客户端才能使用代理。

## 前置要求

| 要求 | 说明 |
|------|------|
| 域名 | 已解析到服务器 IP |
| Docker | 已安装 Docker 和 Docker Compose |
| SSL 证书 | 推荐使用宝塔面板管理证书；脚本自动检测宝塔证书目录 |
| 开放端口 | HTTPS 端口需在防火墙 / 安全组放行 |

---

## 快速开始

### 交互式部署（推荐）

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh)
```

运行后按提示输入，**所有配置直接回车使用默认值**：

```
  请输入绑定域名: proxy.example.com
  安装目录 [/www/wwwroot/proxy.example.com/naiveproxy]:          ← 回车
  证书文件 [/www/.../fullchain.pem]:                              ← 回车（宝塔自动检测）
  私钥文件 [/www/.../privkey.pem]:                                ← 回车
  HTTPS 端口 [38291]:                                            ← 回车（随机高位端口）
  HTTP 端口 [38290]:                                             ← 回车
  代理用户名 [np******]:                                          ← 回车（随机生成）
  代理密码 [****************]:                                    ← 回车（随机生成）
  伪装站点 [https://demo.cloudreve.org]:                          ← 回车（随机选择）
```

> 脚本会自动创建安装目录、生成配置文件、拉取镜像并启动容器，无需手动准备任何文件。

部署完成后输出连接信息：

```
  ✓ 容器启动成功！

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    部署完成
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    客户端连接信息:
      naive+https://<用户名>:<密码>@proxy.example.com:38291#naive
```

### 非交互式部署

通过命令行参数指定配置，`--yes` 跳过确认。**至少需要指定域名和证书**，其余均有默认值（自动随机生成高位端口、用户名、密码、伪装站）：

```bash
curl -sSL -o /tmp/naive-install.sh https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh \
&& chmod +x /tmp/naive-install.sh \
&& /tmp/naive-install.sh \
  -t proxy.example.com \
  -c /www/server/panel/vhost/cert/proxy.example.com/fullchain.pem \
  -k /www/server/panel/vhost/cert/proxy.example.com/privkey.pem \
  --yes
```

> 脚本自动创建安装目录（默认 `/www/wwwroot/<域名>/naiveproxy`），无需手动 `mkdir`。

也可以指定全部参数：

```bash
curl -sSL -o /tmp/naive-install.sh https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh \
&& chmod +x /tmp/naive-install.sh \
&& /tmp/naive-install.sh \
  -t proxy.example.com \
  -c /www/server/panel/vhost/cert/proxy.example.com/fullchain.pem \
  -k /www/server/panel/vhost/cert/proxy.example.com/privkey.pem \
  -w 80 -s 443 \
  -u <用户名> -p <密码> \
  -f https://demo.cloudreve.org \
  -d /www/wwwroot/proxy.example.com/naiveproxy \
  --yes
```

---

## 管理命令

> 以下命令中的 `/www/wwwroot/proxy.example.com/naiveproxy` 为安装目录示例，请替换为实际路径。

### 修改配置

交互式修改端口、用户名、密码、伪装站点，改完自动重启生效：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --modify
```

运行后显示当前配置，直接回车保持不变，输入新值则修改：

```
  当前配置:
    HTTPS 端口: 38291
    用户名:     ...
    密码:       ...
    伪装站:     https://demo.cloudreve.org

  HTTPS 端口 [38291]:              ← 回车保持，或输入新端口
  用户名 [...]:                    ← 回车保持，或输入新用户名
  密码 [...]:                      ← 回车保持，或输入新密码
  伪装站点 [...]:                  ← 回车保持，或输入新地址

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

# 最近 100 行
docker logs --tail=100 naiveproxy
```

### 卸载

完全移除容器和数据目录：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --uninstall
```

---

## 参数说明

```
./install.sh [选项]

部署选项:
  -t, --host <HOST>            绑定域名（必填）
  -w, --http-port <PORT>       HTTP 端口（默认随机高位端口）
  -s, --https-port <PORT>      HTTPS 端口（默认随机高位端口）
  -u, --user <USER>            代理用户名（默认自动生成）
  -p, --pwd <PASS>             代理密码（默认自动生成）
  -f, --fake-host <URL>        伪装站点（随机选择）
  -c, --cert-file <PATH>       证书文件路径（默认宝塔证书）
  -k, --cert-key <PATH>        私钥文件路径（默认宝塔证书）
  -d, --install-dir <DIR>      安装目录（默认 /www/wwwroot/<域名>/naiveproxy）
  -y, --yes                    跳过确认，未提供的参数使用默认值
  -v, --verbose                调试模式
  -h, --help                   显示帮助

管理模式:
  --modify                     修改已有配置
  --uninstall                  卸载并清理
```

---

## 客户端连接

部署完成后，使用脚本输出的连接信息在客户端配置：

```
naive+https://<用户名>:<密码>@<域名>:<HTTPS端口>#naive
```

### 支持的客户端

| 平台 | 客户端 |
|:----:|:------:|
| Windows | V2RayN / NekoRay |
| Linux | NekoRay |
| macOS | NekoRay |
| Android | SagerNet / NekoBox |
| iOS | Shadowrocket |

---

## 自定义 Caddyfile

Caddyfile 位于安装目录下 `data/Caddyfile`，可直接编辑：

```bash
vim /www/wwwroot/proxy.example.com/naiveproxy/data/Caddyfile
```

编辑后重载：

```bash
docker exec naiveproxy /app/caddy reload --config /data/Caddyfile
```

### 多用户示例

添加多个 `forward_proxy` 块实现多用户：

```
:443, proxy.example.com {
	tls /path/to/fullchain.pem /path/to/privkey.pem
	route {
		forward_proxy {
			basic_auth <用户1> <密码1>
			hide_ip hide_via probe_resistance
		}
		forward_proxy {
			basic_auth <用户2> <密码2>
			hide_ip hide_via probe_resistance
		}
		reverse_proxy https://demo.cloudreve.org {
			header_up Host {upstream_hostport}
		}
	}
}
```

> **注意**：端口必须写在域名前面，即 `:443, proxy.example.com`，反过来会报错。

---

## 常见问题

### 浏览器访问域名看不到伪装站点？

HTTPS 端口需要在防火墙 / 安全组中放行。

### 自动申请证书失败？

自动申请需要 80 端口开放且未被占用。如果 80 端口被 Nginx 等占用，建议在宝塔面板申请证书后使用现有证书模式。

### 如何更换端口？

```bash
bash <(curl -sSL https://raw.githubusercontent.com/jiasongji/naiveproxy-docker/main/install.sh) --modify
```

输入新的 HTTPS 端口，其他项回车跳过即可。

### 容器日志报 ACME 错误？

脚本已设置 `auto_https off` 禁止 Caddy 自动获取证书。如果仍有报错，不影响代理功能，可以忽略。
