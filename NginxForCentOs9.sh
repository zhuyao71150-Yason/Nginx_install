#!/bin/bash

# 1. 更新系统并安装开发工具链 (CentOS 9 使用 dnf)
dnf groupinstall -y "Development Tools"
dnf install -y gcc gcc-c++ make libtool zlib zlib-devel pcre pcre-devel openssl openssl-devel wget vim unzip git lrzsz perl-devel perl-ExtUtils-Embed

# 2. 下载源码包
cd ~
wget https://nginx.org/download/nginx-1.22.1.tar.gz --no-check-certificate
wget https://github.com/maxmind/libmaxminddb/releases/download/1.7.1/libmaxminddb-1.7.1.tar.gz

# 3. 编译安装 libmaxminddb (GeoIP2 核心库)
tar -zxvf libmaxminddb-1.7.1.tar.gz
cd libmaxminddb-1.7.1
./configure
make -j $(nproc)
make install
echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf
ldconfig

# 4. 准备 Nginx GeoIP2 模块
cd ~
git clone https://github.com/leev/ngx_http_geoip2_module.git
rm -rf /usr/local/src/ngx_http_geoip2_module
mv ngx_http_geoip2_module /usr/local/src/

# 5. 编译安装 Nginx
cd ~
tar -zxvf nginx-1.22.1.tar.gz
cd nginx-1.22.1
./configure --prefix=/usr/local/nginx \
--with-http_ssl_module \
--with-http_realip_module \
--with-http_stub_status_module \
--with-stream \
--add-module=/usr/local/src/ngx_http_geoip2_module
make -j $(nproc)
make install

# 6. 配置 GeoIP2 数据库及配置文件
mkdir -p /usr/local/Geoip2/
rm -f /usr/local/nginx/conf/nginx.conf
cd ~
git clone https://github.com/Nick30806/Nginx-Geoip2.git
cp Nginx-Geoip2/nginx.conf /usr/local/nginx/conf/
cp Nginx-Geoip2/Geo* /usr/local/Geoip2/

# 7. 目录初始化
mkdir -p /usr/local/nginx/ssl
mkdir -p /usr/local/nginx/vhosts
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx

# 8. 安全与防火墙配置
# 注意：CentOS 9 修改 SELinux 建议重启生效，且 config 文件路径未变
sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config

systemctl start firewalld
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --add-rich-rule='rule family="ipv4" source address="61.220.250.0/24" service name="ssh" accept' --permanent
firewall-cmd --reload

# 9. 创建 Systemd 服务 (替代旧的 chkconfig)
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
systemctl start nginx

echo "Nginx 安装完成并已启动！"
