# clusters/ — mỗi cluster một lớp cấu hình

Phần lớn ShopLite chạy y hệt trên mọi cluster: chart, ApplicationSet, Kong, Keycloak, Kafka, observability. Chỉ một ít thứ đổi theo cluster (tên miền, nơi lưu dữ liệu, nơi lấy secret). Thay vì copy cả repo, mỗi cluster có **một thư mục chồng lên bản gốc** bằng Kustomize.

| Cluster | Root app | Cách chồng |
|---|---|---|
| **k3d** (local) | `bootstrap/root-app.yaml` → `platform/` | Là bản gốc, không có lớp phủ |
| **gke-us** (GCP) | `bootstrap/gke-root-app.yaml` → `clusters/gke-us/` | `platform/` + vá + vài Application chỉ có trên GKE |

## `clusters/gke-us/` gồm những gì

```
kustomization.yaml     gốc của cluster: ../../platform + các vá (patches)
argocd-values.yaml     values Argo CD chồng lên bootstrap/argocd-values.yaml (URL, OIDC, health ExternalSecret)
values*.yaml           values Helm cho mọi app: Postgres ngoài, issuer, host dev/prod, frontend
apps/                  ApplicationSet gốc (apps/) + prod không còn "paused", thêm 3 file values, tên secret DB
keycloak/              platform-resources/keycloak + bỏ CNPG, JDBC URL Neon, hostname https, URL của realm
platform/              Application chỉ có trên GKE: external-secrets, secrets, external-dns
secrets/               ClusterSecretStore + ExternalSecret (thay bootstrap/secrets.sh) + namespace
```

Những gì khác với k3d, và chỗ nào xử lý:

| Khác biệt | Chỗ xử lý |
|---|---|
| Tên miền thật, HTTPS | `kustomization.yaml` (Grafana, Kafka UI), `argocd-values.yaml`, `values-*.yaml`, `keycloak/` |
| Postgres ngoài (Neon), không CNPG | `values.yaml` (`postgres.external.enabled`), chart `externalsecret-db.yaml`, `keycloak/`, xoá app `cnpg-operator` |
| Secret từ Secret Manager | `platform/external-secrets.yaml`, `platform/secrets.yaml`, `secrets/` |
| Loki/Tempo lưu ở GCS | patch `loki`, `tempo` trong `kustomization.yaml` |
| TLS | Kong dùng chứng chỉ Cloudflare Origin làm mặc định (patch `kong`); Cloudflare đứng trước và giữ chứng chỉ công khai |
| DNS | `platform/external-dns.yaml` (bản ghi proxied ở Cloudflare). Không cần `local-dns` nên bị xoá |

## Thứ tự đồng bộ (sync wave)

`external-secrets` (-40) → `secrets` (-35) → `kong` (-30) → `external-dns`, `argocd` (-20) → `cert-manager` (-15) → các operator (-10) → `keycloak`, `kong-config`, `observability`, `kafka` (0) → `shop` (10).
External Secrets và các Secret phải có trước Kong, vì Kong gắn Secret chứng chỉ vào pod.

## Giữ chỗ cần thay trước khi dùng

- Tên miền: hiện là `neststack.site` (đã đặt). Đổi sang domain khác: `bash scripts/set-domain.sh <domain-mới> neststack.site`, rồi nạp lại Origin cert và API token cho domain mới.
- Host Neon của Keycloak: đã điền (`ep-orange-hill-b5peya20...`, host direct, không `-pooler`) trong `clusters/gke-us/keycloak/kustomization.yaml`. Nếu tạo lại project Neon thì sửa host này.
- Project id `shoplite-demo-1e7583`: giữ nguyên nếu dùng project hiện tại.
- `targetRevision: main`: các Application đọc nhánh `main`, nên phải merge nhánh `phase-6-gke` trước khi dựng cluster.

## Kiểm tra khi sửa (không cần cluster)

```bash
bash scripts/check-kustomize-bases.sh         # platform/, apps/, platform-resources/kong/ còn đầy đủ trong kustomization
kubectl kustomize clusters/gke-us             # lớp phủ GKE build được
kubectl kustomize clusters/gke-us/apps
kubectl kustomize clusters/gke-us/keycloak
helm template <svc> charts/microservice -f apps/<svc>/values.yaml -f apps/<svc>/values-<env>.yaml \
  -f clusters/gke-us/values.yaml -f clusters/gke-us/values-<env>.yaml --set postgres.external.remoteKey=x
```

k3d không bị ảnh hưởng: `kubectl kustomize platform` cho ra đúng những object như đọc thẳng các file (đã so sánh), và `helm template` của mọi app với values k3d cho kết quả giống hệt bản trước.

## Điều chưa được kiểm chứng vì chưa có GKE

Mọi thứ trên đây đã được render và so sánh, nhưng **chưa chạy trên cluster thật**. Cần xem lúc dựng lần đầu: Workload Identity của ESO/Loki/Tempo, ExternalSecret thành Secret, Kong đọc chứng chỉ Origin, `trusted_ips` của Cloudflare, Keycloak nối Neon qua SSL, cold start của Neon.
