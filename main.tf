terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.62.0"
    }
  }
}

locals {
  resource_postfix = "${var.project_name}-${var.environment_name}-${var.resource_number}"
}

// -- Existing resources -----------------------------------------------------


data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}


# -- Application Insights ---------------------------------------------------
module "app_insights" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-appi-module?ref=1.1.1"
  name                     = "appi-${local.resource_postfix}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  application_type         = "web"
}


# -- Action Group -----------------------------------------------------------


# Terraform does not seem to delete Scheduled Query Rules Alerts
# so add some entropy to its name
resource "random_string" "kv_random" {
  keepers = {
    # Generate a new id each time either of these change
    project_name = "${var.project_name}"
    resource_number    = "${var.resource_number}"
  }

  length  = 4
  special = false
}


resource "azurerm_monitor_action_group" "monitor_action_group" {
  count               = var.alert_emails != [] ? 1 : 0
  resource_group_name = data.azurerm_resource_group.this.name
  name                = "${var.project_name} Model HTTP 500 alerts - ${random_string.kv_random.result}"
  short_name          = "Error 500"

  dynamic "email_receiver" {
      for_each = toset(var.alert_emails)
      content {
        name                    = email_receiver.value
        email_address           = email_receiver.value
        use_common_alert_schema = true
      }
  }
}


# -- Query Rules Alert ------------------------------------------------------


resource "azurerm_monitor_scheduled_query_rules_alert" "scheduled_query_rules_alert" {
  count               = var.alert_emails != [] ? 1 : 0
  name                = "HTTP Error 500 alerts - ${random_string.kv_random.result}"
  description         = "Alert when model API causes HTTP Error 500"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  data_source_id      = module.app_insights.id
  enabled             = true

  # Count all requests with server error result code grouped into 60-minute bins
  severity            = 1
  frequency           = var.alert_frequency
  time_window         = var.alert_frequency
  query               = <<-QUERY
  requests
    | where tolong(resultCode) >= 500
    | summarize count() by bin(timestamp, ${var.alert_frequency}m)
  QUERY

  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }

  action {
    action_group           = [azurerm_monitor_action_group.monitor_action_group[0].id]
    email_subject          = format("%s Model HTTP API Error 500", var.project_name)
  }
}


# -- App Service + Plan -----------------------------------------------------


module "plan" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-plan-module?ref=1.3.3"
  name                     = "plan-${local.resource_postfix}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  kind                     = "linux"
  reserved                 = true
  tier                     = "Basic"
  size                     = "B2"
}


module "webapp" {
  source                                    = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-app-module?ref=2.0.0"
  name                                      = "app-${local.resource_postfix}"
  resource_group_name                       = data.azurerm_resource_group.this.name
  location                                  = data.azurerm_resource_group.this.location
  app_service_plan_id                       = module.plan.id
  application_insights_instrumentation_key  = module.app_insights.instrumentation_key
  health_check_path                         = "health"
}
