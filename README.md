# substack

一条命令把 [subconverter](https://github.com/tindy2013/subconverter) 和 [sub-web](https://github.com/CareyWang/sub-web) 装到自己的机器上，用自己的转换服务，不再把订阅链接交给公共站点。

```bash
curl -fsSL https://raw.githubusercontent.com/mints-7/substack/main/install.sh | sudo bash
```

跑完会打印一个地址，浏览器打开就是 sub-web 的界面。后端默认只绑 `127.0.0.1`，外网碰不到。

## 带域名和 HTTPS

域名先解析到这台机器，80/443 放行，然后：

```bash
curl -fsSL https://raw.githubusercontent.com/mints-7/substack/main/install.sh | sudo bash -s -- \
  --domain sub.example.com --email you@example.com
```

脚本会写 Nginx 反代（前端走 `/`，后端走 `/sub`，同域就不会有跨域问题），再用 certbot 签证书。装完直接访问 `https://sub.example.com`。

## 参数

| 参数 | 说明 |
| --- | --- |
| `--domain <域名>` | 配 Nginx 反代并申请证书 |
| `--email <邮箱>` | 证书到期通知邮箱 |
| `--no-nginx` | 不装 Nginx，前后端都绑公网 IP，靠端口访问 |
| `--mirror <地址>` | Docker 镜像加速地址（拉不动镜像时用） |
| `--uninstall` | 删容器和 Nginx 配置 |
| `--purge` | 卸载时连配置目录一起删 |
| `--dry-run` | 只打印会做什么，不动系统 |

环境变量 `SUBSTACK_DIR` 可以改配置目录，默认 `/opt/substack`。

## 它到底做了什么

1. 装 Docker（已经装了就直接用）
2. 在 `/opt/substack/pref.ini` 写一份配置，token 随机生成，文件权限 600
3. 起两个容器：后端 `subconverter`、前端 `subweb`
4. 给了域名就加 Nginx 反代和证书
5. 把访问地址、token、下一步打在屏幕上

重复执行没关系，会让容器按最新配置重建，`pref.ini` 里的 token 会沿用，不会每次都变。

## 国内机器需要注意

- **拉镜像大概率超时**。脚本会自动写一份 `/etc/docker/daemon.json` 用加速器重试一次；如果那个地址也失效了，自己找一个能用的，`--mirror` 传进去。
- **备案**：国内服务器上用域名对外提供服务要先备案，否则 80/443 会被拦。只是自己用、走 IP 访问问题不大。
- **别公开**。这套东西一旦挂出去，很快会被人当免费接口刷。脚本里已经做了三件事：后端只绑回环、生成 token、Nginx 层限流（2 r/s，突发 20）。

## 卸载

```bash
sudo bash install.sh --uninstall           # 删容器和反代配置，保留 /opt/substack
sudo bash install.sh --uninstall --purge   # 连配置一起删
```

证书和 `certbot` 不会自动删，想要干净的话自己跑 `certbot delete` 和 `apt remove docker.io`。

## 不用脚本

博客里有一份手敲版本的步骤，包括 pref.ini 每一项在干什么、Nginx 每个 block 为什么这么写：<https://github.com/mints-7/blog>

## 许可

MIT
