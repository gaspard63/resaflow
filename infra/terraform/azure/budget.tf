# FinOps : budget mensuel du groupe de ressources avec alertes réelles et prévisionnelles
resource "azurerm_consumption_budget_resource_group" "main" {
  name              = "budget-${local.name}"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  dynamic "notification" {
    for_each = { for t in [50, 80, 100] : "actual-${t}" => { threshold = t, type = "Actual" } }
    content {
      enabled        = length(var.budget_contact_emails) > 0
      threshold      = notification.value.threshold
      operator       = "GreaterThanOrEqualTo"
      threshold_type = notification.value.type
      contact_emails = var.budget_contact_emails
      contact_roles  = ["Owner"]
    }
  }

  notification {
    enabled        = length(var.budget_contact_emails) > 0
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted" # prévient AVANT le dépassement
    contact_emails = var.budget_contact_emails
    contact_roles  = ["Owner"]
  }

  lifecycle {
    ignore_changes = [time_period] # la date de départ ne doit pas recréer le budget
  }
}
