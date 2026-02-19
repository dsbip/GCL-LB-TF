# ==============================================================================
# Proxy-only subnet (required by internal & regional external ALBs)
# ==============================================================================

resource "google_compute_subnetwork" "proxy_only" {
  count = local.create_proxy_subnet ? 1 : 0

  project       = local.project
  name          = local.proxy_subnet_name
  region        = local.region
  network       = local.network
  ip_cidr_range = local.proxy_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# ==============================================================================
# Serverless NEGs — one per Cloud Run backend (always regional)
# ==============================================================================

resource "google_compute_region_network_endpoint_group" "cloud_run" {
  for_each = local.backends

  project               = local.project
  name                  = "${local.name}-neg-${each.key}"
  region                = local.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = each.value.cloud_run_service
  }
}

# ==============================================================================
#  REGIONAL RESOURCES (internal + external_regional)
# ==============================================================================

# --- Backend services (regional) ---

resource "google_compute_region_backend_service" "cloud_run" {
  for_each = local.is_regional ? local.backends : {}

  project               = local.project
  name                  = "${local.name}-bs-${each.key}"
  region                = local.region
  protocol              = "HTTPS"
  load_balancing_scheme = local.load_balancing_scheme

  backend {
    group            = google_compute_region_network_endpoint_group.cloud_run[each.key].id
    balancing_mode   = "UTILIZATION"
    capacity_scaler  = local.is_external_regional ? 1.0 : null
  }
}

# --- URL map (regional) ---

resource "google_compute_region_url_map" "this" {
  count = local.is_regional ? 1 : 0

  project         = local.project
  name            = "${local.name}-url-map"
  region          = local.region
  default_service = google_compute_region_backend_service.cloud_run["default"].id

  dynamic "path_matcher" {
    for_each = length(local.path_backends) > 0 ? ["main"] : []

    content {
      name            = "main"
      default_service = google_compute_region_backend_service.cloud_run["default"].id

      dynamic "path_rule" {
        for_each = local.path_backends

        content {
          paths   = path_rule.value.paths
          service = google_compute_region_backend_service.cloud_run[path_rule.key].id
        }
      }
    }
  }

  dynamic "host_rule" {
    for_each = length(local.path_backends) > 0 ? ["main"] : []

    content {
      hosts        = ["*"]
      path_matcher = "main"
    }
  }
}

# --- SSL certificate (regional, self-managed) ---

resource "google_compute_region_ssl_certificate" "this" {
  count = local.is_regional && local.create_ssl_cert ? 1 : 0

  project     = local.project
  name_prefix = "${local.name}-cert-"
  region      = local.region
  certificate = file(local.ssl_cert_file)
  private_key = file(local.ssl_key_file)

  lifecycle {
    create_before_destroy = true
  }
}

# --- Target HTTPS proxy (regional) ---

resource "google_compute_region_target_https_proxy" "this" {
  count = local.is_regional ? 1 : 0

  project          = local.project
  name             = "${local.name}-https-proxy"
  region           = local.region
  url_map          = google_compute_region_url_map.this[0].id
  ssl_certificates = [local.regional_ssl_certificate]
}

# --- Forwarding rule (regional) ---

resource "google_compute_forwarding_rule" "this" {
  count = local.is_regional ? 1 : 0

  project               = local.project
  name                  = "${local.name}-fr"
  region                = local.region
  load_balancing_scheme = local.load_balancing_scheme
  target                = google_compute_region_target_https_proxy.this[0].id
  port_range            = "443"
  ip_protocol           = "TCP"
  network               = local.is_internal ? local.network : null
  subnetwork            = local.is_internal ? local.subnetwork : null
  ip_address            = local.ip_address != "" ? local.ip_address : null

  depends_on = [
    google_compute_subnetwork.proxy_only,
  ]
}

# ==============================================================================
#  GLOBAL RESOURCES (external only)
# ==============================================================================

# --- Backend services (global) ---

resource "google_compute_backend_service" "cloud_run" {
  for_each = local.is_global ? local.backends : {}

  project               = local.project
  name                  = "${local.name}-bs-${each.key}"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group          = google_compute_region_network_endpoint_group.cloud_run[each.key].id
    balancing_mode = "UTILIZATION"
  }
}

# --- URL map (global) ---

resource "google_compute_url_map" "this" {
  count = local.is_global ? 1 : 0

  project         = local.project
  name            = "${local.name}-url-map"
  default_service = google_compute_backend_service.cloud_run["default"].id

  dynamic "host_rule" {
    for_each = length(local.path_backends) > 0 ? ["main"] : []

    content {
      hosts        = ["*"]
      path_matcher = "main"
    }
  }

  dynamic "path_matcher" {
    for_each = length(local.path_backends) > 0 ? ["main"] : []

    content {
      name            = "main"
      default_service = google_compute_backend_service.cloud_run["default"].id

      dynamic "path_rule" {
        for_each = local.path_backends

        content {
          paths   = path_rule.value.paths
          service = google_compute_backend_service.cloud_run[path_rule.key].id
        }
      }
    }
  }
}

# --- SSL certificate (global, self-managed) ---

resource "google_compute_ssl_certificate" "this" {
  count = local.is_global && local.create_ssl_cert ? 1 : 0

  project     = local.project
  name_prefix = "${local.name}-cert-"
  certificate = file(local.ssl_cert_file)
  private_key = file(local.ssl_key_file)

  lifecycle {
    create_before_destroy = true
  }
}

# --- Managed SSL certificate (global, Google-managed) ---

resource "google_compute_managed_ssl_certificate" "this" {
  count = local.create_managed_cert ? 1 : 0

  project = local.project
  name    = "${local.name}-managed-cert"

  managed {
    domains = local.ssl_managed_domains
  }
}

# --- Target HTTPS proxy (global) ---

resource "google_compute_target_https_proxy" "this" {
  count = local.is_global ? 1 : 0

  project          = local.project
  name             = "${local.name}-https-proxy"
  url_map          = google_compute_url_map.this[0].id
  ssl_certificates = local.global_ssl_certificates
}

# --- Global forwarding rule ---

resource "google_compute_global_forwarding_rule" "this" {
  count = local.is_global ? 1 : 0

  project               = local.project
  name                  = "${local.name}-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.this[0].id
  port_range            = "443"
  ip_protocol           = "TCP"
  ip_address            = local.ip_address != "" ? local.ip_address : null
}
