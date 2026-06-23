output "host_ip" {
  description = "Static LAN IP assigned to the VM"
  value       = var.host_ip
}

output "url" {
  description = "Frontend URL once DNS/NAT and TLS are in place"
  value       = "https://${var.domain}"
}
