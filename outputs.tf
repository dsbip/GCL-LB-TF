output "load_balancer_ip" {
  description = "The IP address assigned to the load balancer."
  value       = module.alb.load_balancer_ip
}

output "forwarding_rule_self_link" {
  description = "Self-link of the forwarding rule."
  value       = module.alb.forwarding_rule_self_link
}

output "url_map_self_link" {
  description = "Self-link of the URL map."
  value       = module.alb.url_map_self_link
}
