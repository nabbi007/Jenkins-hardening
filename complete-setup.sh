#!/bin/bash
# Complete the Jenkins + SonarQube setup
set -e

JENKINS_IP="46.137.135.110"
SSH_KEY="./infra/terraform/keys/jenkins-hardening"

echo "🔧 Completing Jenkins + SonarQube setup..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP << 'EOF'
set -e

echo "🔍 Installing security tools with correct versions..."

# Install Trivy (latest stable)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin

# Install Gitleaks
wget -q https://github.com/gitleaks/gitleaks/releases/download/v8.18.4/gitleaks_8.18.4_linux_x64.tar.gz
tar -xzf gitleaks_8.18.4_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/
rm gitleaks_8.18.4_linux_x64.tar.gz

# Install Syft
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin

# Install SonarQube Scanner
wget -q https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
sudo yum install -y unzip
unzip -q sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm sonar-scanner-cli-5.0.1.3006-linux.zip

# Install Node.js
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs

echo "🔊 Starting SonarQube container..."
sudo docker run -d \
  --name sonarqube \
  --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  sonarqube:10.3-community

echo "⏳ Waiting for services to start..."
sleep 45

echo "✅ Setup completed!"
echo ""
echo "🌐 Access URLs:"
echo "   Jenkins:   http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "   SonarQube: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9000"
echo ""
echo "🔑 Jenkins initial password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "Jenkins still starting..."

echo ""
echo "🔧 Installed versions:"
docker --version
java -version
trivy --version
gitleaks version
syft version
sonar-scanner --version
node --version
npm --version

echo ""
echo "🐳 Running containers:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "🌐 Your services:"
echo "   Jenkins:   http://$JENKINS_IP:8080"
echo "   SonarQube: http://$JENKINS_IP:9000"
echo ""
echo "🔑 Get Jenkins password:"
echo "   ssh -i $SSH_KEY ec2-user@$JENKINS_IP 'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'"
echo ""
echo "🔧 SSH into instance:"
echo "   ssh -i $SSH_KEY ec2-user@$JENKINS_IP"