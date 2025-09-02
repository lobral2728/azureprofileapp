variable "tenant_id" {
  type = string
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "project" {
  type    = string
  default = "grinbin"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "enable_photo_write" {
  type    = bool
  default = false
}
