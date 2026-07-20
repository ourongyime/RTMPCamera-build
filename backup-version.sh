#!/bin/bash
# backup-version.sh - 备份当前源码到 backups/v{VERSION}/
# 用法: bash backup-version.sh

VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
BACKUP_DIR="backups/v${VERSION}"

mkdir -p "$BACKUP_DIR"
rsync -av --exclude 'backups' --exclude '.git' --exclude 'RTMPCamera_项目总结.txt' ./ "$BACKUP_DIR/"

echo "=========================================="
echo " 已备份 v${VERSION} 到 ${BACKUP_DIR}/"
echo "=========================================="
