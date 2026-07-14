#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE


# LAN口设置静态IP
uci set network.lan.proto='static'
uci set network.lan.netmask='255.255.255.0'
# 设置路由器管理后台地址
uci set network.lan.ipaddr='192.168.100.1'
echo "default router ip is 192.168.100.1" >> $LOGFILE

uci commit network


# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by HTT"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"


exit 0
