terraform {
  required_version = ">= 1.7.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Recommended for teams: uncomment and configure a remote state backend so the
  # infrastructure state is preserved and shareable. Left local by default.
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "e2btfstate"
  #   container_name       = "tfstate"
  #   key                  = "e2b-single-box.tfstate"
  # }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
