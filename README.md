# shoplite-gitops

Nguồn sự thật (single source of truth) cho mọi thứ chạy trên Kubernetes. ArgoCD đọc repo này và sync lên cluster — không ai `kubectl apply` tay.

## Trạng thái theo phase

| Thư mục | Phase | Trạng thái |
|---|---|---|
| `local/` | 1 | ✅ docker-compose chạy toàn bộ stack trên máy |
| `bootstrap/`, `platform/`, `platform-resources/`, `charts/`, `apps/` | 3 | ✅ k3d + Argo CD + Kong + CNPG + Strimzi + 12 app (dev/prod) |
| Keycloak + Kong JWT trên K8s | 4 | ⏳ |
| Observability trên K8s | 5 | ⏳ |
| GKE | 6 | ⏳ |

## Kubernetes local (Phase 3)

Yêu cầu: Docker Desktop (≥ 10 GB RAM), `k3d`, `kubectl`, `helm`. Port 80/443 trên máy phải trống.

```bash
bash bootstrap/up.sh            # k3d cluster -> helm install Argo CD -> apply root app
kubectl get applications -n argocd -w
k3d cluster stop shoplite       # tạm tắt, giữ dữ liệu  (start lại: k3d cluster start shoplite)
k3d cluster delete shoplite     # xoá hẳn
```

| URL | Gì |
|---|---|
| http://argocd.localhost | Argo CD UI, user `admin`, password: `kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| http://dev.shop.localhost | Môi trường dev (namespace `shop-dev`) |
| http://shop.localhost | Môi trường prod (namespace `shop-prod`) |

Login / đặt hàng cần Keycloak → Phase 4. Phase 3 kiểm tra được: `curl http://dev.shop.localhost/api/products`.

### Cây Application

```
root (bootstrap/root-app.yaml — apply tay đúng 1 lần)
└── platform/*.yaml
    ├── argocd            wave -20  Argo CD tự quản lý chính nó (nâng version = sửa git)
    ├── cnpg-operator     wave -10  operator PostgreSQL
    ├── strimzi-operator  wave -10  operator Kafka
    ├── kong              wave -10  Kong Ingress Controller, LoadBalancer -> host :80/:443
    ├── kafka             wave   0  platform-resources/kafka: Kafka KRaft 1 node + KafkaTopic
    └── shop              wave  10  AppProject "shop" + apps/appset.yaml
        └── ApplicationSet "shop" = {dev, prod} × {valkey, user, product, order, notification, frontend}
            └── user-service-dev, user-service-prod, ... (12 Application)
```

Sync wave chỉ có tác dụng giữa các Application con nhờ health check `argoproj.io_Application` khai báo trong `bootstrap/argocd-values.yaml`.

### Quyết định thiết kế

| Chủ đề | Chọn | Vì sao |
|---|---|---|
| Chart | 1 chart `charts/microservice` cho cả 5 workload | Service khác nhau chỉ ở values. Sửa probe/securityContext 1 chỗ |
| Values | `apps/<svc>/values.yaml` (chung) + `values-<env>.yaml` | CI chỉ sửa `image.tag` trong `values-dev.yaml`; prod chỉ đổi qua PR promote |
| PostgreSQL | 1 CNPG `Cluster` riêng cho mỗi service × env | Database-per-service đúng nghĩa; operator tự sinh Secret `<svc>-db-app` → không có password nào do người viết |
| Kafka | 1 cluster chung, topic `dev.*` / `prod.*`, consumer group theo env | Kafka tốn RAM nhất; tách bằng tên topic là cách multi-tenant phổ biến |
| Valkey | 1 instance mỗi namespace, chart tự viết, không persistence | Cache mất thì chỉ miss; tránh Bitnami (đã ngừng image miễn phí) |
| Bảo mật pod | non-root, read-only root FS, drop ALL capabilities, seccomp | Đạt chuẩn Pod Security "restricted" |
| AppProject `shop` | chỉ deploy từ repo này vào `shop-dev` / `shop-prod` | App lỗi cấu hình không thể ghi vào namespace khác |
| TLS | chưa (HTTP trên `*.localhost`) | cert-manager + Let's Encrypt cần domain thật → Phase 6 |

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
