terraform {
  required_version = ">= 0.12.0"
  required_providers {
    azurerm = "~> 1.36.0"
  }
}

locals {
  consumers = flatten([for h in var.hubs :
    [for c in h.consumers : {
      hub  = h.name
      name = c
  }]])

  keys = flatten([for h in var.hubs :
    [for k in h.keys : {
      hub = h.name
      key = k
  }]])

  diag_namespace_logs = [
    "ArchiveLogs",
    "AutoScaleLogs",
    "CustomerManagedKeyUserLogs",
    "EventHubVNetConnectionEvent",
    "KafkaCoordinatorLogs",
    "KafkaUserErrorLogs",
    "OperationalLogs",
  ]
  diag_namespace_metrics = [
    "AllMetrics",
  ]

  diag_resource_list = var.diagnostics != null ? split("/", var.diagnostics.destination) : []
  parsed_diag = var.diagnostics != null ? {
    log_analytics_id   = contains(local.diag_resource_list, "microsoft.operationalinsights") ? var.diagnostics.destination : null
    storage_account_id = contains(local.diag_resource_list, "Microsoft.Storage") ? var.diagnostics.destination : null
    event_hub_auth_id  = contains(local.diag_resource_list, "Microsoft.EventHub") ? var.diagnostics.destination : null
    metric             = contains(var.diagnostics.metrics, "all") ? local.diag_namespace_metrics : var.diagnostics.metrics
    log                = contains(var.diagnostics.logs, "all") ? local.diag_namespace_logs : var.diagnostics.metrics
    } : {
    log_analytics_id   = null
    storage_account_id = null
    event_hub_auth_id  = null
    metric             = []
    log                = []
  }
}

resource "azurerm_resource_group" "events" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_eventhub_namespace" "events" {
  name                = "${var.name}-ns"
  location            = azurerm_resource_group.events.location
  resource_group_name = azurerm_resource_group.events.name
  sku                 = var.sku
  capacity            = var.capacity
  kafka_enabled       = var.sku == "Standard" ? true : false

  auto_inflate_enabled     = var.auto_inflate != null ? var.auto_inflate.enabled : null
  maximum_throughput_units = var.auto_inflate != null ? var.auto_inflate.maximum_throughput_units : null

  dynamic "network_rulesets" {
    for_each = var.network_rules != null ? ["true"] : []
    content {
      default_action = "Deny"

      dynamic "ip_rule" {
        for_each = var.network_rules.ip_rules
        iterator = iprule
        content {
          ip_mask = iprule.value
        }
      }

      dynamic "virtual_network_rule" {
        for_each = var.network_rules.subnet_ids
        iterator = subnet
        content {
          subnet_id = subnet.value
        }
      }
    }
  }

  tags = var.tags
}

resource "azurerm_eventhub_namespace_authorization_rule" "events" {
  count               = length(var.authorization_rules)
  name                = var.authorization_rules[count.index].name
  namespace_name      = azurerm_eventhub_namespace.events.name
  resource_group_name = azurerm_resource_group.events.name

  listen = var.authorization_rules[count.index].listen
  send   = var.authorization_rules[count.index].send
  manage = var.authorization_rules[count.index].manage
}

resource "azurerm_eventhub" "events" {
  count               = length(var.hubs)
  name                = var.hubs[count.index].name
  namespace_name      = azurerm_eventhub_namespace.events.name
  resource_group_name = azurerm_resource_group.events.name
  partition_count     = var.hubs[count.index].partitions
  message_retention   = var.hubs[count.index].message_retention
}

resource "azurerm_eventhub_consumer_group" "events" {
  count               = length(local.consumers)
  name                = local.consumers[count.index].name
  namespace_name      = azurerm_eventhub_namespace.events.name
  eventhub_name       = local.consumers[count.index].hub
  resource_group_name = azurerm_resource_group.events.name
  user_metadata       = "terraform"

  depends_on = ["azurerm_eventhub.events"]
}

resource "azurerm_eventhub_authorization_rule" "events" {
  count               = length(local.keys)
  name                = local.keys[count.index].key.name
  namespace_name      = azurerm_eventhub_namespace.events.name
  eventhub_name       = local.keys[count.index].hub
  resource_group_name = azurerm_resource_group.events.name

  listen = local.keys[count.index].key.listen
  send   = local.keys[count.index].key.send
  manage = false

  depends_on = ["azurerm_eventhub.events"]
}

resource "azurerm_monitor_diagnostic_setting" "namespace" {
  count                          = var.diagnostics != null ? 1 : 0
  name                           = "${var.name}-ns-diag"
  target_resource_id             = azurerm_eventhub_namespace.events.id
  log_analytics_workspace_id     = local.parsed_diag.log_analytics_id
  eventhub_authorization_rule_id = local.parsed_diag.event_hub_auth_id
  eventhub_name                  = local.parsed_diag.event_hub_auth_id != null ? var.diagnostics.eventhub_name : null
  storage_account_id             = local.parsed_diag.storage_account_id

  dynamic "log" {
    for_each = local.parsed_diag.log
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }

  dynamic "metric" {
    for_each = local.parsed_diag.metric
    content {
      category = metric.value

      retention_policy {
        enabled = false
      }
    }
  }
}