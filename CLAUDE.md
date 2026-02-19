# CLAUDE.md

## Project Overview

Terraform module for deploying GCP Application Load Balancers (internal, global external, regional external) fronting Cloud Run services. All configuration is driven by a single YAML file.

## Repository Structure

```
.
├── main.tf                          # Root module — calls modules/alb
├── variables.tf                     # Root variable: config_file (default: config.yaml)
├── outputs.tf                       # Passes through module outputs
├── versions.tf                      # Terraform >= 1.2, google provider >= 5.0
├── config.yaml                      # Example: internal ALB
├── config-external.yaml             # Example: global external ALB
├── config-external-regional.yaml    # Example: regional external ALB
├── config-existing-cert.yaml        # Example: internal with pre-existing SSL cert
├── certs/                           # Test self-signed certificates (not for production)
└── modules/
    └── alb/
        ├── main.tf                  # All GCP resources (regional + global, gated by type)
        ├── variables.tf             # Single input: config_file path
        ├── locals.tf                # YAML parsing, type detection, derived values
        ├── outputs.tf               # LB IP, forwarding rule, URL map (conditional)
        └── versions.tf              # Provider requirements
```

## Key Architecture Decisions

- **Single module, three LB types**: The `type` field in YAML (`internal` | `external` | `external_regional`) controls which GCP resources are created. Internal and external_regional share regional resources; external uses global resources.
- **YAML-driven config**: The module takes a single `config_file` variable. All resource configuration is decoded from YAML via `yamldecode(file(...))`.
- **Backends must be normalized**: YAML-decoded objects have inconsistent value shapes (some backends have `paths`, some don't). The `backends` local uses a `for` expression to normalize all values to `{ cloud_run_service, paths }` — this is required for `for_each` ternary conditionals to work in Terraform 1.2.
- **NEGs are always regional**: Even for global external ALBs, serverless NEGs (`google_compute_region_network_endpoint_group`) are regional. The global backend service references these regional NEGs.

## Terraform Compatibility Notes

- **Terraform 1.2.7** is installed locally. The `endswith()` function requires 1.4+, so `can(regex(...))` is used instead for the YAML file extension validation.
- **YAML object type vs map type**: `yamldecode()` returns Terraform `object` types, not `map`. Ternary expressions like `condition ? local.backends : {}` fail with "inconsistent conditional result types" unless the object values are normalized into a uniform shape via a `for` expression.
- **`capacity_scaler` for EXTERNAL_MANAGED**: Regional backend services with `EXTERNAL_MANAGED` scheme require `capacity_scaler` to be set on backends. Internal (`INTERNAL_MANAGED`) does not. The module conditionally sets this to `1.0` or `null`.

## Common Commands

```bash
terraform init
terraform validate
terraform plan -var='config_file=config.yaml'
terraform apply -var='config_file=config.yaml'
```

## Testing Locally

No GCP credentials are needed for `validate` and `plan`. For `plan` with self-managed SSL certs, the cert/key PEM files must exist on disk. Test certs can be generated with:

```bash
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 \
  -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes -subj "/CN=test.internal"
```

The `MSYS_NO_PATHCONV=1` prefix is required on Git Bash for Windows to prevent path mangling of the `-subj` argument.
