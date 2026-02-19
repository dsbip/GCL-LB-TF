module "alb" {
  source      = "./modules/alb"
  config_file = var.config_file
}
