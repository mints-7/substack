#!/usr/bin/env bash
#
# substack —— 一键搭一套自己的订阅转换服务（subconverter + sub-web）
#
# 用法：
#   bash install.sh                                  # 只跑容器，前端监听 0.0.0.0:58080
#   bash install.sh --domain sub.example.com --email you@example.com
#                                                    # 反代到域名并签 HTTPS
#   bash install.sh --uninstall                      # 卸载容器和 nginx 配置
#
# 一键（不用先下载）：
#   curl -fsSL https://raw.githubusercontent.com/mints-7/substack/main/install.sh | sudo bash -s -- --domain sub.example.com --email you@example.com
#
# 脚本只做四件事：装 Docker（缺才装）、写配置、起两个容器、可选配 Nginx + 证书。
# 不想用脚本的，照着博客里的步骤手敲一遍也一样。

set -euo pipefail

DIR="${SUBSTACK_DIR:-/opt/substack}"
IMG_BACKEND="tindy2013/subconverter:latest"
IMG_FRONT="careywong/subweb:latest"
BACKEND_PORT=25500
FRONT_PORT=58080

DOMAIN=""
EMAIL=""
MIRROR=""
WITH_NGINX=1
UNINSTALL=0
DRY_RUN=0

c_reset=$'\033[0m'; c_purple=$'\033[1;35m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_grey=$'\033[2m'
info() { printf '%s==>%s %s\n' "$c_purple" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '%s[试运行]%s %s\n' "$c_grey" "$c_reset" "$*"; else eval "$*"; fi; }

usage() {
  cat <<'EOF'
substack 安装脚本

参数：
  --domain <域名>   配 Nginx 反代并申请 HTTPS 证书（需要域名已解析到本机）
  --email <邮箱>    证书到期通知邮箱，配合 --domain 使用
  --no-nginx        跳过 Nginx，前端直接监听 0.0.0.0:58080
  --mirror <地址>   指定 Docker 镜像加速地址（拉不动镜像时用）
  --uninstall       停掉并删除容器（加 --purge 连 /opt/substack 一起删）
  --purge           卸载时删除配置目录
  --dry-run         只打印会执行什么，不动系统
  -h, --help        看这段说明

环境变量：
  SUBSTACK_DIR      配置目录，默认 /opt/substack
EOF
}

PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)    DOMAIN="${2:-}"; shift 2 ;;
    --email)     EMAIL="${2:-}";  shift 2 ;;
    --no-nginx)  WITH_NGINX=0; shift ;;
    --mirror)    MIRROR="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)     PURGE=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "不认识的参数：$1（用 --help 看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，用 sudo 再跑一次"
[ -r /etc/os-release ] && . /etc/os-release || die "读不到 /etc/os-release，这脚本只支持 Debian/Ubuntu 系"

command -v apt-get >/dev/null || die "没找到 apt-get，这脚本只支持 Debian/Ubuntu 系"

# ---------- 卸载 ----------
if [ "$UNINSTALL" = 1 ]; then
  info "停掉并删除容器"
  for name in subconverter subweb; do
    if command -v docker >/dev/null && docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      run "docker rm -f $name"
    fi
  done

  if [ -L /etc/nginx/sites-enabled/substack.conf ] || [ -f /etc/nginx/sites-enabled/substack.conf ]; then
    info "移除 Nginx 配置"
    run "rm -f /etc/nginx/sites-enabled/substack.conf /etc/nginx/sites-available/substack.conf"
    run "rm -f /etc/nginx/conf.d/substack-limit.conf"
    if command -v nginx >/dev/null; then
      run "nginx -t && systemctl reload nginx || true"
    fi
  fi

  if [ "$PURGE" = 1 ]; then
    info "删除配置目录 $DIR"
    run "rm -rf '$DIR'"
  else
    warn "配置留在 $DIR（里面有你生成的 token），要一起删就加 --purge"
  fi
  info "卸载完成。证书还留在 /etc/letsencrypt，想删自己跑 certbot delete"
  exit 0
fi

# ---------- 1. 基础依赖 ----------
info "检查基础依赖"
if ! command -v curl >/dev/null; then
  run "apt-get update -qq && apt-get install -y -qq curl ca-certificates"
fi

# ---------- 2. Docker ----------
if command -v docker >/dev/null 2>&1; then
  info "已有 Docker：$(docker --version | awk '{print $3}' | tr -d ,)"
else
  info "没装 Docker，开始安装"
  if [ "$DRY_RUN" = 1 ]; then
    run "（试运行）安装 docker"
  else
    # 官方源优先，codename 还没进官方源时退回发行版自带的 docker.io
    codename="${VERSION_CODENAME:-}"
    ok=0
    if [ -n "$codename" ]; then
      if curl -fsSL -o /dev/null -w '%{http_code}' "https://download.docker.com/linux/debian/dists/${codename}/Release" | grep -q 200; then
        info "用 Docker 官方源（${codename}）"
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io
        ok=1
      fi
    fi

    if [ "$ok" = 0 ]; then
      warn "官方源没有这个发行版，改用系统自带的 docker.io"
      apt-get update -qq
      apt-get install -y -qq docker.io
    fi

    systemctl enable --now docker
  fi
fi

if [ "$DRY_RUN" = 0 ]; then
  docker info >/dev/null 2>&1 || die "Docker 装好了但起不来，跑 systemctl status docker 看看"
fi

# ---------- 3. 配置 ----------
info "准备配置目录 $DIR"
run "mkdir -p '$DIR'"

if [ -f "$DIR/pref.ini" ]; then
  info "发现已有的 pref.ini，沿用里面的 token"
  TOKEN="$(grep -E '^api_access_token=' "$DIR/pref.ini" | head -1 | cut -d= -f2- || true)"
  [ -n "${TOKEN:-}" ] || TOKEN="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
else
  TOKEN="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  info "生成新配置（token 会打印在最后）"
  if [ "$DRY_RUN" = 0 ]; then
    cat > "$DIR/pref.ini" <<EOF
[common]
api_mode=true
api_access_token=${TOKEN}
enable_cache=true
cache_subscription=300
cache_config=3600
exclude_remarks=(到期|剩余流量|官网|订阅|过期)
log_level=info

[server]
listen=0.0.0.0
port=25500

[advanced]
max_pending_connections=200
max_concurrent_threads=4
enable_cache=true
EOF
    chmod 600 "$DIR/pref.ini"
  fi
fi

# ---------- 3.5 拉镜像（国内直连 Docker Hub 常常超时） ----------
DEFAULT_MIRRORS=("https://docker.1panel.live" "https://docker.xuanyuan.me" "https://docker.1ms.run")

write_mirrors() {
  local cfg=/etc/docker/daemon.json
  if [ -f "$cfg" ]; then
    warn "$cfg 已存在，我不动它。拉不动镜像的话，自己把 registry-mirrors 加进去再重启 docker"
    return 1
  fi
  local list="$1"
  cat > "$cfg" <<EOF
{
  "registry-mirrors": [${list}]
}
EOF
  info "已写入镜像加速配置，重启 docker"
  systemctl restart docker
  for i in $(seq 1 20); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  warn "docker 重启后没起来"
  return 1
}

ensure_image() {
  local img="$1"
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s[试运行]%s docker pull %s\n' "$c_grey" "$c_reset" "$img"
    return 0
  fi
  docker image inspect "$img" >/dev/null 2>&1 && return 0

  # 已经配过加速器，直接走它，别再去撞 Docker Hub 的超时
  if grep -qs 'registry-mirrors' /etc/docker/daemon.json; then
    info "拉取镜像 $img（走已配置的加速器）"
    timeout 300 docker pull -q "$img" >/dev/null 2>&1 && return 0
    die "镜像拉不下来。检查 /etc/docker/daemon.json 里的 registry-mirrors 是否还有效"
  fi

  info "拉取镜像 $img"
  if timeout 90 docker pull -q "$img" >/dev/null 2>&1; then return 0; fi

  warn "直连 Docker Hub 超时，换镜像加速再试一次"
  if [ -n "$MIRROR" ]; then
    write_mirrors "\"${MIRROR}\"" || true
  else
    local list="" m
    for m in "${DEFAULT_MIRRORS[@]}"; do list="${list:+$list, }\"$m\""; done
    write_mirrors "$list" || true
  fi

  timeout 300 docker pull -q "$img" >/dev/null 2>&1 && return 0
  die "镜像拉不下来。换一个能用的加速地址重试：bash install.sh --mirror https://你的加速地址"
}

# ---------- 4. 容器 ----------
# 有 Nginx 时前后端都只绑回环，靠反代出去；没有 Nginx 时浏览器要直连后端，只能绑 0.0.0.0
if [ "$WITH_NGINX" = 1 ] && [ -n "$DOMAIN" ]; then
  FRONT_BIND="127.0.0.1"
  BACKEND_BIND="127.0.0.1"
  PUBLIC_URL="https://${DOMAIN}"
  BACKEND_URL="https://${DOMAIN}"
else
  FRONT_BIND="0.0.0.0"
  BACKEND_BIND="0.0.0.0"
  PUBLIC_URL=""
  BACKEND_URL=""
  [ -n "$DOMAIN" ] && warn "给了域名但没配 Nginx，前后端只能靠 IP 访问"
fi

# 没配域名时，公网地址得等安装完拿到 IP 再拼
if [ -z "$PUBLIC_URL" ]; then
  TMP_IP="$(curl -fsS -m 4 https://ipinfo.io/ip 2>/dev/null || curl -fsS -m 4 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$TMP_IP" ] || TMP_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_URL="http://${TMP_IP}:${FRONT_PORT}"
  BACKEND_URL="http://${TMP_IP}:${BACKEND_PORT}"
fi

ensure_image "$IMG_BACKEND"
ensure_image "$IMG_FRONT"

info "启动后端 subconverter"
run "docker rm -f subconverter >/dev/null 2>&1 || true"
run "docker run -d --name subconverter --restart always \
  -p ${BACKEND_BIND}:${BACKEND_PORT}:25500 \
  -v '$DIR/pref.ini:/base/pref.ini:ro' \
  $IMG_BACKEND"

info "启动前端 sub-web"
run "docker rm -f subweb >/dev/null 2>&1 || true"
run "docker run -d --name subweb --restart always \
  -p ${FRONT_BIND}:${FRONT_PORT}:80 \
  -e VITE_SUBCONVERTER_DEFAULT_BACKEND=${BACKEND_URL} \
  $IMG_FRONT"

# ---------- 5. 等后端起来 ----------
if [ "$DRY_RUN" = 0 ]; then
  info "等后端就绪"
  for i in $(seq 1 30); do
    if curl -fsS -m 2 "http://127.0.0.1:${BACKEND_PORT}/version" >/dev/null 2>&1; then
      info "后端已就绪：$(curl -fsS -m 2 "http://127.0.0.1:${BACKEND_PORT}/version")"
      break
    fi
    [ "$i" = 30 ] && die "后端 30 秒没起来，看日志：docker logs --tail 50 subconverter"
    sleep 1
  done
fi

# ---------- 6. Nginx + HTTPS ----------
if [ "$WITH_NGINX" = 1 ] && [ -n "$DOMAIN" ]; then
  info "配置 Nginx 反代 ${DOMAIN}"
  if ! command -v nginx >/dev/null; then
    run "apt-get install -y -qq nginx"
  fi

  if [ "$DRY_RUN" = 0 ]; then
    cat > /etc/nginx/conf.d/substack-limit.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=substack:10m rate=2r/s;
EOF

    cat > /etc/nginx/sites-available/substack.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 2m;

    location / {
        proxy_pass http://127.0.0.1:${FRONT_PORT};
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /sub {
        limit_req zone=substack burst=20 nodelay;
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_read_timeout 30s;
        add_header Cache-Control "no-store";
    }

    location = /version {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
    }
}
EOF
    ln -sf /etc/nginx/sites-available/substack.conf /etc/nginx/sites-enabled/substack.conf
    # 默认站点会抢 80，先让位
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || die "Nginx 配置检查没过，看上面报错"
    systemctl reload nginx
    info "Nginx 已生效"
  else
    run "（试运行）写 Nginx 配置并 reload"
  fi

  if [ -n "$EMAIL" ]; then
    info "申请 HTTPS 证书"
    if ! command -v certbot >/dev/null; then
      run "apt-get install -y -qq certbot python3-certbot-nginx"
    fi
    run "certbot --nginx -d '${DOMAIN}' --agree-tos -m '${EMAIL}' --non-interactive --redirect || \
      echo '证书申请失败：确认域名解析到本机、80 端口放行、重复跑一次即可'"
  else
    warn "没给 --email，跳过证书。想补就跑：certbot --nginx -d ${DOMAIN}"
  fi
fi

# ---------- 7. 收尾 ----------
IP="$(curl -fsS -m 4 https://ipinfo.io/ip 2>/dev/null || curl -fsS -m 4 https://api.ipify.org 2>/dev/null || true)"
[ -n "$IP" ] || IP="$(hostname -I | awk '{print $1}')"

cat <<EOF

$(printf '%s' "$c_purple")装好了$(printf '%s' "$c_reset")

  前端      ${PUBLIC_URL}
  后端      ${BACKEND_URL}   （${BACKEND_BIND}）
  配置      ${DIR}/pref.ini
  api token ${TOKEN}

下一步：
  1. 打开前端页面，把「后端地址」填 ${BACKEND_URL}
  2. 粘一条机场订阅，生成 Clash 链接，导入客户端试一次
  3. 想看日志：docker logs -f subconverter

别做的事：
  · 没配域名时前后端都挂在公网 IP 上，记得在云厂商安全组里只放行自己的 IP，
    或者干脆加 --domain 走 Nginx，让后端缩回本机
  · 别把这个页面公开给一群陌生人用，流量和风险都是你自己的
  · 国内机器对外提供这类服务要先备案，自己掂量

卸载：bash install.sh --uninstall
EOF
