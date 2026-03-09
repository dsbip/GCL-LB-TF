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
  # SSL policy
  # ---------------------------------------------------------------------------
  ssl_policy_existing    = try(local.config.ssl_policy.existing, "")
  ssl_policy_profile     = try(local.config.ssl_policy.profile, "")
  ssl_policy_min_tls     = try(local.config.ssl_policy.min_tls_version, "TLS_1_2")
  ssl_policy_custom_features = try(local.config.ssl_policy.custom_features, [])

  create_ssl_policy = local.ssl_policy_existing == "" && local.ssl_policy_profile != ""

  ssl_policy_self_link = (
    local.create_ssl_policy
    ? google_compute_ssl_policy.this[0].self_link
    : local.ssl_policy_existing != "" ? local.ssl_policy_existing : null
  )

  # ---------------------------------------------------------------------------
  # Static IP address
  # ---------------------------------------------------------------------------
  ip_address_existing    = try(local.config.ip_address, "")
  create_static_ip       = local.ip_address_existing == ""
  static_ip_address_type = local.is_internal ? "INTERNAL" : "EXTERNAL"

  # Resolved IP for the forwarding rule
  regional_ip_address = (
    local.is_regional && local.create_static_ip
    ? google_compute_address.this[0].self_link
    : local.ip_address_existing != "" ? local.ip_address_existing : null
  )

  global_ip_address = (
    local.is_global && local.create_static_ip
    ? google_compute_global_address.this[0].self_link
    : local.ip_address_existing != "" ? local.ip_address_existing : null
  )

  # ---------------------------------------------------------------------------
  # Cloud Armor security policy
  # ---------------------------------------------------------------------------
  security_policy_default = try(local.config.security_policy, "")

  # ---------------------------------------------------------------------------
  # Backends
  # ---------------------------------------------------------------------------
  backends = {
    for k, v in local.config.backends : k => {
      cloud_run_service = v.cloud_run_service
      paths             = try(v.paths, [])
      hosts             = try(tolist(v.hosts), try([tostring(v.hosts)], ["*"]))
      security_policy   = try(v.security_policy, local.security_policy_default)
    }
  }

  # Non-default backends
  non_default_backends = {
    for k, v in local.backends : k => v if k != "default"
  }

  # Wildcard path backends: routed by path under all hosts (current behavior)
  wildcard_path_backends = {
    for k, v in local.non_default_backends : k => v
    if join(",", sort(v.hosts)) == "*" && length(v.paths) > 0
  }

  # Host-specific backends: routed to specific hostnames
  host_backends = {
    for k, v in local.non_default_backends : k => v
    if join(",", sort(v.hosts)) != "*"
  }

  # Group host backends by their sorted host key
  host_group_keys = distinct([
    for k, v in local.host_backends : join(",", sort(v.hosts))
  ])

  host_groups = {
    for hk in local.host_group_keys : hk => {
      hosts        = split(",", hk)
      matcher_name = replace(replace(split(",", hk)[0], ".", "-"), "*", "star")
      all_backends = {
        for k, v in local.host_backends : k => v
        if join(",", sort(v.hosts)) == hk
      }
    }
  }

  # For each host group, find the default backend (one without paths) or fall back to "default"
  host_group_defaults = {
    for hk, g in local.host_groups : hk => try(
      [for k, v in g.all_backends : k if length(v.paths) == 0][0],
      "default"
    )
  }

  # For each host group, collect backends that have path rules
  host_group_path_backends = {
    for hk, g in local.host_groups : hk => {
      for k, v in g.all_backends : k => v if length(v.paths) > 0
    }
  }
}
