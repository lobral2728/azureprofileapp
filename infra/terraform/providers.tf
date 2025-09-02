provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Uses MS Graph under the hood
provider "azuread" {
  tenant_id = var.tenant_id
}
