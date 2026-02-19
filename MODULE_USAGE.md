# GCP Application Load Balancer — Terraform Module

A single Terraform module that deploys an HTTPS Application Load Balancer in Google Cloud, fronting one or more existing Cloud Run services. Supports internal, global external, and regional external load balancers — all configured through a YAML file.

## Requirements

| Name | Version |
|------|---------|
| Terraform | >= 1.2 |
| Google provider | >= 5.0 |

## Module Input

| Variable | Type | Description |
|----------|------|-------------|
| `config_file` | `string` | Path to a `.yaml` or `.yml` configuration file. |

### Usage

```hcl
module "alb" {
  source      = "./modules/alb"
  config_file = "config.yaml"
}
```

## Module Outputs

| Output | Description |
|--------|-------------|
| `load_balancer_ip` | The IP address assigned to the forwarding rule (internal IP for `internal`, public IP for `external` / `external_regional`). |
| `forwarding_rule_self_link` | Self-link of the forwarding rule. |
| `url_map_self_link` | Self-link of the URL map. |

---

## YAML Configuration Reference

The YAML file passed to `config_file` is the single source of truth for the load balancer. Every field is documented below with its type, which LB types it applies to, whether it is required, its default when omitted, and detailed usage notes.

### Full Annotated Schema

```yaml
# ─── Top-level ────────────────────────────────────────────────────────────────
type: "internal"              # optional — see §1
project_id: "my-gcp-project"  # required — see §2
region: "us-central1"         # required — see §3
name: "my-internal-lb"        # required — see §4
ip_address: ""                # optional — see §5

# ─── Network ─────────────────────────────────────────────────────────────────
network:                      # see §6
  name: "my-vpc"
  subnet: "my-subnet"

# ─── Proxy-only subnet ───────────────────────────────────────────────────────
proxy_subnet:                 # see §7
  create: true
  name: "my-proxy-subnet"
  ip_cidr_range: "10.129.0.0/23"

# ─── SSL ──────────────────────────────────────────────────────────────────────
ssl:                          # see §8
  certificate_file: "certs/cert.pem"
  private_key_file: "certs/key.pem"
  # existing_certificate: "projects/.../sslCertificates/..."
  # managed_domains: ["app.example.com"]

# ─── Backends ─────────────────────────────────────────────────────────────────
backends:                     # see §9
  default:
    cloud_run_service: "frontend"
  api:
    cloud_run_service: "api-service"
    paths: ["/api", "/api/*"]
```

---

### §1 `type`

| | |
|---|---|
| **Type** | `string` |
| **Required** | No |
| **Default** | `"internal"` |
| **Allowed values** | `"internal"`, `"external"`, `"external_regional"` |

Controls which GCP load balancer architecture is deployed:

| Value | Scheme | Scope | IP type | Resources |
|-------|--------|-------|---------|-----------|
| `"internal"` | `INTERNAL_MANAGED` | Regional | Private (from subnet) | Regional backend services, regional URL map, regional HTTPS proxy, regional forwarding rule |
| `"external"` | `EXTERNAL_MANAGED` | Global | Public (anycast) | Global backend services, global URL map, global HTTPS proxy, global forwarding rule |
| `"external_regional"` | `EXTERNAL_MANAGED` | Regional | Public (single region) | Regional backend services, regional URL map, regional HTTPS proxy, regional forwarding rule |

All three types use **regional** serverless NEGs for Cloud Run.

---

### §2 `project_id`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** |
| **Applies to** | All types |

The GCP project ID where all resources will be created. This is the project ID (e.g. `"my-project-123"`), not the project number.

All resources — NEGs, backend services, URL maps, SSL certificates, proxies, forwarding rules, and proxy-only subnets — are created in this project.

```yaml
project_id: "production-project-456"
```

---

### §3 `region`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** |
| **Applies to** | All types |

The GCP region for all regional resources. For `internal` and `external_regional`, every resource is created in this region. For `external` (global), the NEGs are created in this region and the remaining resources are global.

Must match the region where your Cloud Run services are deployed.

```yaml
region: "us-central1"
```

Common values: `us-central1`, `us-east1`, `europe-west1`, `asia-southeast1`.

---

### §4 `name`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** |
| **Applies to** | All types |

Base name prefix for all created GCP resources. Each resource appends a suffix:

| Resource | Naming pattern |
|----------|----------------|
| Serverless NEG | `<name>-neg-<backend_key>` |
| Backend service | `<name>-bs-<backend_key>` |
| URL map | `<name>-url-map` |
| SSL certificate | `<name>-cert-<random>` (uses `name_prefix`) |
| Managed SSL certificate | `<name>-managed-cert` |
| HTTPS proxy | `<name>-https-proxy` |
| Forwarding rule | `<name>-fr` |
| Proxy-only subnet | `<name>-proxy-subnet` (default, overridable) |

GCP resource names must be lowercase, start with a letter, and contain only letters, numbers, and hyphens. Max 63 characters per resource name, so keep `name` under ~40 characters to leave room for suffixes.

```yaml
name: "myapp-prod-lb"
```

---

### §5 `ip_address`

| | |
|---|---|
| **Type** | `string` |
| **Required** | No |
| **Default** | `""` (auto-assign) |
| **Applies to** | All types |

Static IP address for the forwarding rule. Behaviour depends on the LB type:

| LB type | What to provide | Auto-assign behaviour |
|---------|-----------------|----------------------|
| `internal` | A private IP from the forwarding rule's subnet (e.g. `"10.0.1.100"`) | GCP picks a free IP from the subnet |
| `external_regional` | A reserved regional external IP address or its self-link | GCP assigns an ephemeral public IP |
| `external` | A reserved global external IP address or its self-link | GCP assigns an ephemeral anycast public IP |

Leave as `""` or omit entirely to let GCP auto-assign.

```yaml
# Auto-assign
ip_address: ""

# Static internal IP
ip_address: "10.0.1.100"

# Reference a reserved global IP by self-link
ip_address: "projects/my-project/global/addresses/my-static-ip"
```

---

### §6 `network` Block

| | |
|---|---|
| **Required** | **Yes** for `internal` and `external_regional`. **Not required** for `external`. |

Identifies the VPC network (and optionally the subnet) used by the load balancer.

#### `network.name`

| | |
|---|---|
| **Type** | `string` |
| **Required** | Yes (when `network` block is present) |

VPC network name (e.g. `"my-vpc"`) or full self-link (`"projects/my-project/global/networks/my-vpc"`).

Used for:
- The forwarding rule's `network` field (`internal` only)
- The proxy-only subnet's parent network (when `proxy_subnet.create: true`)

```yaml
network:
  name: "my-vpc"
```

#### `network.subnet`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** for `internal`. Not used by `external` or `external_regional`. |

Subnet name or self-link for the internal forwarding rule. Must be in the same region as `region`. This is where the forwarding rule's private IP will be allocated from.

This is the **workload subnet**, not the proxy-only subnet.

```yaml
network:
  name: "my-vpc"
  subnet: "my-subnet"
  # or full self-link:
  # subnet: "projects/my-project/regions/us-central1/subnetworks/my-subnet"
```

---

### §7 `proxy_subnet` Block

| | |
|---|---|
| **Required** | Applicable to `internal` and `external_regional`. Ignored for `external`. |

GCP requires a **proxy-only subnet** (`purpose: REGIONAL_MANAGED_PROXY`) in the VPC/region for managed regional load balancers. Only one proxy-only subnet is allowed per VPC per region. This block controls whether the module creates it or expects it to already exist.

#### `proxy_subnet.create`

| | |
|---|---|
| **Type** | `bool` |
| **Required** | No |
| **Default** | `false` |

Set to `true` to have the module create the proxy-only subnet. Set to `false` (or omit) if one already exists in the VPC/region.

If a proxy-only subnet already exists and you set `create: true`, the apply will fail with a GCP conflict error.

#### `proxy_subnet.name`

| | |
|---|---|
| **Type** | `string` |
| **Required** | No |
| **Default** | `"<name>-proxy-subnet"` |

Name for the proxy-only subnet. Only used when `create: true`.

#### `proxy_subnet.ip_cidr_range`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** when `create: true` |

CIDR range for the proxy-only subnet. Google recommends a `/23` or larger. This range is consumed by GCP-managed proxy instances and must not overlap with other subnets in the VPC.

```yaml
# Create a new proxy-only subnet
proxy_subnet:
  create: true
  name: "my-lb-proxy-subnet"
  ip_cidr_range: "10.129.0.0/23"

# Use an existing one (module does not create anything)
proxy_subnet:
  create: false
```

---

### §8 `ssl` Block

| | |
|---|---|
| **Required** | **Yes** — exactly one SSL strategy must be configured. |

Configures the SSL certificate for the HTTPS proxy. There are three mutually exclusive strategies. Provide fields for **one** of them:

#### Strategy A: Self-managed certificate (file-based)

Provide PEM-encoded certificate and private key files on disk. The module reads them at plan time via `file()`, so they **must exist before `terraform plan`**.

| Field | Type | Description |
|-------|------|-------------|
| `ssl.certificate_file` | `string` | Path to the PEM certificate file, relative to the Terraform root directory. May include intermediate chain certificates concatenated after the leaf cert. |
| `ssl.private_key_file` | `string` | Path to the PEM private key file. Must correspond to the certificate. |

```yaml
ssl:
  certificate_file: "certs/cert.pem"
  private_key_file: "certs/key.pem"
```

Creates a `google_compute_region_ssl_certificate` (for `internal` / `external_regional`) or a `google_compute_ssl_certificate` (for `external`). Uses `name_prefix` with `create_before_destroy` lifecycle to enable zero-downtime certificate rotation.

#### Strategy B: Existing certificate (reference by self-link)

Reference an SSL certificate resource that already exists in GCP. No certificate resource is created by the module.

| Field | Type | Description |
|-------|------|-------------|
| `ssl.existing_certificate` | `string` | Full self-link of the existing SSL certificate. |

The self-link format differs by LB type:

```yaml
# For internal / external_regional (regional certificate):
ssl:
  existing_certificate: "projects/my-project/regions/us-central1/sslCertificates/my-cert"

# For external (global certificate):
ssl:
  existing_certificate: "projects/my-project/global/sslCertificates/my-cert"
```

#### Strategy C: Google-managed certificate (`external` only)

Let Google automatically provision and renew the SSL certificate. Only available for the `external` (global) LB type. Requires that the domain(s) resolve to the load balancer's IP via DNS.

| Field | Type | Description |
|-------|------|-------------|
| `ssl.managed_domains` | `list(string)` | One or more domain names for the managed certificate. |

```yaml
ssl:
  managed_domains:
    - "app.example.com"
    - "www.example.com"
```

Creates a `google_compute_managed_ssl_certificate`. Certificate provisioning happens asynchronously after `apply` and requires DNS validation — the domain(s) must point to the load balancer's IP. Provisioning can take 10-20 minutes.

#### SSL strategy summary by LB type

| Strategy | `internal` | `external_regional` | `external` |
|----------|:---:|:---:|:---:|
| `certificate_file` + `private_key_file` | Yes | Yes | Yes |
| `existing_certificate` | Yes | Yes | Yes |
| `managed_domains` | No | No | **Yes** |

---

### §9 `backends` Block

| | |
|---|---|
| **Type** | `map(object)` |
| **Required** | **Yes** |

A map of named backend definitions. Each key becomes part of the resource names (`<name>-neg-<key>`, `<name>-bs-<key>`).

#### Rules

1. **Exactly one entry must be named `"default"`**. This serves as the catch-all backend service in the URL map — any request that does not match a path rule is routed here.
2. All **non-default** entries must include a `paths` list.
3. The map **can contain just `"default"`** for a single-backend setup (no path routing).

#### `backends.<key>.cloud_run_service`

| | |
|---|---|
| **Type** | `string` |
| **Required** | **Yes** |

Name of an existing Cloud Run service in the same region. This is the **service name**, not a full resource path. The module creates a serverless NEG pointing to `cloud_run.services/<this_value>`.

The Cloud Run service must already be deployed before running `terraform apply`.

#### `backends.<key>.paths`

| | |
|---|---|
| **Type** | `list(string)` |
| **Required** | **Yes** for non-default backends. Must be **omitted** for the `"default"` backend. |

URL path patterns that route to this backend. Uses GCP URL map path matching syntax:

| Pattern | Matches |
|---------|---------|
| `"/api"` | Exact match: only `/api` |
| `"/api/*"` | Prefix match: `/api/users`, `/api/v1/items`, etc. |
| `"/api/v1/users"` | Exact match: only `/api/v1/users` |
| `"/*"` | Everything (but prefer using `default` for this) |

Path rules are evaluated in order of specificity. If a request matches multiple rules, the most specific path wins.

```yaml
backends:
  # Catch-all — no paths, serves everything not matched by other rules
  default:
    cloud_run_service: "frontend-service"

  # API routes
  api:
    cloud_run_service: "api-service"
    paths:
      - "/api"
      - "/api/*"

  # Admin panel
  admin:
    cloud_run_service: "admin-service"
    paths:
      - "/admin"
      - "/admin/*"

  # Static assets
  static:
    cloud_run_service: "cdn-service"
    paths:
      - "/static/*"
      - "/assets/*"
```

#### How backends map to GCP resources

For each entry in `backends`, the module creates:

```
backends.<key>
    │
    ├── google_compute_region_network_endpoint_group  (serverless NEG → Cloud Run)
    │
    └── google_compute_region_backend_service          (internal / external_regional)
        OR google_compute_backend_service              (external / global)
```

The URL map then references these backend services:
- The `"default"` backend becomes the URL map's `default_service`
- All other backends become `path_rule` entries inside a `path_matcher`

---

## GCP Resources Created

| Resource | When Created | Count |
|----------|-------------|-------|
| `google_compute_subnetwork` (proxy-only) | `internal` / `external_regional` when `proxy_subnet.create: true` | 0 or 1 |
| `google_compute_region_network_endpoint_group` | Always | 1 per backend |
| `google_compute_region_backend_service` | `internal` / `external_regional` | 1 per backend |
| `google_compute_backend_service` (global) | `external` | 1 per backend |
| `google_compute_region_url_map` | `internal` / `external_regional` | 1 |
| `google_compute_url_map` (global) | `external` | 1 |
| `google_compute_region_ssl_certificate` | `internal` / `external_regional` with cert files | 0 or 1 |
| `google_compute_ssl_certificate` (global) | `external` with cert files | 0 or 1 |
| `google_compute_managed_ssl_certificate` | `external` with `managed_domains` | 0 or 1 |
| `google_compute_region_target_https_proxy` | `internal` / `external_regional` | 1 |
| `google_compute_target_https_proxy` (global) | `external` | 1 |
| `google_compute_forwarding_rule` | `internal` / `external_regional` | 1 |
| `google_compute_global_forwarding_rule` | `external` | 1 |

---

## Examples

### 1. Internal Load Balancer

Private load balancer within a VPC, with a self-managed SSL certificate and path-based routing to three Cloud Run services.

```yaml
type: "internal"
project_id: "my-gcp-project"
region: "us-central1"
name: "my-internal-lb"

network:
  name: "my-vpc"
  subnet: "my-subnet"

proxy_subnet:
  create: true
  name: "my-internal-lb-proxy-subnet"
  ip_cidr_range: "10.129.0.0/23"

ssl:
  certificate_file: "certs/cert.pem"
  private_key_file: "certs/key.pem"

ip_address: ""

backends:
  default:
    cloud_run_service: "frontend-service"
  api:
    cloud_run_service: "api-service"
    paths:
      - "/api"
      - "/api/*"
  admin:
    cloud_run_service: "admin-service"
    paths:
      - "/admin"
      - "/admin/*"
```

```bash
terraform apply -var='config_file=config.yaml'
```

### 2. Global External Load Balancer

Public-facing global load balancer with a Google-managed SSL certificate. No VPC or proxy subnet configuration needed.

```yaml
type: "external"
project_id: "my-gcp-project"
region: "us-central1"
name: "my-external-lb"

ssl:
  managed_domains:
    - "app.example.com"

ip_address: ""

backends:
  default:
    cloud_run_service: "frontend-service"
  api:
    cloud_run_service: "api-service"
    paths:
      - "/api"
      - "/api/*"
```

```bash
terraform apply -var='config_file=config-external.yaml'
```

### 3. Regional External Load Balancer

Public-facing regional load balancer with a self-managed certificate. Requires a proxy-only subnet but no subnet on the forwarding rule.

```yaml
type: "external_regional"
project_id: "my-gcp-project"
region: "us-central1"
name: "my-ext-regional-lb"

network:
  name: "my-vpc"

proxy_subnet:
  create: true
  name: "my-ext-regional-lb-proxy-subnet"
  ip_cidr_range: "10.130.0.0/23"

ssl:
  certificate_file: "certs/cert.pem"
  private_key_file: "certs/key.pem"

ip_address: ""

backends:
  default:
    cloud_run_service: "frontend-service"
  api:
    cloud_run_service: "api-service"
    paths:
      - "/api"
      - "/api/*"
```

```bash
terraform apply -var='config_file=config-external-regional.yaml'
```

### 4. Internal Load Balancer with Existing SSL Certificate

Uses a pre-existing regional SSL certificate and an existing proxy-only subnet (no resources created for either).

```yaml
type: "internal"
project_id: "my-gcp-project"
region: "us-central1"
name: "my-internal-lb"

network:
  name: "my-vpc"
  subnet: "my-subnet"

proxy_subnet:
  create: false

ssl:
  existing_certificate: "projects/my-gcp-project/regions/us-central1/sslCertificates/my-cert"

ip_address: ""

backends:
  default:
    cloud_run_service: "frontend-service"
  api:
    cloud_run_service: "api-service"
    paths:
      - "/api"
      - "/api/*"
```

### 5. Single Backend (No Path Routing)

If you only have one Cloud Run service, just define the `default` backend. No path routing rules are created.

```yaml
type: "internal"
project_id: "my-gcp-project"
region: "us-central1"
name: "my-simple-lb"

network:
  name: "my-vpc"
  subnet: "my-subnet"

proxy_subnet:
  create: false

ssl:
  existing_certificate: "projects/my-gcp-project/regions/us-central1/sslCertificates/my-cert"

backends:
  default:
    cloud_run_service: "my-service"
```

---

## Prerequisites

Before deploying, ensure the following exist in the target GCP project:

1. **Cloud Run services** referenced in the `backends` block must already be deployed in the same region.
2. **VPC network** and **subnet** (for `internal` type) must exist.
3. **Proxy-only subnet** must either exist or be created by the module (`proxy_subnet.create: true`). Only one proxy-only subnet per VPC per region is allowed.
4. **SSL certificate files** must be present on disk at plan time if using `certificate_file` / `private_key_file`.
5. **IAM permissions**: the deploying identity needs `roles/compute.loadBalancerAdmin` (or equivalent) and `roles/compute.networkAdmin` if creating the proxy-only subnet.
