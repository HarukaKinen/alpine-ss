# Alpine SS

纯 AI 写的，反正脚本这玩意能用就行。

面向 **Alpine Linux + OpenRC** 的 Shadowsocks-rust 一键脚本。

网上多数 SS 脚本只测过 Debian / `systemctl`，在 Alpine 上不是服务名不对，就是 pid 写成空的、菜单重启无效。这个脚本只做一件事：装官方仓库的 `shadowsocks-rust`，写好 `/etc/init.d/ss`。

适合同区域转发、多台 Alpine 当出口。不过墙，不装插件。

## 一键安装

```sh
wget -qO /tmp/alpine-ss.sh https://raw.githubusercontent.com/HarukaKinen/alpine-ss/master/alpine-ss.sh
sh /tmp/alpine-ss.sh
```

没有 wget 时：

```sh
apk add --no-cache curl
curl -fsSL https://raw.githubusercontent.com/HarukaKinen/alpine-ss/master/alpine-ss.sh -o /tmp/alpine-ss.sh
sh /tmp/alpine-ss.sh
```

不要用 `wget -qO- ... | sh` 直接管道跑：脚本要从 stdin 读菜单选择，管道会占掉 stdin，导致「选择」直接读空、报「无效选择」。下载到文件再执行就没这问题。

需要 root。脚本会问端口（默认 8888）和加密，密码自动生成。

## 会做什么

```shell
======== Alpine SS (shadowsocks-rust) ========

  1)  安装
  2)  卸载
  3)  重启
  4)  停止
  5)  查看配置
  6)  改端口/加密（密码会重生成）
  0)  退出
```

- 写入 community 源（没有的话）
- `apk add shadowsocks-rust`
- 生成 `/etc/shadowsocks/config.json`
- 写入 OpenRC：`/etc/init.d/ss`，pid 为 `/run/ss.pid`
- `rc-update add ss default` 并启动

菜单：安装 / 卸载 / 重启 / 停止 / 查看配置 / 改端口和加密（密码会重生成）。

装好以后：

```sh
rc-service ss start
rc-service ss stop
rc-service ss restart
rc-service ss status
```

不用 `systemctl`。

## 加密怎么选

作者没有过墙需求，所以加密纯按 CPU 性能选：

| 机器                     | 选                        |
| ------------------------ | ------------------------- |
| x86_64（大部分小鸡）     | `aes-256-gcm`（默认）     |
| ARM / 无 AES-NI          | `chacha20-ietf-poly1305`  |
| 客户端支持 SS2022 时可选 | `2022-blake3-aes-256-gcm` |

客户端加密名用脚本打印的，例如 `aes-256-gcm`，不要写成 `AEAD_AES_256_GCM`（我们是 Rust 不是 Go 那套）。

## UDP

服务端默认 `tcp_and_udp`。入站 UDP 被云厂商丢掉时，TCP 仍然可用。

客户端默认按 TCP 用即可，不必加 `udp: true`。只有确认对端 UDP 通了（例如区域机 `nc -nzu -w 3 IP PORT`），再在那一条节点上开 UDP。

## 要求

- Alpine（有 `/etc/alpine-release`）
- OpenRC
- root
- 能访问 `dl-cdn.alpinelinux.org`（装包）
