#!/bin/bash
# Quick fix script to run on the existing EC2 instance
# SSH to your instance and run this script

echo "Fixing EDMP services on existing instance..."

# Install Docker
sudo yum install -y docker
sudo amazon-linux-extras install docker -y

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add ec2-user to docker group
sudo usermod -a -G docker ec2-user

# Install docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.23.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

# Create the docker-compose file in home directory
cd ~
cat > docker-compose.yml << 'EOF'
version: '3.8'

networks:
  prodnetwork:
    driver: bridge

volumes:
  jenkins-data:
  nexus-data:
  sonar-data:
  registry-data:

services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.4.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    networks:
      - prodnetwork
    restart: unless-stopped

  kafka:
    image: confluentinc/cp-kafka:7.4.0
    ports:
      - "2181:2181"
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://3.88.144.135:9092
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
    networks:
      - prodnetwork
    depends_on:
      - zookeeper
    restart: unless-stopped

  kafka-manager:
    image: hlebalbau/kafka-manager:stable
    platform: linux/amd64
    ports:
      - "9001:9000"
    environment:
      ZK_HOSTS: zookeeper:2181
      APPLICATION_SECRET: "random-secret"
    networks:
      - prodnetwork
    depends_on:
      - zookeeper
    restart: unless-stopped

  jenkins:
    image: jenkins/jenkins:2.401.3-lts
    platform: linux/amd64
    ports:
      - "8080:8080"
      - "50000:50000"
    environment:
      JAVA_OPTS: "-Xmx1024m -Xms512m -Djenkins.install.runSetupWizard=false"
    volumes:
      - jenkins-data:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - prodnetwork
    user: root
    restart: unless-stopped

  nexus:
    image: sonatype/nexus3:3.45.0
    platform: linux/amd64
    ports:
      - "8081:8081"
    volumes:
      - nexus-data:/nexus-data
    networks:
      - prodnetwork
    restart: unless-stopped

  registry:
    image: registry:2
    ports:
      - "5000:5000"
    volumes:
      - registry-data:/var/lib/registry
    networks:
      - prodnetwork
    restart: unless-stopped

  sonar:
    image: sonarqube:9.9.2-community
    ports:
      - "9000:9000"
    environment:
      SONAR_ES_BOOTSTRAP_CHECKS_DISABLE: "true"
    volumes:
      - sonar-data:/opt/sonarqube/data
    networks:
      - prodnetwork
    restart: unless-stopped

  edmp-monitoring:
    image: codecentric/spring-boot-admin:2.7.3
    platform: linux/amd64
    ports:
      - "10001:8080"
    networks:
      - prodnetwork
    restart: unless-stopped
EOF

# Start the services
echo "Starting services..."
sudo docker-compose up -d

echo "Services are starting up. Check status with: sudo docker-compose ps"
echo "View logs with: sudo docker-compose logs -f" 