# Acmebot Terraform Module (Fork)

This module deploys **Key Vault Acmebot** on Azure using **Azure Functions (Flex Consumption)** with support for managed identity, DNS-01 validation, and Microsoft Entra authentication.

> ⚠️ This is a fork of the original module:  
> https://github.com/polymind-inc/terraform-azurerm-acmebot

---

## 🚀 Usage

```hcl
module "acmebot" {
  source = "github.com/<your-org>/terraform-azurerm-acmebot"

  app_base_name       = "acmebot"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  mail_address  = "you@domain.com"
  vault_uri     = azurerm_key_vault.kv.vault_uri

  azure_dns = {
    subscription_id = data.azurerm_client_config.current.subscription_id
  }

  maximum_instance_count = 50
  instance_memory_in_mb  = 2048

  enable_auth = true
}
