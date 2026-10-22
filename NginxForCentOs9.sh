#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Nginx + GeoIP2 install script for CentOS Stream 9 / RHEL9
# =========================

# 固定版本（你要求 1.30.6）
NGINX_VER="${NGINX_VER:-1.30.6}"
LIBMAXMINDDB_VER="${LIBMAXMINDDB_VER:-1.7.1}"

# 路徑
PREFIX_NGINX="/usr/local/nginx"
GEOIP2_DIR="/usr/local/Geoip2"
MODULE_SRC_DIR="/usr/local/src/ngx_http_geoip2_module"

# 若你要保留 SELinux，不要關閉：改成 0
DISABLE_SELINUX="${DISABLE_SELINUX:-1}"

# 若你要套用外部 nginx.conf，改成 1（需可連到該 repo）
USE_REMOTE_CONF="${USE_REMOTE_CONF:-1}"
REMOTE_CONF_REPO="https://github.com/Nick30806/Nginx-Geoip2.git"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

trap 'err "腳本在第 $LINENO 行失敗，請檢查上方訊息。"' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "請用 root 執行：sudo bash $0"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/redhat-release ]]; then
    err "此腳本僅支援 RHEL/CentOS 系列。"
    exit 1
  fi
  if ! grep -Eqi 'release (9|10)|stream' /etc/redhat-release; then
    warn "偵測到系統版本不是 CentOS/RHEL 9，仍嘗試繼續。"
  fi
}

install_build_deps() {
  log "安裝編譯工具與相依套件..."
  dnf -y makecache
  dnf -y groupinstall "Development Tools"
  dnf -y install \
    gcc gcc-c++ make libtool autoconf automake \
    zlib zlib-devel \
    pcre pcre-devel pcre2 pcre2-devel \
    openssl openssl-devel \
    wget curl tar xz unzip git \
    vim lrzsz \
    perl perl-devel perl-ExtUtils-Embed \
    libxml2-devel libxslt-devel gd-devel GeoIP-devel \
    ca-certificates firewalld
}

download_sources() {
  log "下載原始碼..."
  cd /usr/local/src
  wget -q --show-progress -O "nginx-${NGINX_VER}.tar.gz" \
    "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
  wget -q --show-progress -O "libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz" \
    "https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VER}/libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz"
}

build_libmaxminddb() {
  log "編譯安裝 libmaxminddb ${LIBMAXMINDDB_VER}..."
  cd /usr/local/src
  rm -rf "libmaxminddb-${LIBMAXMINDDB_VER}"
  tar -zxf "libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz"
  cd "libmaxminddb-${LIBMAXMINDDB_VER}"
  ./configure
  make -j"$(nproc)"
  make install

  echo "/usr/local/lib" > /etc/ld.so.conf.d/local-libmaxminddb.conf
  ldconfig
}

prepare_geoip2_module() {
  log "準備 ngx_http_geoip2_module..."
  cd /usr/local/src
  rm -rf ngx_http_geoip2_module
  git clone --depth=1 https://github.com/leev/ngx_http_geoip2_module.git
  rm -rf "${MODULE_SRC_DIR}"
  mv ngx_http_geoip2_module "${MODULE_SRC_DIR}"
}

build_nginx() {
  log "編譯安裝 Nginx ${NGINX_VER}..."
  cd /usr/local/src
  rm -rf "nginx-${NGINX_VER}"
  tar -zxf "nginx-${NGINX_VER}.tar.gz"
  cd "nginx-${NGINX_VER}"

  ./configure \
    --prefix="${PREFIX_NGINX}" \
    --sbin-path="${PREFIX_NGINX}/sbin/nginx" \
    --conf-path="${PREFIX_NGINX}/conf/nginx.conf" \
    --pid-path="${PREFIX_NGINX}/logs/nginx.pid" \
    --lock-path="${PREFIX_NGINX}/logs/nginx.lock" \
    --error-log-path="${PREFIX_NGINX}/logs/error.log" \
    --http-log-path="${PREFIX_NGINX}/logs/access.log" \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads \
    --with-file-aio \
    --add-module="${MODULE_SRC_DIR}"

  make -j"$(nproc)"
  make install
}

setup_conf_and_geoip_data() {
  log "配置檔與 GeoIP2 資料目錄..."
  mkdir -p "${GEOIP2_DIR}" "${PREFIX_NGINX}/ssl" "${PREFIX_NGINX}/vhosts"
  ln -sf "${PREFIX_NGINX}/sbin/nginx" /usr/local/bin/nginx

  if [[ "${USE_REMOTE_CONF}" == "1" ]]; then
    log "套用遠端 nginx.conf 與 Geo* 檔案..."
    cd /tmp
    rm -rf /tmp/Nginx-Geoip2
    git clone --depth=1 "${REMOTE_CONF_REPO}" /tmp/Nginx-Geoip2

    if [[ -f /tmp/Nginx-Geoip2/nginx.conf ]]; then
      cp -f /tmp/Nginx-Geoip2/nginx.conf "${PREFIX_NGINX}/conf/nginx.conf"
    else
      warn "找不到遠端 nginx.conf，保留目前設定。"
    fi

    shopt -s nullglob
    geo_files=(/tmp/Nginx-Geoip2/Geo*)
    if (( ${#geo_files[@]} > 0 )); then
      cp -f /tmp/Nginx-Geoip2/Geo* "${GEOIP2_DIR}/"
    else
      warn "遠端 repo 無 Geo* 檔案，請自行放入 mmdb。"
    fi
    shopt -u nullglob
  else
    warn "USE_REMOTE_CONF=0：略過遠端配置覆蓋。"
  fi
}

configure_firewall() {
  log "設定 firewalld..."
  systemctl enable --now firewalld

  firewall-cmd --zone=public --add-port=80/tcp --permanent
  firewall-cmd --zone=public --add-port=443/tcp --permanent
  firewall-cmd --zone=public --add-port=8080/tcp --permanent
  firewall-cmd --add-rich-rule='rule family="ipv4" source address="61.220.250.0/24" service name="ssh" accept' --permanent

  firewall-cmd --reload
}

configure_selinux() {
  if [[ "${DISABLE_SELINUX}" == "1" ]]; then
    log "關閉 SELinux（需重啟後完全生效）..."
    if [[ -f /etc/selinux/config ]]; then
      sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    fi
    setenforce 0 || true
  else
    warn "已略過 SELinux 關閉（DISABLE_SELINUX=0）。"
  fi
}

install_systemd_service() {
  log "建立 systemd 服務..."
  cat > /etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t -q
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
TimeoutStopSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nginx
  systemctl restart nginx
}

post_checks() {
  log "執行安裝後檢查..."
  "${PREFIX_NGINX}/sbin/nginx" -V
  "${PREFIX_NGINX}/sbin/nginx" -t
  systemctl --no-pager --full status nginx | sed -n '1,15p'
  ss -lntp | grep -E ':(80|443|8080)\b' || warn "未看到 80/443/8080 監聽，請檢查 nginx.conf。"
}

main() {
  require_root
  check_os
  install_build_deps
  download_sources
  build_libmaxminddb
  prepare_geoip2_module
  build_nginx
  setup_conf_and_geoip_data
  configure_firewall
  configure_selinux
  install_systemd_service
  post_checks

  log "Nginx ${NGINX_VER} 安裝完成並已啟動。"
  warn "若你關閉了 SELinux，建議排程重啟主機以完整生效。"
}

main "$@"
