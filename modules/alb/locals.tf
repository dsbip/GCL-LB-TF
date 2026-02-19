locals {
  config = yamldecode(file(var.config_file))

  project = local.config.project_id
  region  = local.config.region
  name    = local.config.name

  # ---------------------------------------------------------------------------
  # Load balancer type
  # ---------------------------------------------------------------------------
  lb_type              = try(local.config.type, "internal")
  is_internal          = local.lb_type == "internal"
  is_external_regional = local.lb_type == "external_regional"
  is_external_global   = local.lb_type == "external"

  is_regional = local.is_internal || local.is_external_regional
  is_global   = local.is_external_global

  load_balancing_scheme = local.is_internal ? "INTERNAL_MANAGED" : "EXTERNAL_MANAGED"

  # ---------------------------------------------------------------------------
  # Network references (optional for global external)
  # ---------------------------------------------------------------------------
  network    = try(local.config.network.name, "")
  subnetwork = try(local.config.network.subnet, "")

  # ---------------------------------------------------------------------------
  # Proxy-only subnet (internal and external_regional only)
  # ---------------------------------------------------------------------------
  create_proxy_subnet = try(local.config.proxy_subnet.create, false) && local.is_regional
  proxy_subnet_name   = try(local.config.proxy_subnet.name, "${local.name}-proxy-subnet")
  proxy_subnet_cidr   = try(local.config.proxy_subnet.ip_cidr_range, "")

  # ---------------------------------------------------------------------------
  # SSL configuration
  # ---------------------------------------------------------------------------
  ssl_existing_cert  = try(local.config.ssl.existing_certificate, "")
  ssl_cert_file      = try(local.config.ssl.certificate_file, "")
  ssl_key_file       = try(local.config.ssl.private_key_file, "")
  ssl_managed_domains = try(local.config.ssl.managed_domains, [])

  # Which cert resource to create?
  create_ssl_cert         = local.ssl_existing_cert == "" && local.ssl_cert_file != "" && length(local.ssl_managed_domains) == 0
  create_managed_cert     = local.is_global && length(local.ssl_managed_domains) > 0

  # Resolved self_link for the SSL certificate used by the HTTPS proxy
  regional_ssl_certificate = (
    local.is_regional && local.create_ssl_cert
    ? google_compute_region_ssl_certificate.this[0].self_link
    : local.ssl_existing_cert
  )

  global_ssl_certificates = (
    local.create_managed_cert
    ? [google_compute_managed_ssl_certificate.this[0].id]
    : local.create_ssl_cert && local.is_global
      ? [google_compute_ssl_certificate.this[0].id]
      : local.ssl_existing_cert != "" ? [local.ssl_existing_cert] : []
  )

  # ---------------------------------------------------------------------------
  # Optional static IP
  # ---------------------------------------------------------------------------
  ip_address = try(local.config.ip_address, "")

  # ---------------------------------------------------------------------------
  # Backends
  # ---------------------------------------------------------------------------
  backends = {
    for k, v in local.config.backends : k => {
      cloud_run_service = v.cloud_run_service
      paths             = try(v.paths, [])
    }
  }

  # Non-default backends (those with path rules)
  path_backends = {
    for k, v in local.backends : k => v if k != "default"
  }
}
