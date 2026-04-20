output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "hub_vnet_id" {
  description = "ID of the hub VNet"
  value       = azurerm_virtual_network.hub.id
}

output "spoke_prod_vnet_id" {
  description = "ID of the prod spoke VNet"
  value       = azurerm_virtual_network.spoke_prod.id
}

output "spoke_dev_vnet_id" {
  description = "ID of the dev spoke VNet"
  value       = azurerm_virtual_network.spoke_dev.id
}

output "peering_hub_to_prod_state" {
  description = "Peering state: hub to prod"
  value       = azurerm_virtual_network_peering.hub_to_prod.name
}

output "peering_hub_to_dev_state" {
  description = "Peering state: hub to dev"
  value       = azurerm_virtual_network_peering.hub_to_dev.name
}
