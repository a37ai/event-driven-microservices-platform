output "public_ip" {
  description = "Public IP address of the EDMP server"
  value       = aws_instance.edmp_server.public_ip
}

output "server_public_ip" {
  description = "Public IP address of the EDMP server"
  value       = aws_instance.edmp_server.public_ip
}

output "server_public_dns" {
  description = "Public DNS name of the EDMP server"
  value       = aws_instance.edmp_server.public_dns
}

# RDS removed - using embedded H2 database

output "jenkins_url" {
  description = "Jenkins URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:8080"
}

output "nexus_url" {
  description = "Nexus URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:8081"
}

output "sonarqube_url" {
  description = "SonarQube URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:9000"
}

output "kafka_manager_url" {
  description = "Kafka Manager URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:9001"
}

output "grafana_url" {
  description = "Grafana URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:10001"
}

output "docker_registry_url" {
  description = "Docker Registry URL"
  value       = "http://${aws_instance.edmp_server.public_ip}:5000"
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}