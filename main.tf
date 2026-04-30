data "azurerm_client_config" "current" {}

resource "azurerm_storage_account" "storage" {
  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.additional_tags

  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
}

resource "random_string" "deployment_container_suffix" {
  length  = 7
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_container" "deployment" {
  name                  = local.deployment_container_name
  storage_account_id    = azurerm_storage_account.storage.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "serverfarm" {
  name                = "plan-${var.app_base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.additional_tags

  os_type  = "Linux"
  sku_name = "FC1"
}

resource "azurerm_log_analytics_workspace" "workspace" {
  count               = var.create_law ? 1 : 0
  name                = "log-${var.app_base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.additional_tags

  sku               = "PerGB2018"
  retention_in_days = 30
}

resource "azurerm_application_insights" "insights" {
  name                = "appi-${var.app_base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.additional_tags

  application_type = "web"
  workspace_id = var.create_law ? (
    azurerm_log_analytics_workspace.workspace[0].id
  ) : var.log_analytics_workspace_id
}

resource "azurerm_function_app_flex_consumption" "function" {
  name                = local.function_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.additional_tags

  service_plan_id               = azurerm_service_plan.serverfarm.id
  storage_container_type        = "blobContainer"
  storage_container_endpoint    = "${azurerm_storage_account.storage.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type   = "StorageAccountConnectionString"
  storage_access_key            = azurerm_storage_account.storage.primary_access_key
  runtime_name                  = "dotnet-isolated"
  runtime_version               = "10.0"
  https_only                    = true
  public_network_access_enabled = var.public_network_access_enabled
  maximum_instance_count        = var.maximum_instance_count
  instance_memory_in_mb         = var.instance_memory_in_mb
  virtual_network_subnet_id     = var.virtual_network_subnet_id

  app_settings = merge(var.additional_app_settings, local.acmebot_app_settings, local.managed_identity_app_settings, local.auth_app_settings)

  identity {
    type = var.user_assigned_identity_id == null ? "SystemAssigned" : "UserAssigned"

    identity_ids = var.user_assigned_identity_id == null ? null : [
      var.user_assigned_identity_id
    ]
  }

  dynamic "auth_settings_v2" {
    for_each = var.enable_auth ? [1] : []

    content {
      auth_enabled           = true
      require_authentication = true
      unauthenticated_action = "RedirectToLoginPage"
      default_provider       = "azureactivedirectory"

      active_directory_v2 {
        client_id                  = azuread_application.acmebot[0].client_id
        tenant_auth_endpoint       = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
        client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"

        allowed_audiences = [
          "api://${azuread_application.acmebot[0].client_id}"
        ]
      }

      login {
        token_store_enabled = true
      }
    }
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.insights.connection_string
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
    scm_use_main_ip_restriction            = true

    ip_restriction_default_action = length(var.allowed_ip_addresses) != 0 ? "Deny" : "Allow"

    dynamic "ip_restriction" {
      for_each = var.allowed_ip_addresses

      content {
        ip_address = ip_restriction.value
      }
    }
  }
}

resource "azuread_application" "acmebot" {
  count        = var.enable_auth ? 1 : 0
  display_name = "app-${local.function_app_name}"

  web {
    homepage_url = "https://${local.function_app_name}.azurewebsites.net/dashboard"

    redirect_uris = [
      "https://${local.function_app_name}.azurewebsites.net/.auth/login/aad/callback"
    ]

    implicit_grant {
      access_token_issuance_enabled = true
      id_token_issuance_enabled     = true
    }
  }
}

resource "azuread_service_principal" "acmebot" {
  count     = var.enable_auth ? 1 : 0
  client_id = azuread_application.acmebot[0].client_id
}

resource "azuread_application_password" "acmebot" {
  count          = var.enable_auth ? 1 : 0
  application_id = azuread_application.acmebot[0].id
}

resource "null_resource" "deploy_package" {
  triggers = {
    package_url = "https://stacmebotprod.blob.core.windows.net/keyvault-acmebot/v5/latest.zip"
    function_id = azurerm_function_app_flex_consumption.function.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]

    command = <<-EOT
      set -euo pipefail

      curl -fsSL -o /tmp/keyvault-acmebot.zip "${self.triggers.package_url}"

      az functionapp deployment source config-zip \
        --subscription ${data.azurerm_client_config.current.subscription_id} \
        --resource-group ${var.resource_group_name} \
        --name ${azurerm_function_app_flex_consumption.function.name} \
        --src /tmp/keyvault-acmebot.zip
    EOT
  }

  depends_on = [
    azurerm_function_app_flex_consumption.function
  ]
}

data "azurerm_function_app_host_keys" "function" {
  count               = var.export_api_key ? 1 : 0
  name                = azurerm_function_app_flex_consumption.function.name
  resource_group_name = var.resource_group_name

  depends_on = [azurerm_function_app_flex_consumption.function]
}
