# Event-Driven Microservices Platform - Cloud Deployment Guide

This guide explains how to deploy the complete Event-Driven Microservices Platform to AWS using Infrastructure as Code (IaC).

## 🏗️ Infrastructure Overview

The deployment creates:

### AWS Infrastructure (via Terraform)
- **EKS Cluster** - Managed Kubernetes cluster
- **VPC** - Virtual Private Cloud with public/private subnets
- **RDS PostgreSQL** - Database for SonarQube
- **ECR Repository** - Container registry
- **Load Balancers** - For external access to services
- **Security Groups** - Network security
- **NAT Gateway** - For private subnet internet access

### Microservices (via Kubernetes)
- **Kafka + Zookeeper** - Message streaming platform
- **Jenkins** - CI/CD pipeline server
- **Nexus** - Artifact repository manager  
- **SonarQube** - Code quality analysis
- **Spring Boot Admin** - Monitoring dashboard
- **Docker Registry** - Container image storage
- **Kafka Manager** - Kafka administration UI

## 🔧 Prerequisites

### Required Tools
```bash
# Install Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

### AWS Configuration
```bash
# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output format (json)

# Verify credentials
aws sts get-caller-identity
```

### Required Cloud Integrations
The deployment requires these pre-configured integrations:
- ✅ **AWS** - Primary cloud provider
- ✅ **JFrog** - Enhanced artifact management
- ✅ **NewRelic** - Application monitoring
- ✅ **Elasticsearch** - Logging and search
- ✅ **Datadog** - Infrastructure monitoring

## 🚀 Deployment

### Deploy Infrastructure
```bash
# Make scripts executable
chmod +x .forge/deploy.sh .forge/destroy.sh

# Deploy the complete platform
./.forge/deploy.sh
```

The deployment process:
1. **Validates** required tools and AWS credentials
2. **Creates AWS infrastructure** via Terraform (15-20 minutes)
3. **Deploys Kubernetes services** (10-15 minutes)
4. **Configures networking** and LoadBalancers
5. **Outputs service URLs** and credentials

### Expected Output
```
🚀 Your microservices platform is now running on AWS EKS!

JENKINS_URL=http://ab123-jenkins-lb.us-east-1.elb.amazonaws.com:8080
JENKINS_USER=admin
JENKINS_API_TOKEN=abc123def456

NEXUS_URL=http://ab123-nexus-lb.us-east-1.elb.amazonaws.com:8081
NEXUS_USERNAME=admin
NEXUS_PASSWORD=admin123

SONARQUBE_URL=http://ab123-sonar-lb.us-east-1.elb.amazonaws.com:9000
KAFKA_MANAGER_URL=http://ab123-kafka-mgr-lb.us-east-1.elb.amazonaws.com:9000
SPRING_BOOT_ADMIN_URL=http://ab123-admin-lb.us-east-1.elb.amazonaws.com:8080
DOCKER_REGISTRY_URL=http://ab123-registry-lb.us-east-1.elb.amazonaws.com:5000
```

## 🔍 Verification

### Check Cluster Status
```bash
# Verify EKS cluster
kubectl get nodes

# Check all services
kubectl get all -n edmp

# View service URLs
kubectl get svc -n edmp
```

### Access Services
- **Jenkins**: Use the provided URL and admin credentials
- **SonarQube**: Default login is admin/admin
- **Kafka Manager**: Add cluster with Zookeeper: `zookeeper.edmp.svc.cluster.local:2181`
- **Nexus**: Browse repositories and artifacts
- **Spring Boot Admin**: Monitor registered applications

## 🗑️ Cleanup

### Destroy Infrastructure
```bash
# Remove all resources and stop billing
./.forge/destroy.sh
```

This will:
1. **Delete Kubernetes resources** (including LoadBalancers)
2. **Destroy AWS infrastructure** via Terraform
3. **Clean up local configurations**
4. **Stop all AWS charges**

## 💰 Cost Estimation

Approximate monthly costs (us-east-1):
- **EKS Cluster**: $72/month
- **EC2 Instances** (3x t3.medium): ~$100/month
- **RDS PostgreSQL** (db.t3.micro): ~$15/month
- **NAT Gateway**: ~$45/month
- **Load Balancers**: ~$20/month each (6 LBs = $120/month)
- **EBS Storage**: ~$10/month

**Total**: ~$365/month

## 🔒 Security

- All traffic encrypted in transit
- Private subnets for worker nodes
- Security groups restrict access
- RDS in private subnets only
- IAM roles with minimal permissions

## 🛠️ Troubleshooting

### Common Issues

**Terraform Errors**:
```bash
# Clean up and retry
cd terraform
terraform destroy -auto-approve
rm -rf .terraform terraform.tfstate*
terraform init
```

**Pod Not Starting**:
```bash
# Check pod logs
kubectl logs -n edmp <pod-name>

# Check events
kubectl get events -n edmp --sort-by=.metadata.creationTimestamp
```

**LoadBalancer Pending**:
```bash
# Check AWS LoadBalancer controller
kubectl get pods -n kube-system | grep aws-load-balancer

# Verify security groups allow traffic
```

## 📊 Monitoring

The platform includes built-in monitoring:
- **Spring Boot Admin** - Application health
- **Kafka Manager** - Message streaming metrics
- **Jenkins** - Build pipeline status
- **SonarQube** - Code quality metrics

Additional monitoring via:
- **Datadog** - Infrastructure metrics
- **NewRelic** - Application performance
- **Elasticsearch** - Centralized logging

## 🔄 Updates

To update the platform:
```bash
# Update infrastructure
cd terraform && terraform plan && terraform apply

# Update Kubernetes services
kubectl apply -f k8s/

# Rolling updates
kubectl rollout restart deployment/<service-name> -n edmp
```