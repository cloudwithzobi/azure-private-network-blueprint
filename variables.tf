variable "location" {
  description = "Azure region where resources will be deployed"
  type        = string
  default     = "Canada Central"
}

variable "resource_group_name" {
  description = "Name of the resource group holding all Phase 2 networking resources"
  type        = string
  default     = "rg-phase2-network"
}

variable "hub_vnet_name" {
  description = "Name of the hub VNet"
  type        = string
  default     = "vnet-hub"
}

variable "hub_vnet_address_space" {
  description = "Address space for the hub VNet"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "hub_subnet_name" {
  description = "Name of the hub shared services subnet"
  type        = string
  default     = "snet-hub-shared"
}

variable "hub_subnet_address_prefix" {
  description = "Address prefix for the hub subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "spoke_prod_vnet_name" {
  description = "Name of the prod spoke VNet"
  type        = string
  default     = "vnet-spoke-prod"
}

variable "spoke_prod_vnet_address_space" {
  description = "Address space for the prod spoke VNet"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "spoke_prod_subnet_name" {
  description = "Name of the prod workload subnet"
  type        = string
  default     = "snet-spoke-prod-workload"
}

variable "spoke_prod_subnet_address_prefix" {
  description = "Address prefix for the prod workload subnet"
  type        = list(string)
  default     = ["10.1.1.0/24"]
}

variable "spoke_dev_vnet_name" {
  description = "Name of the dev spoke VNet"
  type        = string
  default     = "vnet-spoke-dev"
}

variable "spoke_dev_vnet_address_space" {
  description = "Address space for the dev spoke VNet"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "spoke_dev_subnet_name" {
  description = "Name of the dev workload subnet"
  type        = string
  default     = "snet-spoke-dev-workload"
}

variable "spoke_dev_subnet_address_prefix" {
  description = "Address prefix for the dev workload subnet"
  type        = list(string)
  default     = ["10.2.1.0/24"]
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    environment = "portfolio"
    phase       = "phase2"
    project     = "hub-spoke-networking"
  }
}
