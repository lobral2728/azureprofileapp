output "resource_group" { value = azurerm_resource_group.rg.name }
output "storage_account_name" { value = azurerm_storage_account.st.name }
output "acr_name" { value = azurerm_container_registry.acr.name }
output "log_analytics_workspace" { value = azurerm_log_analytics_workspace.law.name }
output "app_insights_name" { value = azurerm_application_insights.appi.name }
output "uami_principal_id" { value = azurerm_user_assigned_identity.uami.principal_id }
output "container_app_api_name" { value = azurerm_container_app.api.name }
