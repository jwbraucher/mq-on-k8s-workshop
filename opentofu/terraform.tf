terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "kubernetes" {
  # By default uses the active context in your local kubeconfig.
  # When working with Docker Desktop's Kubernetes this is "docker-desktop".
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}
