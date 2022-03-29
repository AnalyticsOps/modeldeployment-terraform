terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=2.62.0"
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
resource "azurerm_application_insights" "main" {
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
  data_source_id      = azurerm_application_insights.this.id
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


resource "azurerm_app_service_plan" "main" {
  name                     = "plan-${local.resource_postfix}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  kind                     = "linux"
  reserved                 = true
  sku                 {
    tier = "Basic"
    size = "B2"
  }
}


resource "azurerm_app_service" "main" {
  name                                      = "app-${local.resource_postfix}"
  resource_group_name                       = data.azurerm_resource_group.this.name
  location                                  = data.azurerm_resource_group.this.location
  app_service_plan_id                       = azurerm_app_service_plan.main.id

  app_settings = {
    APPINSIGHTS_INSTRUMENTATIONKEY = azurerm_application_insights.main.instrumentation_key
    ApplicationInsightsAgent_EXTENSION_VERSION = "~2"
  }
  site_config {
    always_on                = true
    min_tls_version          = "1.2"
    health_check_path        = "health"
  }
}
