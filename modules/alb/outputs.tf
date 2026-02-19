output "load_balancer_ip" {
  description = "The IP address assigned to the load balancer forwarding rule."
  value = (
    local.is_regional
    ? google_compute_forwarding_rule.this[0].ip_address
    : google_compute_global_forwarding_rule.this[0].ip_address
  )
}

output "forwarding_rule_self_link" {
  description = "Self-link of the forwarding rule."
  value = (
    local.is_regional
    ? google_compute_forwarding_rule.this[0].self_link
    : google_compute_global_forwarding_rule.this[0].self_link
  )
}

output "url_map_self_link" {
  description = "Self-link of the URL map."
  value = (
    local.is_regional
    ? google_compute_region_url_map.this[0].self_link
    : google_compute_url_map.this[0].self_link
  )
}
