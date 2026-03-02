pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
    timeout(time: 20, unit: 'MINUTES')
  }

  triggers {
    githubPush()
  }

  parameters {
    booleanParam(name: 'ENABLE_SONARQUBE',     defaultValue: true,  description: 'Run SonarQube SAST')
    booleanParam(name: 'ENABLE_NPM_AUDIT',     defaultValue: true,  description: 'Run npm audit SCA')
    booleanParam(name: 'ENABLE_GITLEAKS',      defaultValue: true,  description: 'Run Gitleaks secret scan')
    booleanParam(name: 'ENABLE_TRIVY',         defaultValue: true,  description: 'Run Trivy image scan')
    booleanParam(name: 'ENABLE_SBOM',          defaultValue: true,  description: 'Generate SBOM using Syft')
    booleanParam(name: 'DEPLOY_FROM_NON_MAIN', defaultValue: false, description: 'Allow deploy from non-main branches')
  }

  environment {
    REPORT_DIR              = 'reports/security'
    SBOM_DIR                = 'reports/sbom'
    ECS_REPORT_DIR          = 'reports/ecs'
    TASKDEF_TEMPLATE        = 'ecs/taskdef.template.json'
    BACKEND_CONTAINER_NAME  = 'backend'
    FRONTEND_CONTAINER_NAME = 'frontend'
    APPSPEC_TEMPLATE        = 'ecs/appspec.template.json'

    // Defaults — override via Jenkins → Manage Jenkins → System → Global properties if needed
    BACKEND_LOG_GROUP           = "${env.BACKEND_LOG_GROUP  ?: '/ecs/voting-app/backend'}"
    FRONTEND_LOG_GROUP          = "${env.FRONTEND_LOG_GROUP ?: '/ecs/voting-app/frontend'}"
    ECS_TASK_CPU                = "${(env.ECS_TASK_CPU               ?: '1024').trim()}"
    ECS_TASK_MEMORY             = "${(env.ECS_TASK_MEMORY            ?: '2048').trim()}"
    ECR_LIFECYCLE_MAX_IMAGES    = "${(env.ECR_LIFECYCLE_MAX_IMAGES   ?: '30').trim()}"
    ECS_TASKDEF_KEEP_REVISIONS  = "${(env.ECS_TASKDEF_KEEP_REVISIONS ?: '15').trim()}"
    CODEDEPLOY_APP_NAME         = "${env.CODEDEPLOY_APP_NAME  ?: 'voting-app-deploy'}"
    CODEDEPLOY_DG_NAME          = "${env.CODEDEPLOY_DG_NAME   ?: 'voting-app-dg'}"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Prepare Build Metadata') {
      steps {
        script {
          // Validate required env vars
          if (!env.AWS_REGION) error('AWS_REGION not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.BACKEND_ECR_REPO) error('BACKEND_ECR_REPO not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.FRONTEND_ECR_REPO) error('FRONTEND_ECR_REPO not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.ECS_CLUSTER_NAME) error('ECS_CLUSTER_NAME not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.ECS_SERVICE_NAME) error('ECS_SERVICE_NAME not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.ECS_TASK_FAMILY) error('ECS_TASK_FAMILY not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')
          if (!env.TRIVY_SEVERITIES) error('TRIVY_SEVERITIES not set. Configure in Jenkins → Manage Jenkins → System → Global properties → Environment variables.')

          env.GIT_SHA     = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
          // BRANCH_NAME is only set by Multibranch pipelines; fall back to git for regular Pipeline jobs
          def detectedBranch = env.BRANCH_NAME \
            ?: env.GIT_BRANCH?.replaceFirst('origin/', '') \
            ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
          env.SAFE_BRANCH = detectedBranch.replaceAll('[^a-zA-Z0-9_.-]', '-')
          env.IS_MAIN     = (detectedBranch == 'main') ? 'true' : 'false'
          env.IMAGE_TAG   = "${env.SAFE_BRANCH}-${env.GIT_SHA}-${env.BUILD_NUMBER}"

          env.ECR_ACCOUNT_ID_EFFECTIVE = sh(
            script: 'aws sts get-caller-identity --query Account --output text',
            returnStdout: true
          ).trim()

          if (!env.ECR_ACCOUNT_ID_EFFECTIVE) {
            error('Unable to determine AWS account ID. Ensure Jenkins IAM role has sts:GetCallerIdentity.')
          }

          env.ECR_REGISTRY       = "${env.ECR_ACCOUNT_ID_EFFECTIVE}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.BACKEND_IMAGE_URI  = "${env.ECR_REGISTRY}/${env.BACKEND_ECR_REPO}:${env.IMAGE_TAG}"
          env.FRONTEND_IMAGE_URI = "${env.ECR_REGISTRY}/${env.FRONTEND_ECR_REPO}:${env.IMAGE_TAG}"

          sh 'mkdir -p reports/security reports/security/trivy reports/sbom reports/ecs .trivycache'
          sh 'test -f ecs/taskdef.template.json'
        }
      }
    }

    stage('Unit + Lint') {
      parallel {
        stage('Backend') {
          steps {
            dir('backend') {
              sh 'npm ci --no-audit --no-fund'
              sh 'npm run lint'
              sh 'npm run test:ci'
            }
          }
        }
        stage('Frontend') {
          steps {
            dir('frontend') {
              sh 'npm ci --no-audit --no-fund'
              sh 'npm run lint'
              sh 'npm run test:ci'
              sh 'npm run build'
            }
          }
        }
      }
    }

    stage('Security Scans') {
      parallel {
        stage('SAST - SonarQube') {
          when { expression { return params.ENABLE_SONARQUBE } }
          steps {
            withSonarQubeEnv('sonar-qube-server') {
              sh '''
                set -euo pipefail
                docker run --rm \
                  --network host \
                  -v "$PWD:/usr/src" \
                  -e SONAR_HOST_URL="${SONAR_HOST_URL}" \
                  -e SONAR_TOKEN="${SONAR_AUTH_TOKEN}" \
                  sonarsource/sonar-scanner-cli:5.0.1 \
                  -Dsonar.login="${SONAR_AUTH_TOKEN}" \
                  -Dsonar.projectVersion="${IMAGE_TAG}" \
                  -Dsonar.qualitygate.wait=true \
                  -Dsonar.qualitygate.timeout=600
              '''
            }
          }
        }

        stage('SCA - npm audit') {
          when { expression { return params.ENABLE_NPM_AUDIT } }
          steps {
            sh '''
              set -euo pipefail
              cd backend
              npm audit --audit-level=high --json > ../reports/security/npm-audit-backend.json || true
              npm audit --audit-level=high || echo "Backend vulnerabilities found"
              cd ../frontend
              npm audit --audit-level=high --json > ../reports/security/npm-audit-frontend.json || true
              npm audit --audit-level=high || echo "Frontend vulnerabilities found"
            '''
          }
        }

        stage('Secrets - Gitleaks') {
          when { expression { return params.ENABLE_GITLEAKS } }
          steps {
            sh '''
              set -euo pipefail
              docker run --rm \
                -v "$PWD:/repo" \
                zricethezav/gitleaks:v8.24.2 detect \
                --source /repo \
                --config /repo/.gitleaks.toml \
                --redact \
                --no-banner \
                --max-target-megabytes 10 \
                --report-format sarif \
                --report-path /repo/reports/security/gitleaks.sarif \
                --exit-code 1 || echo "Gitleaks found secrets - check reports/security/gitleaks.sarif"
            '''
          }
        }
      }
    }

    stage('Build Container Images') {
      steps {
        sh 'docker build -t "$BACKEND_IMAGE_URI" backend'
        sh 'docker build -t "$FRONTEND_IMAGE_URI" frontend'
      }
    }

    stage('Post-Build Scans') {
      parallel {
        stage('Container Scan - Trivy') {
          when { expression { return params.ENABLE_TRIVY } }
          steps {
            sh '''
              set -euo pipefail
              SEVERITIES=$(echo "${TRIVY_SEVERITIES}" | tr -d ' ')
              docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v "$PWD:/work" \
                -v "$PWD/.trivycache:/root/.cache/trivy" \
                -e TRIVY_CACHE_DIR=/root/.cache/trivy \
                aquasec/trivy:0.58.1 image \
                --scanners vuln \
                --severity "${SEVERITIES}" \
                --ignore-unfixed \
                --exit-code 1 \
                --format json \
                --output /work/reports/security/trivy/backend.json \
                "${BACKEND_IMAGE_URI}"

              docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v "$PWD:/work" \
                -v "$PWD/.trivycache:/root/.cache/trivy" \
                -e TRIVY_CACHE_DIR=/root/.cache/trivy \
                aquasec/trivy:0.58.1 image \
                --scanners vuln \
                --severity "${SEVERITIES}" \
                --ignore-unfixed \
                --exit-code 1 \
                --format json \
                --output /work/reports/security/trivy/frontend.json \
                "${FRONTEND_IMAGE_URI}"
            '''
          }
        }

        stage('SBOM - Syft') {
          when { expression { return params.ENABLE_SBOM } }
          steps {
            sh '''
              set -euo pipefail
              docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v "$PWD:/work" \
                anchore/syft:v1.20.0 "${BACKEND_IMAGE_URI}" \
                -o cyclonedx-json=/work/reports/sbom/backend.cyclonedx.json

              docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v "$PWD:/work" \
                anchore/syft:v1.20.0 "${FRONTEND_IMAGE_URI}" \
                -o cyclonedx-json=/work/reports/sbom/frontend.cyclonedx.json
            '''
          }
        }
      }
    }

    stage('Push Versioned Images to ECR') {
      steps {
        sh '''
          set -euo pipefail
          aws ecr get-login-password --region "$AWS_REGION" | \
            docker login --username AWS --password-stdin "$ECR_REGISTRY"
          docker push "$BACKEND_IMAGE_URI"
          docker push "$FRONTEND_IMAGE_URI"
        '''
      }
    }

    stage('Tag Latest (main only)') {
      when { expression { return env.IS_MAIN == 'true' } }
      steps {
        sh '''
          set -euo pipefail
          docker tag "$BACKEND_IMAGE_URI"  "${ECR_REGISTRY}/${BACKEND_ECR_REPO}:latest"
          docker tag "$FRONTEND_IMAGE_URI" "${ECR_REGISTRY}/${FRONTEND_ECR_REPO}:latest"
          docker push "${ECR_REGISTRY}/${BACKEND_ECR_REPO}:latest"
          docker push "${ECR_REGISTRY}/${FRONTEND_ECR_REPO}:latest"
        '''
      }
    }

    stage('Render ECS Task Definition') {
      steps {
        withCredentials([
          string(credentialsId: 'ecs-execution-role-arn', variable: 'ECS_EXECUTION_ROLE_ARN'),
          string(credentialsId: 'ecs-task-role-arn', variable: 'ECS_TASK_ROLE_ARN')
        ]) {
          sh '''
            set -euo pipefail

            escape_for_sed() { printf '%s' "$1" | sed -e 's/[\\/&]/\\\\&/g'; }

            sed \
              -e "s/__TASK_FAMILY__/$(escape_for_sed "$ECS_TASK_FAMILY")/g" \
              -e "s/__TASK_CPU__/${ECS_TASK_CPU}/g" \
              -e "s/__TASK_MEMORY__/${ECS_TASK_MEMORY}/g" \
              -e "s/__AWS_REGION__/$(escape_for_sed "$AWS_REGION")/g" \
              -e "s/__EXECUTION_ROLE_ARN__/$(escape_for_sed "$ECS_EXECUTION_ROLE_ARN")/g" \
              -e "s/__TASK_ROLE_ARN__/$(escape_for_sed "$ECS_TASK_ROLE_ARN")/g" \
              -e "s/__BACKEND_IMAGE__/$(escape_for_sed "$BACKEND_IMAGE_URI")/g" \
              -e "s/__FRONTEND_IMAGE__/$(escape_for_sed "$FRONTEND_IMAGE_URI")/g" \
              -e "s#__BACKEND_LOG_GROUP__#${BACKEND_LOG_GROUP}#g" \
              -e "s#__FRONTEND_LOG_GROUP__#${FRONTEND_LOG_GROUP}#g" \
              -e "s/__BACKEND_CONTAINER_NAME__/${BACKEND_CONTAINER_NAME}/g" \
              -e "s/__FRONTEND_CONTAINER_NAME__/${FRONTEND_CONTAINER_NAME}/g" \
              "$TASKDEF_TEMPLATE" > "$ECS_REPORT_DIR/taskdef.rendered.json"
          '''
        }
      }
    }

    stage('Register ECS Task Definition Revision') {
      steps {
        script {
          env.NEW_TASK_DEF_ARN = sh(
            script: "aws ecs register-task-definition --cli-input-json file://${env.ECS_REPORT_DIR}/taskdef.rendered.json --query 'taskDefinition.taskDefinitionArn' --output text",
            returnStdout: true
          ).trim()
        }
        sh '''
          set -euo pipefail
          printf '%s\\n' "$NEW_TASK_DEF_ARN" > "$ECS_REPORT_DIR/task-definition-arn.txt"
          aws ecs describe-task-definition --task-definition "$NEW_TASK_DEF_ARN" > "$ECS_REPORT_DIR/task-definition.json"
        '''
      }
    }

    stage('Deploy to ECS Service') {
      when {
        anyOf {
          expression { return env.IS_MAIN == 'true' }
          expression { return params.DEPLOY_FROM_NON_MAIN }
        }
      }
      steps {
        sh '''
          set -euo pipefail

          # ── Render AppSpec with the new task definition ARN ──
          APPSPEC=$(sed \
            -e "s|__TASK_DEF_ARN__|${NEW_TASK_DEF_ARN}|g" \
            -e "s|__FRONTEND_CONTAINER_NAME__|${FRONTEND_CONTAINER_NAME}|g" \
            "$APPSPEC_TEMPLATE")

          printf '%s\n' "$APPSPEC" > "$ECS_REPORT_DIR/appspec.rendered.json"

          # ── Escape the JSON for the --revision payload ──
          APPSPEC_ESCAPED=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$APPSPEC")

          # ── Create CodeDeploy blue/green deployment ──
          DEPLOYMENT_ID=$(aws deploy create-deployment \
            --application-name  "$CODEDEPLOY_APP_NAME" \
            --deployment-group-name "$CODEDEPLOY_DG_NAME" \
            --revision "{\"revisionType\":\"AppSpecContent\",\"appSpecContent\":{\"content\":${APPSPEC_ESCAPED}}}" \
            --query 'deploymentId' --output text)

          printf '%s\n' "$DEPLOYMENT_ID" > "$ECS_REPORT_DIR/deployment-id.txt"
          echo "→ CodeDeploy deployment started: $DEPLOYMENT_ID"

          # ── Wait for deployment to succeed (up to 15 min) ──
          aws deploy wait deployment-successful --deployment-id "$DEPLOYMENT_ID"
          echo "✓ CodeDeploy deployment $DEPLOYMENT_ID succeeded"

          aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" > "$ECS_REPORT_DIR/deployment-result.json"
        '''
      }
    }

    stage('Post-Deploy Cleanup') {
      when {
        anyOf {
          expression { return env.IS_MAIN == 'true' }
          expression { return params.DEPLOY_FROM_NON_MAIN }
        }
      }
      steps {
        sh '''
          set -euo pipefail

          cat > "$ECS_REPORT_DIR/ecr-lifecycle-policy.json" <<POLICY
{
  "rules": [{
    "rulePriority": 1,
    "description": "Keep only latest ${ECR_LIFECYCLE_MAX_IMAGES} images",
    "selection": {
      "tagStatus": "any",
      "countType": "imageCountMoreThan",
      "countNumber": ${ECR_LIFECYCLE_MAX_IMAGES}
    },
    "action": { "type": "expire" }
  }]
}
POLICY

          aws ecr put-lifecycle-policy \
            --repository-name "$BACKEND_ECR_REPO" \
            --lifecycle-policy-text "$(cat "$ECS_REPORT_DIR/ecr-lifecycle-policy.json")" || true

          aws ecr put-lifecycle-policy \
            --repository-name "$FRONTEND_ECR_REPO" \
            --lifecycle-policy-text "$(cat "$ECS_REPORT_DIR/ecr-lifecycle-policy.json")" || true

          aws ecs list-task-definitions \
            --family-prefix "$ECS_TASK_FAMILY" \
            --sort DESC \
            --query 'taskDefinitionArns[]' \
            --output text | tr '\\t' '\\n' > "$ECS_REPORT_DIR/task-definition-list.txt"

          tail -n +$((ECS_TASKDEF_KEEP_REVISIONS + 1)) "$ECS_REPORT_DIR/task-definition-list.txt" > "$ECS_REPORT_DIR/prune-list.txt" || true

          if [ -s "$ECS_REPORT_DIR/prune-list.txt" ]; then
            while IFS= read -r arn; do
              [ -z "$arn" ] && continue
              aws ecs deregister-task-definition --task-definition "$arn" || true
            done < "$ECS_REPORT_DIR/prune-list.txt"
          fi
        '''
      }
    }

    stage('Docker Cleanup') {
      steps {
        sh 'docker image prune -f --filter "dangling=true" || true'
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**/*', fingerprint: true, allowEmptyArchive: true
    }
    success {
      echo "✓ Build: ${env.IMAGE_TAG}"
      echo "✓ Backend:  ${env.BACKEND_IMAGE_URI}"
      echo "✓ Frontend: ${env.FRONTEND_IMAGE_URI}"
      echo "✓ Task Def: ${env.NEW_TASK_DEF_ARN ?: 'N/A'}"
    }
  }
}
