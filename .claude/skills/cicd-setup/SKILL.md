---
name: cicd-setup
description: Set up GitHub Actions workflows for testing, security checks, and Cloud Run deployment. Use when configuring CI/CD, creating workflows, or troubleshooting deployment automation.
disable-model-invocation: true
---

# CI/CD Setup for Cloud Run

Set up GitHub Actions workflows for this Laravel project to automate testing and deployment to Google Cloud Run.

## Workflow Structure

Create three workflow files in `.github/workflows/`:

### 1. Test Workflow (`test.yml`)
Run tests on every PR and push to main.

**Configuration:**
- Trigger: `pull_request` and `push` to `main` branch
- Services: MySQL 8.0 (image: `mysql:8.0`)
- PHP Version: 8.4 with extensions `mbstring, pdo_mysql`

**Steps:**
1. Checkout code
2. Setup PHP 8.4
3. Install dependencies: `composer install --no-interaction --prefer-dist`
4. Copy `.env.example` to `.env`
5. Generate app key: `php artisan key:generate`
6. Run migrations: `php artisan migrate --force`
7. Run tests: `php artisan test`
8. Check code style: `./vendor/bin/pint --test`

### 2. Deploy Workflow (`deploy.yml`)
Deploy to Cloud Run on push to main branch.

**Configuration:**
- Trigger: `push` to `main` branch ONLY
- Region: `asia-northeast1`
- Port: `8080`

**Steps:**
1. Setup GCloud SDK with service account
2. Configure Docker: `gcloud auth configure-docker`
3. Build Docker image tagged with `${{ github.sha }}` and `latest`
4. Push to Google Container Registry (`gcr.io`)
5. Deploy to Cloud Run with environment variables
6. Run migrations: `gcloud run jobs execute migrate-job --region asia-northeast1 --wait`

**Important:**
- Tag images with both SHA and `latest`
- Set all environment variables via `--set-env-vars`
- Never deploy from feature branches

### 3. Security Workflow (`security.yml`)
Check for vulnerabilities on PR and weekly.

**Configuration:**
- Trigger: `pull_request` + `schedule: cron '0 0 * * 0'` (weekly)
- Run: `composer audit`
- Block merge if vulnerabilities found

## Required GitHub Secrets

Add in: Repository Settings → Secrets and variables → Actions

| Secret | Generate With |
|--------|---------------|
| `GCP_SA_KEY` | Service account JSON key from GCP IAM |
| `GCP_PROJECT_ID` | From GCP Console |
| `APP_KEY` | `php artisan key:generate --show` |
| `DB_HOST` | Cloud SQL connection name or IP |
| `DB_DATABASE` | Database name |
| `DB_USERNAME` | Database user |
| `DB_PASSWORD` | Database password |

## Cloud Run Environment Variables

Set via `--set-env-vars` in deploy step:
- `APP_ENV=production`
- `APP_DEBUG=false`
- `DB_CONNECTION=mysql`
- `DB_HOST=${{ secrets.DB_HOST }}`
- `DB_DATABASE=${{ secrets.DB_DATABASE }}`
- `DB_USERNAME=${{ secrets.DB_USERNAME }}`
- `DB_PASSWORD=${{ secrets.DB_PASSWORD }}`

## Best Practices

**Testing:**
- ✅ Block merge if tests fail
- ✅ Run Pint for code style checks
- ✅ Use MySQL service container

**Security:**
- ✅ Never commit secrets
- ✅ Use service accounts with minimal permissions
- ✅ Block merge on security vulnerabilities

**Deployment:**
- ✅ Deploy only from `main` branch
- ✅ Require PR reviews before merge
- ✅ Run migrations after deployment
- ❌ Never deploy from feature branches

## Rollback

Cloud Run keeps previous revisions for easy rollback:

```bash
# List revisions
gcloud run revisions list --service=charevie --region=asia-northeast1

# Rollback to specific revision
gcloud run services update-traffic charevie \
  --to-revisions=REVISION_NAME=100 \
  --region=asia-northeast1
```

## Pre-Setup Checklist

Before creating workflows:
- [ ] GCP project created
- [ ] Cloud Run API enabled
- [ ] Cloud Build API enabled
- [ ] Service account created with necessary permissions
- [ ] Database accessible from Cloud Run
- [ ] All GitHub Secrets added
- [ ] `.env.example` is up to date
- [ ] Tests pass locally: `php artisan test`
- [ ] Code style passes: `./vendor/bin/pint --test`

## Troubleshooting

**Tests fail in CI but pass locally:**
- Check MySQL service configuration
- Verify PHP version and extensions

**Deployment fails:**
- Verify all GitHub Secrets are set
- Check service account permissions
- Review Cloud Build logs

**Migrations fail:**
- Verify database connection from Cloud Run
- Check database credentials in secrets

## Next Steps

1. Create workflow files in `.github/workflows/`
2. Push to feature branch and create PR
3. Verify test workflow runs
4. Merge to main and verify deployment
5. Check application is accessible
6. Monitor Cloud Run logs
