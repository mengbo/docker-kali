#!/bin/bash
set -e

echo "等待 postgres 容器就绪..."
for i in {1..30}; do
  pg_isready -h postgres -U msf -d msf && break
  sleep 1
done

echo "运行 msfconsole db_status（触发框架自动建 schema）..."
msfconsole -q -x 'db_status; exit'

echo "验证 schema..."
TABLES=$(PGPASSWORD=msf psql -h postgres -U msf -d msf -t -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" \
  | tr -d ' ')
if [ "$TABLES" != "73" ]; then
  echo "ERROR: 期望 73 张表，实际 $TABLES" >&2
  exit 1
fi
echo "msf schema 就绪：$TABLES 张表"
