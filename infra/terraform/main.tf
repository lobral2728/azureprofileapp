locals {
  prefix = "${var.project}-${var.env}"
}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# ---------------- RG ----------------
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.prefix}"
  location = var.location
}

# ---------------- Storage (Blob + Tables) ----------------
resource "azurerm_storage_account" "st" {
  name                            = lower(replace("st${local.prefix}${random_string.suffix.result}", "-", ""))
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  account_kind                    = "StorageV2"
}

resource "azurerm_storage_container" "pics_cache" {
  name                  = "profilepics-cache"
  storage_account_name  = azurerm_storage_account.st.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "predictions" {
  name                  = "predictions"
  storage_account_name  = azurerm_storage_account.st.name
  container_access_type = "private"
}

# Holds your .keras model if you download at runtime
resource "azurerm_storage_container" "models" {
  name                  = "models"
  storage_account_name  = azurerm_storage_account.st.name
  container_access_type = "private"
}

resource "azurerm_storage_table" "tbl_predictions" {
  name                 = "predictions"
  storage_account_name = azurerm_storage_account.st.name
}

resource "azurerm_storage_table" "tbl_labels" {
  name                 = "labels"
  storage_account_name = azurerm_storage_account.st.name
}

# ---------------- ACR ----------------
resource "azurerm_container_registry" "acr" {
  name                = lower(replace("acr${local.prefix}${random_string.suffix.result}", "-", ""))
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ---------------- Logs ----------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "appi" {
  name                = "appi-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
}

# ---------------- Container Apps Environment ----------------
resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${local.prefix}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

# ---------------- User-Assigned Managed Identity ----------------
resource "azurerm_user_assigned_identity" "uami" {
  name                = "uami-${local.prefix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# RBAC for ACR pull
data "azurerm_role_definition" "acr_pull" {
  name  = "AcrPull"
  scope = azurerm_container_registry.acr.id
}
resource "azurerm_role_assignment" "uami_acr_pull" {
  scope              = azurerm_container_registry.acr.id
  role_definition_id = data.azurerm_role_definition.acr_pull.id
  principal_id       = azurerm_user_assigned_identity.uami.principal_id
}

# RBAC for Storage (blobs)
data "azurerm_role_definition" "blob_contrib" {
  name  = "Storage Blob Data Contributor"
  scope = azurerm_storage_account.st.id
}
resource "azurerm_role_assignment" "uami_storage_blob_contrib" {
  scope              = azurerm_storage_account.st.id
  role_definition_id = data.azurerm_role_definition.blob_contrib.id
  principal_id       = azurerm_user_assigned_identity.uami.principal_id
}

# RBAC for Storage (tables) - optional but useful for labels
data "azurerm_role_definition" "table_contrib" {
  name  = "Storage Table Data Contributor"
  scope = azurerm_storage_account.st.id
}
resource "azurerm_role_assignment" "uami_table_contrib" {
  scope              = azurerm_storage_account.st.id
  role_definition_id = data.azurerm_role_definition.table_contrib.id
  principal_id       = azurerm_user_assigned_identity.uami.principal_id
}

# ---------------- Microsoft Graph app role assignments for the UAMI ----------------
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
}

locals {
  graph_user_read_all_id      = one([for r in data.azuread_service_principal.msgraph.app_roles : r.id if r.value == "User.Read.All"])
  graph_profilephoto_read_all = one([for r in data.azuread_service_principal.msgraph.app_roles : r.id if r.value == "ProfilePhoto.Read.All"])
  graph_profilephoto_rw_all = try(
    one([for r in data.azuread_service_principal.msgraph.app_roles : r.id if r.value == "ProfilePhoto.ReadWrite.All"]),
    null
  )
}

resource "azuread_app_role_assignment" "uami_user_read_all" {
  principal_object_id = azurerm_user_assigned_identity.uami.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = local.graph_user_read_all_id
}

resource "azuread_app_role_assignment" "uami_profilephoto_read_all" {
  principal_object_id = azurerm_user_assigned_identity.uami.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = local.graph_profilephoto_read_all
}

resource "azuread_app_role_assignment" "uami_profilephoto_rw_all" {
  count               = var.enable_photo_write && local.graph_profilephoto_rw_all != null ? 1 : 0
  principal_object_id = azurerm_user_assigned_identity.uami.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = local.graph_profilephoto_rw_all
}

# ---------------- Container App (API) ----------------
resource "azurerm_container_app" "api" {
  name                         = "ca-${local.prefix}-api"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.uami.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.uami.id # <- use .id (resource ID)
  }

  template {
    container {
      name  = "api"
      image = "${azurerm_container_registry.acr.login_server}/profilepic/api:dev"

      cpu    = 0.5
      memory = "1Gi"
      env {
        name  = "STORAGE_ACCOUNT"
        value = azurerm_storage_account.st.name
      }
      env {
        name  = "STORAGE_ACCOUNT"
        value = azurerm_storage_account.st.name
      }
      env {
        name  = "PRED_CONTAINER"
        value = "predictions"
      }
      env {
        name  = "CACHE_CONTAINER"
        value = "profilepics-cache"
      }
      env {
        name  = "TABLE_LABELS"
        value = "labels"
      }
      env {
        name  = "MIN_CONF"
        value = "0.95"
      }
      env {
        name  = "LOW_CONF"
        value = "0.70"
      }
    }
  }

  ingress {
    external_enabled = false
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ---------------- Container Apps Job (Batch Predictor) ----------------
resource "azurerm_container_app_job" "predict_job" {
  name                         = "caj-${local.prefix}-predict"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 1

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.uami.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.uami.id # <- ensure .id here too
  }

  template {
    container {
      name  = "predict"
      image = "${azurerm_container_registry.acr.login_server}/profilepic/batch:dev"

      cpu    = 1.0
      memory = "2Gi"
      env {
        name  = "STORAGE_ACCOUNT"
        value = azurerm_storage_account.st.name
      }
      env {
        name  = "PRED_CONTAINER"
        value = "predictions"
      }
      env {
        name  = "CACHE_CONTAINER"
        value = "profilepics-cache"
      }
      env {
        name  = "MODEL_CONTAINER"
        value = "models"
      }
      env {
        name  = "MODEL_BLOB"
        value = "model.keras"
      }
      env {
        name  = "MODEL_PATH"
        value = "/tmp/model.keras"
      }
      env {
        name  = "BATCH_LIMIT"
        value = "0"
      }
    }
  }
}
