  #!/bin/bash
  set -e

  echo "=== 编译 Flutter Web ==="
  cd admin && flutter build web --release && cd ..

  echo "=== 创建打包目录 ==="
  rm -rf /tmp/family-finance
  mkdir -p /tmp/family-finance

  echo "=== 复制文件 ==="
  cp -r backend /tmp/family-finance/
  cp -r admin /tmp/family-finance/
  cp -r deploy /tmp/family-finance/
  cp docker-compose.yml /tmp/family-finance/
  cp .env.example /tmp/family-finance/.env

  echo "=== 打包 ==="
  cd /tmp
  tar czf family-finance.tar.gz family-finance/

  echo "=== 完成 ==="
  echo "文件: /tmp/family-finance.tar.gz"
  ls -lh /tmp/family-finance.tar.gz