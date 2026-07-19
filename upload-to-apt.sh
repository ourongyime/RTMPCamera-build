#!/bin/bash
# upload-to-apt.sh - 上传 deb 包到 apt.chizicn.com
# 使用前确保 packages/ 下有编译好的 deb 包

set -e

# APT 源站配置
FTP_HOST="mb.chizicn.com"
FTP_PORT="21"
FTP_USER="apt_chizicn_com"
FTP_PASS="phEQSiyFfFkabSrK"
HTTP_UPLOAD_URL="http://apt.chizicn.com/upload.php"

echo "=========================================="
echo " RTMPCamera DEB 上传脚本"
echo "=========================================="

# 查找最新 deb 包
DEB_FILE=$(ls -t packages/*.deb 2>/dev/null | head -1)

if [ -z "$DEB_FILE" ]; then
    echo "错误: 在 packages/ 目录下没有找到 deb 包"
    exit 1
fi

echo "找到 deb 包: $DEB_FILE"
echo "文件大小: $(du -h "$DEB_FILE" | cut -f1)"

# 方式1: HTTP 上传
echo ""
echo ">>> 通过 HTTP 上传..."

UPLOAD_RESULT=$(curl -s -F "file=@$DEB_FILE" "$HTTP_UPLOAD_URL")
echo "HTTP 上传结果: $UPLOAD_RESULT"

# 方式2: FTP 上传 (备用)
if echo "$UPLOAD_RESULT" | grep -qi "error\|failed"; then
    echo ""
    echo ">>> HTTP 上传失败, 尝试 FTP..."

    ftp -n $FTP_HOST $FTP_PORT <<END_FTP
user $FTP_USER $FTP_PASS
binary
put $DEB_FILE
bye
END_FTP

    echo "FTP 上传完成"
fi

echo ""
echo "=========================================="
echo " 上传完成！"
echo ""
echo " 接下来需要:"
echo " 1. SSH 登录源站服务器"
echo " 2. 执行: dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz"
echo " 3. 在 Sileo 中刷新源, 搜索 RTMPCamera"
echo "=========================================="
