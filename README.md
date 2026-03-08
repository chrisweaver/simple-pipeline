# AWS CodePipeline → Lambda — Terraform

Provisions a fully managed CI/CD pipeline with four stages:

```
Source (CodeStar / GitHub) → Build (CodeBuild) → Test (CodeBuild) → Deploy (Lambda)
```

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.5.0 |
| AWS CLI | 2.x (credentials configured) |
| Node.js (app) | 20.x (or change `lambda_runtime`) |

## Quick Start

```bash
# 1. Clone / copy this directory into your project
cp -r terraform-cicd/ path/to/infra/

# 2. Set your variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your repo owner, name, etc.

# 3. Initialise and apply
terraform init
terraform plan
terraform apply
```

## ⚠️  Activate the CodeStar Connection (one-time manual step)

After `terraform apply`, the CodeStar Connection is in **PENDING** state.  
You must activate it before the pipeline will trigger:

1. Open **AWS Console → Developer Tools → Settings → Connections**
2. Select the connection named `<project_name>-connection`
3. Click **Update pending connection** and complete the OAuth flow
4. Status should change to **Available**

## Project Layout

```
terraform-cicd/
├── main.tf                   # Pipeline, Lambda, S3, CodeBuild projects
├── iam.tf                    # All IAM roles and policies
├── variables.tf              # Input variable definitions
├── outputs.tf                # Output values
├── terraform.tfvars.example  # Template for your tfvars
└── buildspec/
    ├── buildspec-build.yml   # Build stage commands
    └── buildspec-test.yml    # Test stage commands
```

## Pipeline Stages

| # | Stage | Provider | Input | Output |
|---|-------|----------|-------|--------|
| 1 | **Source** | CodeStarSourceConnection | Repository branch push | `source_output` |
| 2 | **Build** | CodeBuild | `source_output` | `build_output` (lambda-deployment.zip) |
| 3 | **Test** | CodeBuild | `build_output` | `test_output` |
| 4 | **Deploy** | Lambda (UpdateFunctionCode) | `test_output` | — |

## Customising the Build

Edit the two files in `buildspec/` to match your language/framework:

- **buildspec-build.yml** — install dependencies, compile, zip
- **buildspec-test.yml** — run unit + integration tests, publish JUnit reports

If you use Python instead of Node.js change:

```yaml
# buildspec-build.yml
install:
  runtime-versions:
    python: 3.12
```

And update `lambda_runtime = "python3.12"` and `lambda_handler = "app.handler"` in `terraform.tfvars`.

## Changing the Deploy Strategy

The default deploy stage calls `lambda:UpdateFunctionCode` directly via the  
built-in **Lambda** CodePipeline action.

For blue/green or traffic-shifted deployments, replace the Deploy stage action  
with an **AWS CodeDeploy** action and add an `appspec.yml` to your repository.

## Tear Down

```bash
terraform destroy
```

> The S3 bucket is created with `force_destroy = true` so Terraform will empty  
> and delete it automatically.
