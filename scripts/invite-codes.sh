#!/bin/bash
# 邀请码管理脚本（v0.5.0 本版没有管理端 UI，接口 + 脚本即最小可用路径）
#
# 用法：
#   ADMIN_TOKEN=<管理员 accessToken> bash scripts/invite-codes.sh gen -n 3 -u 1 -d 7 -m "家庭邀请"
#   ADMIN_TOKEN=<管理员 accessToken> bash scripts/invite-codes.sh list [status] [page] [size]
#   ADMIN_TOKEN=<管理员 accessToken> bash scripts/invite-codes.sh revoke 41
#
# ⚠️ 发布前先 gen 2 个（本版注册必须有邀请码，没有码新用户完全无法建号）：
#   ADMIN_TOKEN=<管理员 accessToken> bash scripts/invite-codes.sh gen -n 2 -u 1 -d 7 -m "v0.5.0 首发"
# 详见 docs/RELEASE.md「v0.5.0 发版说明」。
#
# 契约要点：响应里没有 familyId —— 邀请码不携带任何家庭信息，新账号默认无家庭，
# 加入家庭走既有的申请 / 审批流程；gen/list/revoke 三个子命令都只处理展示字段。
#
# 环境变量：
#   ADMIN_TOKEN  必填，管理员登录返回的 accessToken（**不在脚本里存任何密钥**）
#   BASE         可选，服务端地址，默认 http://127.0.0.1:28083
#
# 说明：邀请码一律由服务端生成，脚本不接受自定义码串；发码接口挂在 admin 组，
#       普通用户 token 调用会得到 403。
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:28083}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"

usage() {
  cat <<'EOF'
用法：ADMIN_TOKEN=<token> bash scripts/invite-codes.sh <命令> [选项]

命令：
  gen      生成邀请码   -n 数量(1~5, 默认1)  -u 可用次数(1~50, 默认1)
                        -d 有效期天数(1/7/30, 默认7)  -m 备注(≤32字, 选填)
  list     查看列表     [状态] [页码] [每页数量]
                        状态：all|unused|partial|used|expired|revoked，默认 all
  revoke   撤销邀请码   <邀请码 id>（仅未使用可撤销，重复撤销返回已撤销）

发布前先 gen 2 个备用（否则新用户无法注册）：
  ADMIN_TOKEN=xxx bash scripts/invite-codes.sh gen -n 2 -u 1 -d 7 -m "v0.5.0 首发"

示例：
  ADMIN_TOKEN=xxx bash scripts/invite-codes.sh gen -n 5 -u 3 -d 7 -m "家庭邀请-2026-11"
  ADMIN_TOKEN=xxx bash scripts/invite-codes.sh list unused 1 20
  ADMIN_TOKEN=xxx bash scripts/invite-codes.sh revoke 41

环境变量：BASE 可覆盖服务端地址（默认 http://127.0.0.1:28083）。
EOF
}

if [ -z "$ADMIN_TOKEN" ]; then
  echo "错误：请先设置 ADMIN_TOKEN（管理员登录返回的 accessToken）" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "错误：需要 python3 来解析服务端响应" >&2
  exit 1
fi

# api <METHOD> <PATH> [BODY]：统一处理 HTTP 状态与中文错误，不回显 token。
api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp code
  tmp="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$BASE$path" \
      -H "X-Finance-Token: $ADMIN_TOKEN" -H 'Content-Type: application/json' \
      -d "$body")" || {
        rm -f "$tmp"
        echo "错误：请求失败，请检查服务端地址与网络" >&2
        exit 1
      }
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$BASE$path" \
      -H "X-Finance-Token: $ADMIN_TOKEN")" || {
        rm -f "$tmp"
        echo "错误：请求失败，请检查服务端地址与网络" >&2
        exit 1
      }
  fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "错误：服务端返回 HTTP $code" >&2
    python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        d = json.load(f)
    print(d.get('message', '未知错误'), file=sys.stderr)
except Exception:
    pass
PY
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

cmd_gen() {
  local count=1 maxuses=1 days=7 note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--count)    count="${2:?错误：-n 缺少参数}"; shift 2 ;;
      -u|--max-uses) maxuses="${2:?错误：-u 缺少参数}"; shift 2 ;;
      -d|--days)     days="${2:?错误：-d 缺少参数}"; shift 2 ;;
      -m|--note)     note="${2:?错误：-m 缺少参数}"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "错误：未知参数 $1" >&2; usage >&2; exit 1 ;;
    esac
  done
  local body
  body="$(python3 - "$count" "$maxuses" "$days" "$note" <<'PY'
import json, sys
print(json.dumps({
    "count": int(sys.argv[1]),
    "maxUses": int(sys.argv[2]),
    "expiresInDays": int(sys.argv[3]),
    "note": sys.argv[4],
}, ensure_ascii=False))
PY
)"
  # 先接住 api 的失败（set -e / pipefail），不要让下游 python 解析空输入
  # 而把 JSONDecodeError 之类的英文堆栈甩给用户（全中文文案要求）。
  local payload
  payload="$(api POST /api/admin/invite-codes "$body")" || exit 1
  printf '%s' "$payload" | python3 -c '
import json, sys, time
d = json.load(sys.stdin)
data = d.get("data") or {}
print(data.get("message", "邀请码已生成，请复制后发给家人"))
for x in data.get("codes", []):
    exp = time.strftime("%Y-%m-%d %H:%M", time.localtime(x.get("expiresAt", 0)))
    print("  %s   id=%s  可用 %s 次  有效期至 %s" % (
        x.get("code"), x.get("id"), x.get("maxUses"), exp))
'
}

cmd_list() {
  local status="${1:-all}" page="${2:-1}" size="${3:-20}"
  local payload
  payload="$(api GET "/api/admin/invite-codes?status=$status&page=$page&size=$size")" || exit 1
  printf '%s' "$payload" | python3 -c '
import json, sys, time
d = json.load(sys.stdin)
data = d.get("data") or {}
rows = data.get("list") or []
if not rows:
    print("还没有生成过邀请码")
    sys.exit(0)
labels = {"unused": "未使用", "partial": "部分使用", "used": "已使用",
          "expired": "已过期", "revoked": "已撤销"}
print("共 %s 个邀请码：" % data.get("total", len(rows)))
for x in rows:
    exp = time.strftime("%Y-%m-%d %H:%M", time.localtime(x.get("expiresAt", 0)))
    users = "、".join(u.get("nickname") or u.get("username") or str(u.get("userId"))
                     for u in (x.get("usages") or []))
    print("  [%-4s] %s  id=%s  备注=%s  配额=%s/%s  有效期至=%s  使用者=%s" % (
        labels.get(x.get("status"), x.get("status")), x.get("code"), x.get("id"),
        x.get("note") or "—", x.get("usedCount"), x.get("maxUses"), exp, users or "—"))
'
}

cmd_revoke() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "错误：请给出要撤销的邀请码 id，例如 revoke 41" >&2
    exit 1
  fi
  local payload
  payload="$(api POST "/api/admin/invite-codes/$id/revoke")" || exit 1
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
data = d.get("data") or {}
if data.get("alreadyRevoked"):
    print("该邀请码此前已撤销")
else:
    print(data.get("message", "邀请码已撤销"))
'
}

case "${1:-}" in
  gen|generate) shift; cmd_gen "$@" ;;
  list)         shift; cmd_list "$@" ;;
  revoke)       shift; cmd_revoke "$@" ;;
  -h|--help|"") usage ;;
  *) echo "错误：未知命令 $1" >&2; usage >&2; exit 1 ;;
esac
