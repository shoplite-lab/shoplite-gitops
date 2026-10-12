# shoplite-gitops

Nguồn sự thật (single source of truth) cho mọi thứ chạy trên Kubernetes. ArgoCD đọc repo này và sync lên cluster — không ai `kubectl apply` tay.

## Trạng thái theo phase

| Thư mục | Phase | Trạng thái |
|---|---|---|
| `local/` | 1 | ✅ docker-compose chạy toàn bộ stack trên máy |
| `bootstrap/`, `platform/`, `platform-resources/`, `charts/`, `apps/` | 3–6 | ⏳ chưa làm |

## Chạy local (Phase 1)

Yêu cầu: Docker Desktop (~8 GB RAM cho Docker). Các repo service phải nằm cạnh nhau:

```
shoplite/
  shoplite-gitops/        <- repo này
  shoplite-frontend/
  shoplite-user-service/
  shoplite-product-service/
  shoplite-order-service/
  shoplite-notification-service/
```

```bash
cd local
docker compose up -d --build
docker compose ps
```

Lần đầu mất vài phút (build Maven + kéo image). Keycloak cần ~30–60s để sẵn sàng.

| URL | Gì | Tài khoản |
|---|---|---|
| http://shop.localhost:8000 | Web app | `alice/alice` (customer), `bob/bob` (admin), `devops1/devops1` (group devops) |
| http://auth.localhost:8000/admin | Keycloak admin console | `admin/admin` |
| http://grafana.localhost:8000 | Grafana (bấm "Sign in with Keycloak") | `devops1` → Admin, user khác → Viewer |
| http://localhost:3000 | Grafana trực tiếp (bỏ qua Kong) | |
| http://localhost:8001 | Kong Admin API (read-only, DB-less) | |
| localhost:5433 / 6379 / 9092 | Postgres / Valkey / Kafka từ host | postgres/postgres |

`*.localhost` tự trỏ về 127.0.0.1 trên Chrome/Edge/Firefox và curl, không cần sửa file hosts.

## Thử nhanh bằng curl

```bash
# Lấy token (password grant chỉ bật cho local để test; browser dùng Auth Code + PKCE)
TOKEN=$(curl -s -X POST http://auth.localhost:8000/realms/shoplite/protocol/openid-connect/token \
  -d grant_type=password -d client_id=shop-frontend -d username=alice -d password=alice | jq -r .access_token)

curl http://shop.localhost:8000/api/products                                  # public
curl http://shop.localhost:8000/api/orders                                    # 401 từ Kong
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"productId":1,"quantity":1}' http://shop.localhost:8000/api/orders     # 201
curl -H "Authorization: Bearer $TOKEN" http://shop.localhost:8000/api/notifications
```

## Những gì đã kiểm chứng ở local

| Kịch bản | Kết quả mong đợi |
|---|---|
| Gọi `/api/orders` không token | Kong trả 401 (service không bị gọi) |
| `alice` tạo product | 403 từ product-service (Kong cho qua vì token hợp lệ, service check role) |
| `bob` tạo product | 201 |
| Đặt hàng vượt tồn kho | 409 `Insufficient stock` (truyền nguyên từ product-service qua order-service) |
| Đặt hàng thành công | Notification xuất hiện sau ~1s (qua Kafka `order.created`) |
| Xem product 2 lần | Lần 2 không có log `Cache miss`, Redis có key `product-service::product::<id>` |
| Gọi `/api/orders` > 20 lần/phút | Kong trả 429 |
| Grafana → Explore → Tempo | 1 trace đi qua `kong → order-service → product-service → kafka → notification-service` |
| Từ trace bấm sang Loki | Log cùng `trace_id` |
| Login shop bằng `devops1`, mở Grafana | Vào thẳng, không hỏi password (SSO), role Admin |

## Kiến trúc local vs Kubernetes

| Thành phần | Local (`local/`) | Kubernetes (phase sau) |
|---|---|---|
| Postgres | 1 container, script tạo 5 DB/role | CloudNativePG operator |
| Kafka | `apache/kafka` KRaft 1 node | Strimzi operator |
| Keycloak | `start-dev --import-realm` | Keycloak Operator + keycloak-config-cli |
| Kong | DB-less `kong/kong.yml` | Kong Ingress Controller + CRD |
| Observability | `grafana/otel-lgtm` all-in-one | OTel Operator + Collector, Tempo, Loki, Alloy, kube-prometheus-stack |
| OTel Java agent | init container `otel-agent` copy jar vào volume | OTel Operator tự inject (cùng cơ chế) |

## ⚠️ Chỉ dùng cho local

`local/keycloak/shoplite-realm.json` chứa **RSA private key, client secret và password mẫu** để Kong có thể verify JWT bằng public key cố định (`local/kong/kong.yml`). Đây là dữ liệu demo, không bao giờ dùng cho môi trường thật. Trên Kubernetes, key/secret nằm trong Secret Manager và được inject qua External Secrets.
