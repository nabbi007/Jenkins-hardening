#!/bin/bash
# Jenkins + SonarQube Setup Script for EC2 Instance
# Run this script to install and configure Jenkins and SonarQube

set -e

JENKINS_IP="46.137.135.110"
SSH_KEY="./infra/terraform/keys/jenkins-hardening"
SSH_USER="ec2-user"

echo "🚀 Setting up Jenkins + SonarQube on EC2 instance: $JENKINS_IP"

# Create the setup script to run on the remote instance
cat > /tmp/remote-setup.sh << 'EOF'
#!/bin/bash
set -e

echo "📦 Updating system packages..."
sudo yum update -y

echo "🐳 Installing Docker..."
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user

echo "☕ Installing Java 17 for Jenkins..."
sudo yum install -y java-17-amazon-corretto-headless

echo "🔧 Installing Jenkins..."
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins

# Configure Jenkins to use Java 17
sudo systemctl daemon-reload
sudo systemctl enable jenkins
sudo systemctl start jenkins

echo "🔍 Installing security tools..."
# Install Trivy
sudo yum install -y wget
wget https://github.com/aquasecurity/trivy/releases/download/v0.48.3/trivy_0.48.3_Linux-64bit.rpm
sudo rpm -ivh trivy_0.48.3_Linux-64bit.rpm
rm trivy_0.48.3_Linux-64bit.rpm

# Install Gitleaks
wget https://github.com/gitleaks/gitleaks/releases/download/v8.18.0/gitleaks_8.18.0_linux_x64.tar.gz
tar -xzf gitleaks_8.18.0_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/
rm gitleaks_8.18.0_linux_x64.tar.gz

# Install Syft for SBOM
wget https://github.com/anchore/syft/releases/download/v0.97.1/syft_0.97.1_linux_amd64.rpm
sudo rpm -ivh syft_0.97.1_linux_amd64.rpm
rm syft_0.97.1_linux_amd64.rpm

# Install SonarQube Scanner
wget https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
sudo yum install -y unzip
unzip sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm sonar-scanner-cli-5.0.1.3006-linux.zip

# Install Node.js and npm for frontend builds
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs

echo "🔊 Starting SonarQube container..."
# Start SonarQube container
sudo docker run -d \
  --name sonarqube \
  --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  sonarqube:10.3-community

echo "⏳ Waiting for services to start..."
sleep 30

echo "🔐 Getting Jenkins initial admin password..."
sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "Jenkins password not ready yet"

echo "✅ Setup completed!"
echo ""
echo "🌐 Access URLs:"
echo "   Jenkins:   http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "   SonarQube: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9000"
echo ""
echo "🔑 Default credentials:"
echo "   SonarQube: admin/admin (change on first login)"
echo "   Jenkins:   admin/[password shown above]"
echo ""
echo "🔧 Installed tools:"
echo "   - Jenkins (Java 17)"
echo "   - SonarQube (Docker container)"
echo "   - Docker"
echo "   - Trivy (container scanner)"
echo "   - Gitleaks (secret scanner)"
echo "   - Syft (SBOM generator)"
echo "   - SonarQube Scanner CLI"
echo "   - Node.js 18"
echo ""
echo "📋 Next steps:"
echo "1. Configure Jenkins plugins"
echo "2. Set up SonarQube project"
echo "3. Configure Jenkins-SonarQube integration"
EOF

# Copy and execute the setup script on the remote instance
echo "📤 Copying setup script to EC2 instance..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/remote-setup.sh "$SSH_USER@$JENKINS_IP:/tmp/"

echo "🔧 Executing setup script on remote instance..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$JENKINS_IP" "chmod +x /tmp/remote-setup.sh && /tmp/remote-setup.sh"

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "🌐 Your services are now available at:"
echo "   Jenkins:   http://$JENKINS_IP:8080"
echo "   SonarQube: http://$JENKINS_IP:9000"
echo ""
echo "🔑 To get Jenkins initial password:"
echo "   ssh -i $SSH_KEY $SSH_USER@$JENKINS_IP 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'"
echo ""
echo "🔧 To SSH into the instance:"
echo "   ssh -i $SSH_KEY $SSH_USER@$JENKINS_IP"