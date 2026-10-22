#!/bin/bash
set -euo pipefail

# Nginx 版本（改這裡即可升級）
NGINX_VER="1.32.0"

# 1. 更新系統並安裝開發工具鏈 (CentOS 9 使用 dnf)
dnf groupinstall -y "Development Tools"
dnf install -y gcc gcc-c++ make libtool zlib zlib-devel pcre pcre-devel openssl openssl-devel wget vim unzip git lrzsz perl-devel perl-ExtUtils-Embed

# 2. 下載源碼包
cd ~
wget https://nginx.org/download/nginx-${NGINX_VER}.tar.gz
wget https://github.com/maxmind/libmaxminddb/releases/download/1.7.1/libmaxminddb-1.7.1.tar.gz

# 3. 編譯安裝 libmaxminddb (GeoIP2 核心庫)
tar -zxvf libmaxminddb-1.7.1.tar.gz
cd libmaxminddb-1.7.1
./configure
make -j "$(nproc)"
make install
echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf
ldconfig

# 4. 準備 Nginx GeoIP2 模塊
cd ~
rm -rf ngx_http_geoip2_module
git clone https://github.com/leev/ngx_http_geoip2_module.git
rm -rf /usr/local/src/ngx_http_geoip2_module
mv ngx_http_geoip2_module /usr/local/src/

# 5. 編譯安裝 Nginx
cd ~
tar -zxvf nginx-${NGINX_VER}.tar.gz
cd nginx-${NGINX_VER}
./configure --prefix=/usr/local/nginx \
--with-http_ssl_module \
--with-http_realip_module \
--with-http_stub_status_module \
--with-stream \
--add-module=/usr/local/src/ngx_http_geoip2_module
make -j "$(nproc)"
make install

# 6. 配置 GeoIP2 數據庫及配置文件
mkdir -p /usr/local/Geoip2/
rm -f /usr/local/nginx/conf/nginx.conf
cd ~
rm -rf Nginx-Geoip2
git clone https://github.com/Nick30806/Nginx-Geoip2.git
cp Nginx-Geoip2/nginx.conf /usr/local/nginx/conf/
cp Nginx-Geoip2/Geo* /usr/local/Geoip2/

# 7. 目錄初始化
mkdir -p /usr/local/nginx/ssl
mkdir -p /usr/local/nginx/vhosts
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx

# 8. 安全與防火牆配置
# 注意：CentOS 9 修改 SELinux 建議重啟生效
sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config

systemctl start firewalld
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --add-rich-rule='rule family="ipv4" source address="61.220.250.0/24" service name="ssh" accept' --permanent
firewall-cmd --reload

# 9. 創建 Systemd 服務 (替代舊的 chkconfig)
cat > /usr/lib/systemd/system/nginx.service <<EOF
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo "Nginx ${NGINX_VER} 安裝完成並已啟動！"
