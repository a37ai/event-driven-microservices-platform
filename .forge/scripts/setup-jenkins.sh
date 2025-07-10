#!/bin/bash
# Setup Jenkins with admin user and API token capability
# This script runs inside the Jenkins container to configure it properly

set -e

# Wait for Jenkins to start
echo "Waiting for Jenkins to start..."
while ! curl -sf http://localhost:8080/login > /dev/null 2>&1; do
    echo "Jenkins not ready yet, waiting..."
    sleep 10
done

echo "Jenkins is responding, proceeding with setup..."

# Create Jenkins initialization scripts directory
mkdir -p /var/jenkins_home/init.groovy.d

# Create a Groovy script to set up admin user and security
cat > /var/jenkins_home/init.groovy.d/01-admin-user.groovy << 'EOF'
#!groovy

import jenkins.model.*
import hudson.security.*
import hudson.security.csrf.DefaultCrumbIssuer
import jenkins.security.s2m.AdminWhitelistRule

def instance = Jenkins.getInstance()

// Create admin user
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount("admin", "admin123")
instance.setSecurityRealm(hudsonRealm)

// Set authorization strategy
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// Enable CSRF protection but configure it properly
instance.setCrumbIssuer(new DefaultCrumbIssuer(true))

// Configure slave-to-master security
instance.getInjector().getInstance(AdminWhitelistRule.class).setMasterKillSwitch(false)

// Save configuration
instance.save()

println "Admin user 'admin' created with password 'admin123'"
println "Security configured successfully"
EOF

# Create a script to enable API token generation
cat > /var/jenkins_home/init.groovy.d/02-api-tokens.groovy << 'EOF'
#!groovy

import jenkins.model.*
import hudson.model.*
import jenkins.security.ApiTokenProperty
import hudson.security.HudsonPrivateSecurityRealm

def instance = Jenkins.getInstance()

// Ensure API token property is enabled for users
def descriptor = instance.getDescriptor(ApiTokenProperty.class)
if (descriptor) {
    println "API Token functionality is available"
}

// Create initial API token for admin user
def user = User.get("admin")
if (user) {
    def apiTokenProperty = user.getProperty(ApiTokenProperty.class)
    if (!apiTokenProperty) {
        apiTokenProperty = new ApiTokenProperty()
        user.addProperty(apiTokenProperty)
    }
    
    // Generate a token named 'deploy-token'
    def result = apiTokenProperty.generateNewToken("deploy-token")
    println "Generated API token for admin user: ${result.plainValue}"
    
    // Save the token to a file for extraction
    new File("/var/jenkins_home/secrets/deploy-api-token").text = result.plainValue
    
    user.save()
}

instance.save()
println "API token configuration completed"
EOF

# Make sure the secrets directory exists
mkdir -p /var/jenkins_home/secrets

# Set proper ownership
chown -R jenkins:jenkins /var/jenkins_home/init.groovy.d
chown -R jenkins:jenkins /var/jenkins_home/secrets

echo "Jenkins setup scripts created successfully"