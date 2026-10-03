# Git Workflow

## Branch model

The repository uses GitLab Flow with one integration branch and one promotion
branch:

~~~text
feature or fix branch -> merge request -> main -> staging
                                      |
                                      +-> production -> manual production deploy
~~~

The branch is part of the release control. main represents the version that is
being integrated and tested in staging. production represents the version that
has been explicitly promoted for production deployment.

## Branches

| Branch | Purpose | Deployment behavior |
| --- | --- | --- |
| main | Integration branch; changes arrive through merge requests | Successful pushes deploy staging automatically |
| production | Promotion branch and production release record | The deployment job is manual |
| feat/<slug> | Short-lived feature work | No deployment |
| fix/<slug> | Short-lived bug-fix work | No deployment |

Feature and fix branches should be deleted after the merge request is merged.

## Merge-request checks

A merge request is expected to pass the quality, test, build, and security
checks before it is merged. The pipeline includes:

- Ruff and Black checks;
- pytest against PostgreSQL 15;
- container image build;
- Trivy configuration and secret scanning;
- image scanning when the pipeline publishes an image.

The pipeline comments describe merge-request image builds as validation-only,
without publication. The current build script still contains an unconditional
docker push command, so this behavior must be reconciled before it is treated
as a guaranteed branch protection rule. The discrepancy is recorded in
[ci-cd.md](ci-cd.md) and [verification.md](verification.md).

## Promotion to production

Promotion is an explicit merge from main into production:

~~~sh
git fetch origin
git checkout production
git pull --ff-only origin production
git merge --no-ff origin/main
git push origin production
~~~

The no-fast-forward merge creates a visible promotion commit. That commit is
the audit record connecting the production branch to the source state that was
reviewed in staging.

The push starts the production pipeline. The pipeline runs through the deploy
stage and waits for a person to start the manual production job. The job
creates the target namespace Secret from protected GitLab variables, selects
the production GitLab Agent context, upgrades the Helm release, waits for the
application and database workloads, and runs an internal smoke check.

## Rollback

For a Kubernetes-only rollback, inspect Helm history and return to the last
known-good release:

~~~sh
helm -n production history prod
helm -n production rollback prod <revision> --wait
kubectl -n production rollout status deployment/prod-fastapi-app --timeout=180s
~~~

For a source-controlled rollback, revert the promotion merge on production:

~~~sh
git checkout production
git pull --ff-only origin production
git revert -m 1 <promotion-merge-sha>
git push origin production
~~~

Reverting preserves the branch history and lets the normal production pipeline
redeploy the earlier source state. History should not be rewritten for a
normal operational incident.

## Commit messages

Use a short imperative subject, followed by a blank line and a paragraph that
explains the reason for the change and any non-obvious consequence. Prefixes
such as docs:, fix:, test:, and ci: are useful when they clarify the purpose.

## Protected settings to keep aligned

The GitLab project should keep these rules aligned with the repository:

- direct pushes to main and production are restricted;
- merge requests are required for normal changes to main;
- the pipeline must pass before merge;
- production deployment remains a manual job;
- CI/CD variables containing passwords, tokens, and backup credentials remain
  protected and masked;
- the container registry and GitLab Agent permissions are limited to the
  project environments.

The environment mapping is described in
[environment-strategy.md](environment-strategy.md), and the complete job flow
is described in [ci-cd.md](ci-cd.md).
