#!/bin/bash
#
# 脚本功能：编译 Paimon catalog 模块并部署到远程 Docker 容器
# 使用方法：./scripts/deploy-paimon-to-remote.sh [REMOTE_HOST] [CONTAINER_NAME]
#
# 默认值：
#   REMOTE_HOST=root@47.239.213.97
#   CONTAINER_NAME=gravitino
#

set -e

# 配置参数
REMOTE_HOST="${1:-root@47.239.213.97}"
CONTAINER_NAME="${2:-gravitino}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Gravitino Paimon Catalog 部署脚本"
echo "=========================================="
echo "远程主机: $REMOTE_HOST"
echo "容器名称: $CONTAINER_NAME"
echo "项目路径: $PROJECT_ROOT"
echo ""

# Step 1: 打包源码
echo "[1/6] 打包源码..."
cd "$PROJECT_ROOT"
BUILD_TAR="/tmp/gravitino-build.tar.gz"
tar -czf "$BUILD_TAR" \
  gradlew gradle build.gradle.kts settings.gradle.kts gradle.properties \
  catalogs/catalog-lakehouse-paimon \
  catalogs/catalog-common \
  catalogs/build.gradle.kts \
  api \
  common \
  core 2>/dev/null
echo "  -> 源码打包完成: $BUILD_TAR"

# Step 2: 上传源码到远程服务器
echo "[2/6] 上传源码到远程服务器..."
scp "$BUILD_TAR" "$REMOTE_HOST:/tmp/"
echo "  -> 上传完成"

# Step 3: 在远程服务器上编译（使用 Docker JDK 17）
echo "[3/6] 在远程服务器上编译（使用 Docker JDK 17）..."
ssh "$REMOTE_HOST" 'bash -s' << 'REMOTE_SCRIPT'
set -e
cd /tmp
rm -rf gravitino-src
mkdir gravitino-src
cd gravitino-src
tar -xzf /tmp/gravitino-build.tar.gz

# 使用 Docker JDK 17 编译
docker run --rm -v /tmp/gravitino-src:/workspace -w /workspace eclipse-temurin:17-jdk \
  ./gradlew :catalogs:catalog-lakehouse-paimon:build :catalogs:catalog-common:build \
  -x test -x spotlessCheck

echo "  -> 编译完成"
REMOTE_SCRIPT

# Step 4: 备份并替换 jar 包
echo "[4/6] 备份并替换 Docker 容器中的 jar 包..."
ssh "$REMOTE_HOST" bash << REMOTE_SCRIPT
set -e
CONTAINER="$CONTAINER_NAME"
LIBS_PATH="/root/gravitino/catalogs/lakehouse-paimon/libs"
SRC_PATH="/tmp/gravitino-src"

# 备份旧 jar
mkdir -p /tmp/backup
docker exec \$CONTAINER sh -c "cp \$LIBS_PATH/gravitino-catalog-lakehouse-paimon-*.jar /tmp/ 2>/dev/null || true"
docker exec \$CONTAINER sh -c "cp \$LIBS_PATH/gravitino-catalog-common-*.jar /tmp/ 2>/dev/null || true"

# 删除旧 jar
docker exec \$CONTAINER sh -c "rm -f \$LIBS_PATH/gravitino-catalog-lakehouse-paimon-*.jar"
docker exec \$CONTAINER sh -c "rm -f \$LIBS_PATH/gravitino-catalog-common-*.jar"

# 复制新 jar（从编译目录）
docker cp \$SRC_PATH/catalogs/catalog-lakehouse-paimon/build/libs/gravitino-catalog-lakehouse-paimon-*-SNAPSHOT.jar \$CONTAINER:\$LIBS_PATH/
docker cp \$SRC_PATH/catalogs/catalog-common/build/libs/gravitino-catalog-common-*-SNAPSHOT.jar \$CONTAINER:\$LIBS_PATH/

echo "  -> jar 包替换完成"
REMOTE_SCRIPT

# Step 5: 重启容器
echo "[5/6] 重启 Docker 容器..."
ssh "$REMOTE_HOST" "docker restart $CONTAINER_NAME"
echo "  -> 容器重启中，等待服务启动..."
sleep 5

# Step 6: 验证
echo "[6/6] 验证部署..."
ssh "$REMOTE_HOST" bash << REMOTE_SCRIPT
set -e
CONTAINER="$CONTAINER_NAME"

# 检查容器状态
echo "  容器状态:"
docker ps --filter "name=\$CONTAINER" --format "  -> {{.Names}}: {{.Status}}"

# 检查新 jar 包
echo "  已部署的 jar 包:"
docker exec \$CONTAINER ls -la /root/gravitino/catalogs/lakehouse-paimon/libs/ | grep -E "gravitino-catalog-(lakehouse-paimon|common)" | awk '{print "  -> " \$NF " (" \$5 " bytes)"}'
REMOTE_SCRIPT

echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo ""
echo "下一步：运行 curl 命令创建 DLF Paimon Catalog"
echo "  ./scripts/dlf-paimon-catalog-operations.sh create"
