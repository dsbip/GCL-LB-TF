variable "config_file" {
  description = "Path to the YAML configuration file for the internal application load balancer."
  type        = string

  validation {
    condition     = can(regex("\\.(yaml|yml)$", var.config_file))
    error_message = "The config_file must be a YAML file (.yaml or .yml)."
  }
}
