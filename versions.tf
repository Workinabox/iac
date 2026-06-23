terraform {
  required_version = ">= 1.5"

  required_providers {
    xenorchestra = {
      source  = "vatesfr/xenorchestra"
      version = "~> 0.37"
    }
  }
}
